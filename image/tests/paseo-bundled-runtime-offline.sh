#!/usr/bin/env bash
#
# Paseo's first activation must succeed OFFLINE, without npm, on a small data volume (paas-odoo-ci#448).
#
#   usage: paseo-bundled-runtime-offline.sh <image> <container-name>
#
# Shared by build-open-design-image.yml (candidate gate) and test-open-design-mcp.yml (PR gate).
#  - --network none: any registry / github.com access fails at once, like a deny-all-egress tenant.
#  - 256 MiB tmpfs data volume: the old on-volume install (~0.8 GB of runtime + npm cache) cannot fit, so a
#    regression to `npm ci` fails on capacity even if somebody re-adds a network.
#  - npm is replaced by a stub that records the call and fails: Paseo may never start it.
#  - uid 1001, all capabilities dropped, no privilege escalation: the chart's securityContext.
set -euo pipefail

IMG="${1:?usage: $0 <image> <container-name>}"
NAME="${2:?usage: $0 <image> <container-name>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
  local rc=$?
  if [ "$rc" != 0 ]; then docker logs "$NAME" 2>&1 | tail -40 || true; fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$NAME" --user 1001:1001 --cap-drop ALL --security-opt no-new-privileges \
  --network none \
  --mount type=tmpfs,destination=/tmp/od-paseo-offline,tmpfs-size=268435456,tmpfs-mode=1777 \
  -e OD_DATA_DIR=/tmp/od-paseo-offline "$IMG" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$NAME" curl -sf http://127.0.0.1:7457/api/health >/dev/null 2>&1 && break
  docker inspect "$NAME" --format '{{.State.Running}}' | grep -qx true || { echo "container exited before it was healthy" >&2; exit 1; }
  sleep 2
done
docker exec "$NAME" curl -sf http://127.0.0.1:7457/api/health >/dev/null

# From here on any `npm` start is a failure. Image content only; the container is thrown away.
docker exec -u 0 "$NAME" sh -c 'rm -f /usr/local/bin/npm && printf "#!/bin/sh\necho \"\$@\" >> /tmp/npm-invoked\nexit 99\n" > /usr/local/bin/npm && chmod 0755 /usr/local/bin/npm'

docker exec -i "$NAME" node --input-type=module < "$HERE/paseo-bundled-runtime-smoke.mjs"

if docker exec "$NAME" test -e /tmp/npm-invoked; then
  echo "npm was started during Paseo activation:" >&2
  docker exec "$NAME" cat /tmp/npm-invoked >&2
  exit 1
fi
echo "[paseo offline] OK: first activation ran from the baked runtime with --network none, 256 MiB data volume and no npm."
