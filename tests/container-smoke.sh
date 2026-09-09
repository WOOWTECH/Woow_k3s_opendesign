#!/usr/bin/env bash
# Real-container smoke for the k3s port.
#
# Adapted from the HA add-on's 364-line container-smoke.sh. The important
# structural change: the unit under test is a TWO-CONTAINER POD, because that is
# the topology the chart deploys.
#
#     podman pod  od-smoke   (one network namespace)
#       +-- opendesign   the GHCR image, daemon on 127.0.0.1:7456
#       +-- nginx        nginx:1.27-alpine on :7457, the ONLY published port
#
# Everything the HA smoke proved that mattered is kept: per-pixel PNG colour
# assertions, pdfinfo page count, PPTX slide count, the BYOK key leak scan, the
# credential-symlink removal across a restart, and `! command -v pi`. What is
# new is the pod-shaped proof that the daemon socket is unreachable from outside
# the pod, and the proxy assertions that replace the HA ingress browser e2e.
#
# Usage:
#   tests/container-smoke.sh [image]
# Env:
#   OD_IMAGE            default localhost/woow-k3s-opendesign:test
#   CONTAINER_ENGINE    default podman (a pod is required; docker has none)
#   SMOKE_PORT          host port for the sidecar, default 17457
#   SMOKE_DAEMON_PORT   host port mapped to the daemon, default 17456
#                       (this MUST refuse connections — see below)
set -Eeuo pipefail

# shellcheck source=lib/layout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/layout.sh"
cd "$REPO_ROOT"

engine=${CONTAINER_ENGINE:-podman}
image=${1:-${OD_IMAGE:-localhost/woow-k3s-opendesign:test}}
sidecar_image=${OD_NGINX_IMAGE:-nginx:1.27-alpine}
port=${SMOKE_PORT:-17457}
daemon_port=${SMOKE_DAEMON_PORT:-17456}
pod="od-smoke-${RANDOM}"
volume="od-smoke-data-${RANDOM}"
allowed_origin=${OD_ALLOWED_ORIGIN:-https://od.test}
project_id=od-smoke
# Deliberately fake. The native BYOK smoke verifies this value never leaves the
# transient browser-style request as a log line or persisted /data artifact.
readonly BYOK_FAKE_KEY='od-byok-test-key-not-a-secret'
tmp=$(mktemp -d)

require_command "$engine" "container smoke"
if [[ "$engine" != *podman* ]]; then
  die_missing "container smoke" \
    "CONTAINER_ENGINE=$engine — this smoke needs a pod (two containers, one netns). Use podman."
fi
require_paths "container smoke (run tests/lib/extract-chart-assets.py first)" \
  "$ARTIFACTS/nginx.conf" "$ARTIFACTS/od-export-bridge.js" \
  "$REPO_ROOT/tests/fixtures/export-deck.html"

if ! "$engine" image exists "$image" 2>/dev/null; then
  die_missing "container smoke" "image not present: $image (build it first, e.g. podman build -t $image .)"
fi

od_container="${pod}-opendesign"
nginx_container="${pod}-nginx"

cleanup() {
  local status=$?
  if (( status != 0 )); then
    echo '--- opendesign logs ---' >&2
    "$engine" logs "$od_container" >&2 2>&1 || true
    echo '--- nginx logs ---' >&2
    "$engine" logs "$nginx_container" >&2 2>&1 || true
  fi
  "$engine" pod rm -f "$pod" >/dev/null 2>&1 || true
  "$engine" volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

"$engine" volume create "$volume" >/dev/null

start_pod() {
  "$engine" pod create --name "$pod" \
    -p "127.0.0.1:${port}:7457" \
    -p "127.0.0.1:${daemon_port}:7456" >/dev/null
  # The application container: exactly the chart's env and security posture.
  "$engine" run -d --pod "$pod" --name "$od_container" \
    -v "$volume:/data" \
    -e OD_BIND_HOST=127.0.0.1 \
    -e OD_PORT=7456 \
    -e OD_DATA_DIR=/data/opendesign \
    -e OD_ALLOWED_ORIGINS="$allowed_origin" \
    -e OD_PUBLIC_BASE_URL="$allowed_origin" \
    -e NODE_ENV=production \
    -e TZ=Asia/Taipei \
    "$image" >/dev/null
  # The sidecar: the chart's ConfigMap, mounted exactly where the chart mounts
  # it, under the chart's securityContext (uid 101, read-only rootfs, /tmp rw).
  "$engine" run -d --pod "$pod" --name "$nginx_container" \
    --user 101:101 --read-only --tmpfs /tmp:rw,mode=1777 \
    -v "$ARTIFACTS/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$ARTIFACTS/od-export-bridge.js:/usr/share/nginx/od-export-bridge.js:ro" \
    "$sidecar_image" sh -ceu 'mkdir -p /tmp/od-nginx && exec nginx -g "daemon off;"' >/dev/null
}

remove_pod() {
  "$engine" pod rm -f "$pod" >/dev/null
}

wait_for_health() {
  local attempt
  for ((attempt = 1; attempt <= 120; attempt += 1)); do
    if curl -fsS "http://127.0.0.1:${port}/api/health" >"$tmp/health.json"; then
      return 0
    fi
    if ! "$engine" inspect -f '{{.State.Running}}' "$od_container" 2>/dev/null | grep -qx true; then
      "$engine" logs "$od_container" >&2 || true
      echo 'the opendesign container exited before becoming healthy' >&2
      return 1
    fi
    sleep 1
  done
  "$engine" logs "$od_container" >&2 || true
  "$engine" logs "$nginx_container" >&2 || true
  echo 'health endpoint did not become ready through the sidecar' >&2
  return 1
}

assert_health_json() {
  python3 - "$1" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding='utf-8')).get('ok') is True
PY
}

start_pod
wait_for_health
assert_health_json "$tmp/health.json"
echo 'ok   health through the nginx sidecar'

# --------------------------------------------------------------------------
# The daemon port must NOT be reachable from outside the pod. OD_BIND_HOST is
# 127.0.0.1, so the published mapping has nothing to connect to. This is what
# lets us keep OD's own OD_API_TOKEN safety floor honoured instead of setting
# OD_DISABLE_API_AUTH=1, which is the inversion this rewrite removes.
if curl -fsS --max-time 5 "http://127.0.0.1:${daemon_port}/api/health" >/dev/null 2>&1; then
  echo "FAIL: the daemon port ${daemon_port} answered from outside the pod." >&2
  echo "      OD_BIND_HOST is not loopback, or something else is listening on 7456." >&2
  echo "      The daemon port must not be reachable from outside the pod." >&2
  exit 1
fi
echo 'ok   the daemon port is not reachable from outside the pod'
"$engine" exec "$od_container" sh -ceu 'wget -q -O - http://127.0.0.1:7456/api/health >/dev/null'
echo 'ok   the daemon answers on loopback inside the pod'

# --------------------------------------------------------------------------
# Image posture: PID 1 root only to prepare the root-owned Longhorn mount, one
# runtime process as 1001, no nginx in this container, and no AI CLI smuggled in.
"$engine" exec "$od_container" sh -ceu '
  test "$(id -u)" = 0
  test "$(stat -c %u:%g /data/opendesign)" = 1001:1001
  pids=$(pidof node)
  test -n "$pids"
  for pid in $pids; do
    set -- $(grep "^Uid:" "/proc/$pid/status")
    test "$2 $3 $4" = "1001 1001 1001"
  done
  ! pidof nginx >/dev/null 2>&1
  test -d /data/opendesign
  test -r /app/apps/daemon/dist/cli.js
  test -d /app/apps/web/out
  test -x /usr/bin/chromium-browser
  command -v bash >/dev/null
  command -v su-exec >/dev/null
  test -r /opt/woow-opendesign/headless-entry.mjs
  test -r /opt/woow-opendesign/headless-renderer.mjs
  for executable in claude codex pi opencode-cli aider gemini cursor-agent qwen copilot amp; do
    if command -v "$executable" >/dev/null 2>&1 \
      || test -e "/app/node_modules/.bin/$executable" \
      || test -e "/usr/local/lib/node_modules/.bin/$executable"; then
      echo "forbidden local AI CLI present: $executable" >&2
      exit 1
    fi
  done
'
echo 'ok   image posture, single runtime process as 1001, no forbidden CLI'

# OpenDesign's native API mode discovers `opencode` through PATH. Verify the
# real locked Alpine binary as its runtime UID, and ensure withdrawn Pi cannot
# be selected as a local fallback.
"$engine" exec -u 1001:1001 "$od_container" sh -ceu '
  test "$(id -u)" = 1001
  test "$(opencode --version)" = 1.18.29
  test "$(command -v opencode)" = /opt/woow-opendesign/opencode/node_modules/.bin/opencode
  ! command -v opencode-cli >/dev/null 2>&1
  ! command -v pi >/dev/null 2>&1
  test ! -e /usr/local/bin/pi
  test ! -e /opt/woow-opendesign/ha-pi-wrapper.mjs
  test -w /data/opendesign
  printf persisted > /data/opendesign/container-smoke-sentinel
'
echo 'ok   locked OpenCode 1.18.29 on PATH as UID 1001, Pi absent'

# --------------------------------------------------------------------------
# Native browser API request contract end-to-end: the daemon selects
# byok-opencode, invokes the bundled CLI, and streams from a loopback
# OpenAI-compatible mock. The harness never writes its key.
"$engine" cp tests/container-opencode-byok-e2e.mjs "$od_container:/tmp/container-opencode-byok-e2e.mjs"
"$engine" exec "$od_container" node /tmp/container-opencode-byok-e2e.mjs
if "$engine" logs "$od_container" 2>&1 | grep -Fq -- "$BYOK_FAKE_KEY"; then
  echo 'fake BYOK key leaked to container logs' >&2
  exit 1
fi
# Scan every regular persisted artifact, including the daemon DB/run output,
# without echoing a matching path or value into the test log.
if "$engine" exec "$od_container" sh -ceu '
  if grep -R -I -F -q -- "$1" /data; then
    exit 1
  fi
' sh "$BYOK_FAKE_KEY"; then
  :
else
  echo 'fake BYOK key leaked to /data persisted artifacts' >&2
  exit 1
fi
echo 'ok   native byok-opencode stream, no key in logs or /data'

# --------------------------------------------------------------------------
# The withdrawn persistent-profile directory is removed at boot. A legacy
# symlink must be unlinked, never followed, and the rest of /data stays intact.
"$engine" exec "$od_container" sh -ceu '
  mkdir -p /data/opendesign/legacy-credentials-target
  printf retained > /data/opendesign/legacy-credentials-target/sentinel
  ln -sfn /data/opendesign/legacy-credentials-target /data/opendesign/credentials
'
remove_pod
start_pod
wait_for_health
assert_health_json "$tmp/health.json"
"$engine" exec "$od_container" sh -ceu '
  grep -qx persisted /data/opendesign/container-smoke-sentinel
  test ! -e /data/opendesign/credentials
  test ! -L /data/opendesign/credentials
  grep -qx retained /data/opendesign/legacy-credentials-target/sentinel
'
echo 'ok   /data survives a pod recreate; the obsolete credential symlink is unlinked, its target kept'

# --------------------------------------------------------------------------
# Direct renderer acceptance uses the Chromium and playwright-core in the image.
"$engine" cp tests/container-renderer-e2e.mjs "$od_container:/opt/woow-opendesign/container-renderer-e2e.mjs"
"$engine" exec "$od_container" node /opt/woow-opendesign/container-renderer-e2e.mjs
echo 'ok   renderer e2e (stitching, WebSocket SSRF block, slide limit, editable rejection)'

# HTTP export contract, run inside the container against the loopback daemon.
"$engine" cp tests/export-http-contract-e2e.mjs "$od_container:/opt/woow-opendesign/export-http-contract-e2e.mjs"
"$engine" cp tests/export-archive-inspection.mjs "$od_container:/opt/woow-opendesign/export-archive-inspection.mjs"
"$engine" cp tests/fixtures/export-deck.html "$od_container:/tmp/export-deck.html"
"$engine" exec \
  -e OD_EXPORT_BASE_URL=http://127.0.0.1:7456 \
  -e OD_EXPORT_FIXTURE_PATH=/tmp/export-deck.html \
  "$od_container" node /opt/woow-opendesign/export-http-contract-e2e.mjs
echo 'ok   export HTTP contract (HTML attachment/error shape, ZIP archive)'

# --------------------------------------------------------------------------
# Seed a project THROUGH THE SIDECAR, with the allow-listed Origin. This proves
# a mutating non-health API survives the proxy with Host normalised to loopback.
curl --fail-with-body -sS -o "$tmp/project.json" \
  -H "origin: ${allowed_origin}" \
  -H 'content-type: application/json' \
  --data "{\"id\":\"${project_id}\",\"name\":\"k3s smoke\",\"skipDiscoveryBrief\":true}" \
  "http://127.0.0.1:${port}/api/projects"
grep -Fq "$project_id" "$tmp/project.json"
python3 - "$tmp/deck-file.json" tests/fixtures/export-deck.html <<'PY'
import json
import sys
from pathlib import Path

with open(sys.argv[1], 'w', encoding='utf-8') as handle:
    json.dump({'name': 'deck.html', 'content': Path(sys.argv[2]).read_text(encoding='utf-8')}, handle)
PY
curl --fail-with-body -sS -o "$tmp/deck-file-response.json" \
  -H "origin: ${allowed_origin}" \
  -H 'content-type: application/json' \
  --data-binary "@$tmp/deck-file.json" \
  "http://127.0.0.1:${port}/api/projects/${project_id}/files"
grep -Fq 'deck.html' "$tmp/deck-file-response.json"
echo 'ok   project + fixture seeded through the sidecar with the allow-listed Origin'

# --------------------------------------------------------------------------
# Proxy acceptance: bridge injection, no path rewriting, Origin allow/deny,
# binary passthrough. Replaces the HA ingress browser e2e.
OD_PROXY_BASE_URL="http://127.0.0.1:${port}" \
OD_ALLOWED_ORIGIN="$allowed_origin" \
OD_PROJECT_ID="$project_id" \
  node tests/container-proxy-e2e.mjs

# --------------------------------------------------------------------------
# Real exports through the proxy, then the assertions that actually caught
# things in the HA suite: per-pixel PNG colours, PDF page count, PPTX slides.
post_export() {
  local endpoint=$1 body=$2 output=$3
  curl --fail-with-body -sS -o "$output" \
    -H "origin: ${allowed_origin}" \
    -H 'content-type: application/json' --data "$body" \
    "http://127.0.0.1:${port}/api/projects/${project_id}/export/${endpoint}"
  test -s "$output"
}

post_export image '{"fileName":"deck.html","deck":true,"imageFormat":"png"}' "$tmp/deck.png"
post_export image '{"fileName":"deck.html","deck":true,"imageFormat":"jpeg"}' "$tmp/deck.jpg"
post_export pdf-image '{"fileName":"deck.html","deck":true,"title":"Smoke"}' "$tmp/deck.pdf"
post_export pptx '{"fileName":"deck.html","deck":true,"title":"Smoke"}' "$tmp/deck.pptx"

if "$engine" exec "$od_container" sh -c 'command -v pdfinfo >/dev/null 2>&1'; then
  "$engine" cp "$tmp/deck.pdf" "$od_container:/tmp/smoke-deck.pdf"
  pages=$("$engine" exec "$od_container" pdfinfo /tmp/smoke-deck.pdf | awk '/^Pages:/ { print $2 }')
elif command -v pdfinfo >/dev/null 2>&1; then
  pages=$(pdfinfo "$tmp/deck.pdf" | awk '/^Pages:/ { print $2 }')
else
  echo 'FAIL: pdfinfo is available neither in the image nor on the host; the PDF' >&2
  echo '      page-count assertion cannot run and must not be silently skipped.' >&2
  exit 1
fi
test "$pages" = 2 || { echo "PDF page count is $pages, expected 2" >&2; exit 1; }
echo "ok   pdfinfo reports $pages pages"

python3 - "$tmp/deck.png" "$tmp/deck.jpg" "$tmp/deck.pdf" "$tmp/deck.pptx" <<'PY'
from pathlib import Path
import io
import re
import struct
import sys
import zipfile
import zlib

png, jpg, pdf, pptx = map(Path, sys.argv[1:])


def png_pixels(data):
    assert data.startswith(b'\x89PNG\r\n\x1a\n')
    offset = 8
    compressed = bytearray()
    width = height = color_type = None
    while offset < len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b'IHDR':
            width, height, depth, color_type = struct.unpack('>IIBB', payload[:10])
            assert depth == 8 and color_type in (2, 6)
        elif kind == b'IDAT':
            compressed.extend(payload)
        elif kind == b'IEND':
            break
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(compressed)
    rows = []
    previous = bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        encoded = raw[cursor:cursor + stride]
        cursor += stride
        row = bytearray(stride)
        for index, byte in enumerate(encoded):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                raise AssertionError(f'unsupported PNG filter {filter_type}')
            row[index] = (byte + predictor) & 0xff
        rows.append(row)
        previous = row
    return width, height, channels, rows


def jpeg_dimensions(data):
    assert data.startswith(b'\xff\xd8\xff')
    offset = 2
    while offset + 8 < len(data):
        if data[offset] != 0xff:
            offset += 1
            continue
        marker = data[offset + 1]
        if marker in (0xd8, 0xd9):
            offset += 2
            continue
        length = struct.unpack('>H', data[offset + 2:offset + 4])[0]
        if 0xc0 <= marker <= 0xc3:
            return struct.unpack('>HH', data[offset + 5:offset + 9])
        offset += 2 + length
    raise AssertionError('JPEG dimensions not found')


png_data = png.read_bytes()
width, height, channels, rows = png_pixels(png_data)
# Upstream may preserve the requested viewport around the two stacked slides,
# so assert the authored content extent and both slide colors rather than a
# tightly-cropped canvas size.
assert width >= 640 and height >= 720, (width, height)
sample_x = 320 * channels
top = tuple(rows[180][sample_x:sample_x + 3])
bottom = tuple(rows[540][sample_x:sample_x + 3])
assert all(abs(actual - expected) <= 3 for actual, expected in zip(top, (22, 93, 186))), top
assert all(abs(actual - expected) <= 3 for actual, expected in zip(bottom, (170, 51, 51))), bottom

jpg_data = jpg.read_bytes()
jpeg_height, jpeg_width = jpeg_dimensions(jpg_data)
assert jpeg_width >= 640 and jpeg_height >= 720, (jpeg_width, jpeg_height)

pdf_data = pdf.read_bytes()
assert pdf_data.startswith(b'%PDF-') and len(pdf_data) > 100

pptx_data = pptx.read_bytes()
assert pptx_data.startswith(b'PK') and len(pptx_data) > 100
with zipfile.ZipFile(io.BytesIO(pptx_data)) as archive:
    slides = [name for name in archive.namelist() if re.fullmatch(r'ppt/slides/slide\d+\.xml', name)]
assert len(slides) == 2, slides
print('ok   two-color full-deck PNG/JPEG and a 2-slide PPTX, through the proxy')
PY

editable_status=$(curl -sS -o "$tmp/editable.json" -w '%{http_code}' \
  -H "origin: ${allowed_origin}" \
  -H 'content-type: application/json' \
  --data '{"fileName":"deck.html","deck":true,"editable":true}' \
  "http://127.0.0.1:${port}/api/projects/${project_id}/export/pptx")
test "$editable_status" = 502
grep -qi 'Editable PPTX is unsupported' "$tmp/editable.json"
echo 'ok   editable PPTX is rejected rather than silently produced'

echo 'container smoke: two-container pod, loopback-only daemon, proxy contract, persistence, renderer, and HTTP assembly passed'
