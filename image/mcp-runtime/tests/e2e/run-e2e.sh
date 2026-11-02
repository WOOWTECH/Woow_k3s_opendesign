#!/usr/bin/env bash
# Container-level e2e of the built-in OpenDesign MCP server in the PaaS image (test-only, never production).
#
#   IMG=<built open-design image> [PROOF_PREFIX=<name prefix>] [BIG_FILE_BYTES=3145728] \
#     open-design/mcp-runtime/tests/e2e/run-e2e.sh <evidence-dir>
#
# Topology = the chart's daemon pod (open-design 0.5.0), with plain Docker: every container joins the network
# namespace of one "pause" container (pod loopback), and volumes stand in for the pod's volumes:
#   $P-data     od-data PVC (daemon: /app/.od)
#   $P-mcpdata  the od-data subPath .woow-mcp (mcp: /data/mcp; daemon: /app/.od/.woow-mcp, as the subPath is a
#               directory of the same PVC). Created root:1001 2775 like the kubelet creates a subPath of a volume
#               with fsGroup 1001
#   $P-run      emptyDir od-mcp-run (mcp and the auth proxy stand-in only; never the daemon)
# containers: $P-daemon (uid 1001, the real OpenDesign daemon on 127.0.0.1:7457), $P-mcp (uid 10001 + group 1001,
# read-only root file system, /opt/woow/bin/paas-opendesign-mcp on 127.0.0.1:8081), $P-proxy (uid 101 like
# nginx-unprivileged: the probes).
# Every container runs with all capabilities dropped and no-new-privileges, as the chart does.
# No bind mount (the CI runner's docker daemon cannot see the job's files): probes go in with `docker cp`.
# Throwaway tokens live only in this shell; every evidence file is redacted and checked for them at the end.
set -Eeuo pipefail

IMG=${IMG:?built open-design image}
EV=${1:?evidence dir}
P=${PROOF_PREFIX:-od-mcp-e2e}
BIG_FILE_BYTES=${BIG_FILE_BYTES:-3145728}   # over the runtime's read_file size limit
E2E=$(cd "$(dirname "$0")" && pwd)
PY=/opt/woow/.venv/bin/python
MCP=http://127.0.0.1:8081
HARD=(--cap-drop ALL --security-opt no-new-privileges)
POD=(--network "container:$P-pause")
mkdir -p "$EV"
TOKEN=''
OLD=''
SEEN=()   # every token this run has held, for redaction and the final leak check
FAILED=()
red() { local s t; s=$(cat); for t in "${SEEN[@]}" "$TOKEN"; do [[ -n $t ]] && s=${s//"$t"/[REDACTED]}; done; printf '%s\n' "$s"; }
log() { printf '\n### %s\n' "$*"; }
# mcp <token> <check>...; expectations come from the caller's HEALTH_EXPECT / STATUS_EXPECT / READY_EXPECT.
mcp() {
  local token=$1; shift
  docker exec -e MCP_TOKEN="$token" -e HEALTH_EXPECT="${HEALTH_EXPECT:-ok}" -e STATUS_EXPECT="${STATUS_EXPECT:-}" \
    -e READY_EXPECT="${READY_EXPECT:-}" "$P-proxy" $PY /tmp/e2e/mcp_probe.py "$MCP" "$@"
}
admin() { docker exec "$P-proxy" $PY /tmp/e2e/admin_probe.py /run/od-mcp/admin.sock "$@"; }
wait_ready() {
  local start=$SECONDS
  until docker exec "$P-proxy" $PY -c "import httpx,sys; sys.exit(httpx.get('$1/health/ready', timeout=5).status_code != 200)" 2>/dev/null; do
    (( SECONDS - start < ${2:-300} )) || { echo "not ready after ${2:-300}s"; docker logs "$P-mcp" 2>&1 | tail -n 20; return 1; }
    sleep 3
  done
  echo "ready after ~$((SECONDS - start))s"
}
# Each step runs in THIS shell (token rotation must persist); its output is redacted into the evidence file.
step() {
  local file=$1; shift
  if "$@" > "$EV/.raw" 2>&1; then :; else echo "STEP FAILED (exit $?)" >> "$EV/.raw"; FAILED+=("$file"); fi
  red < "$EV/.raw" > "$EV/$file"
  rm -f "$EV/.raw"
  echo "== $file: $(grep -c '"FAIL"' "$EV/$file" || true) failed expectation(s)$(grep -q '^STEP FAILED' "$EV/$file" && echo ', STEP FAILED')"
}
cleanup() {
  docker rm -f "$P-proxy" "$P-mcp" "$P-daemon" "$P-pause" >/dev/null 2>&1 || true
  docker volume rm "$P-data" "$P-mcpdata" "$P-run" >/dev/null 2>&1 || true
}
[[ ${KEEP:-0} == 1 ]] || trap cleanup EXIT
cleanup

for v in data mcpdata run; do docker volume create "$P-$v" >/dev/null; done
# Volume roots as the kubelet leaves them with fsGroup 1001: PVC root and subPath root:1001 2775, emptyDir 2777.
docker run --rm --user 0 --entrypoint sh -v "$P-data":/v/data -v "$P-mcpdata":/v/mcpdata -v "$P-run":/v/run "$IMG" -c \
  'chown 0:1001 /v/*; chmod 2775 /v/data /v/mcpdata; chmod 2777 /v/run'
docker run -d --name "$P-pause" --network none --entrypoint sleep "$IMG" infinity >/dev/null
docker run -d --name "$P-daemon" "${POD[@]}" "${HARD[@]}" --user 1001:1001 \
  -v "$P-data":/app/.od -v "$P-mcpdata":/app/.od/.woow-mcp "$IMG" \
  node apps/daemon/bin/od.mjs --host 127.0.0.1 --port 7457 --no-open >/dev/null
MCP_RUN=(-d "${POD[@]}" "${HARD[@]}" --user 10001:10001 --group-add 1001 --entrypoint /opt/woow/bin/paas-opendesign-mcp)
# --read-only: the chart runs this container with readOnlyRootFilesystem.
docker run --name "$P-mcp" "${MCP_RUN[@]}" --read-only -e WOOW_OD_MCP_PUBLIC_ORIGIN=https://od-e2e.example.invalid \
  -e SOME_POD_ENV=must-not-reach-the-runtime -v "$P-mcpdata":/data/mcp -v "$P-run":/run/od-mcp "$IMG" >/dev/null
docker run -d --name "$P-proxy" "${POD[@]}" "${HARD[@]}" --user 101:101 -v "$P-run":/run/od-mcp \
  --entrypoint sleep "$IMG" infinity >/dev/null
docker cp "$E2E/." "$P-proxy":/tmp/e2e >/dev/null

s01() {
  log "image"
  docker image inspect "$IMG" --format 'id={{.Id}} created={{.Created}}'
  docker exec "$P-proxy" sh -c "sed -n 's/.*\"source_commit\": \"\\([0-9a-f]*\\)\".*/vendored Woow_ha_mcp_addons commit \\1/p' /opt/woow/VENDOR.json; /usr/bin/python3 --version; grep '\"version\"' /app/apps/daemon/package.json"
  log "startup (daemon + mcp sidecar)"
  wait_ready "$MCP" 300
  docker logs "$P-mcp" 2>&1 | tail -n 5
}
s02() {
  log "auth refusals on /mcp"
  mcp "$TOKEN" auth
  log "Bearer flow: initialize -> tools/list (15) -> read tools"
  mcp "$TOKEN" bearer
  log "Claude.ai-style URL secret /private_<token>/mcp (Origin allowed); wrong secret -> 404"
  mcp "$TOKEN" secret
  log "readiness"
  READY_EXPECT=200 mcp '' ready
}
s03() {
  log "/mcp-admin/ over admin.sock as nginx sends it (basic-auth user in X-Remote-User-Id)"
  admin checks
}
s04() {
  log "every tool is enabled: the five non-read tools are dispatched to the daemon (bogus ids, no such agent)"
  mcp "$TOKEN" calls
  log "refused calls: JSON-RPC errors without input echo; no session -> 403"
  mcp "$TOKEN" refusals
}
s04b() {
  log "protections on a real project: secret file names, size limit, binary file, a failing agent run"
  local id=0a0b0c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d
  docker cp "$E2E/make_project.sh" "$P-daemon":/tmp/make_project.sh >/dev/null
  docker exec "$P-daemon" sh /tmp/make_project.sh $id "$BIG_FILE_BYTES"
  docker exec -e MCP_TOKEN="$TOKEN" -e PROJECT_ID=$id "$P-proxy" $PY /tmp/e2e/mcp_probe.py "$MCP" protect
}
s05() {
  log "policy: disable read_file -> 14 tools and read_file refused; enable all -> 15"
  admin disable=read_file
  mcp "$TOKEN" count=14 refused=read_file
  admin enable-all
  mcp "$TOKEN" count=15
}
s06() {
  log "token rotate: old token 401, new token 200"
  OLD=$TOKEN
  TOKEN=$(admin rotate)
  SEEN+=("$TOKEN")
  STATUS_EXPECT=401 mcp "$OLD" status
  STATUS_EXPECT=200 mcp "$TOKEN" status
  log "token revoke: Bearer 401, URL secret 404"
  admin revoke
  STATUS_EXPECT=401 mcp "$TOKEN" status
  docker exec -e T="$TOKEN" "$P-proxy" $PY -c "import httpx,os,sys; s=httpx.post('$MCP/private_'+os.environ['T']+'/mcp', json={}).status_code; print('secret path after revoke', s); sys.exit(s != 404)"
  log "rotate again restores access"
  OLD=$TOKEN
  TOKEN=$(admin rotate)
  SEEN+=("$TOKEN")
  STATUS_EXPECT=200 mcp "$TOKEN" status
}
s07() {
  log "Claude.ai connector sequence over the URL secret"
  mcp "$TOKEN" claudeai
}
s08() {
  local mgmt rc=0
  log "mcp container: processes, modes, environment"
  docker exec "$P-mcp" sh -c 'for d in /proc/[0-9]*; do c=$(tr "\0" " " < $d/cmdline 2>/dev/null); [ -n "$c" ] && echo "uid=$(awk "/^Uid:/{print \$2}" $d/status) $c"; done' | grep -v ' sh -c ' || true
  docker exec "$P-mcp" stat -c '%a %u:%g %F %n' /data/mcp /data/mcp/state /data/mcp/state/state.json /run/od-mcp /run/od-mcp/admin.sock /run/od-mcp/child /run/od-mcp/child/child.sock
  [[ $(docker exec "$P-mcp" stat -c '%a %u' /data/mcp/state/state.json) == '600 10001' ]] || { echo 'FAIL state.json is not 600 uid 10001'; rc=1; }
  [[ $(docker exec "$P-mcp" stat -c '%a %u' /data/mcp/state) == '700 10001' ]] || { echo 'FAIL state dir is not 700 uid 10001'; rc=1; }
  [[ $(docker exec "$P-mcp" stat -c '%a %u' /run/od-mcp/child) == '700 10001' ]] || { echo 'FAIL child dir is not 700 uid 10001'; rc=1; }
  mgmt=$(docker exec "$P-mcp" sh -c 'for d in /proc/[0-9]*; do grep -q management.py $d/cmdline 2>/dev/null && echo ${d#/proc/}; done' | head -1)
  if docker exec "$P-mcp" cat "/proc/$mgmt/environ" >/dev/null 2>&1; then echo 'FAIL management environ readable (dumpable)'; rc=1; else echo 'management environ: unreadable (not dumpable)'; fi
  if docker exec "$P-mcp" sh -c "tr '\\0' '\\n' < /proc/\$(pgrep -f ha_opendesign_mcp/child.py | head -1)/environ" 2>/dev/null | grep -q SOME_POD_ENV; then echo 'FAIL pod env reached the child'; rc=1; else echo 'pod environment: not inherited by the runtime'; fi
  log "daemon container (uid 1001: OpenDesign, agents, tenant shells)"
  if docker exec "$P-daemon" cat /app/.od/.woow-mcp/state/state.json >/dev/null 2>&1; then echo 'FAIL daemon reads state.json'; rc=1; else echo 'read state.json: denied'; fi
  if docker exec "$P-daemon" ls /app/.od/.woow-mcp/state >/dev/null 2>&1; then echo 'FAIL daemon lists the state dir'; rc=1; else echo 'list state dir: denied'; fi
  if docker exec "$P-daemon" test -e /run/od-mcp; then echo 'FAIL daemon sees /run/od-mcp'; rc=1; else echo '/run/od-mcp: not mounted in the daemon container'; fi
  docker exec "$P-daemon" sh -c 'code=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8081/mcp); echo "daemon -> 127.0.0.1:8081/mcp without token: $code"; test "$code" = 401' || rc=1
  log "auth proxy stand-in (uid 101, mounts od-mcp-run)"
  docker exec "$P-proxy" $PY -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/od-mcp/admin.sock"); print("connect admin.sock: allowed")' || rc=1
  if docker exec "$P-proxy" $PY -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/od-mcp/child/child.sock")' 2>/dev/null; then echo 'FAIL proxy reaches child.sock'; rc=1; else echo 'connect child.sock: denied'; fi
  log "memory"
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "$P-mcp" "$P-daemon"
  return $rc
}
s09() {
  log "OpenDesign daemon stopped: the MCP sidecar keeps running, health reports the backend error, readiness 503"
  docker stop -t 5 "$P-daemon" >/dev/null
  HEALTH_EXPECT=error mcp "$TOKEN" health
  sleep 25
  READY_EXPECT=503 mcp '' ready
  echo "mcp container: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$P-mcp")"
  [[ $(docker inspect -f '{{.State.Running}}' "$P-mcp") == true ]]
  log "daemon started again: ready, health ok"
  docker start "$P-daemon" >/dev/null
  wait_ready "$MCP" 300
  HEALTH_EXPECT=ok mcp "$TOKEN" health
}
s10() {
  log "mcp container restarted (stale admin.sock / child dir in the emptyDir): same token, same grants"
  docker restart -t 10 "$P-mcp" >/dev/null
  wait_ready "$MCP" 180
  STATUS_EXPECT=200 mcp "$TOKEN" status
  mcp "$TOKEN" count=15
}
step 01-startup.txt s01
TOKEN=$(admin reveal)
[[ ${#TOKEN} == 43 ]] || { echo "unexpected token shape"; exit 1; }
SEEN+=("$TOKEN")
step 02-mcp.txt s02
step 03-admin.txt s03
step 04-tools.txt s04
step 04b-protections.txt s04b
step 05-policy.txt s05
step 06-token-lifecycle.txt s06
step 07-claudeai.txt s07
step 08-isolation.txt s08
step 09-backend-unavailable.txt s09
step 10-mcp-restart.txt s10

patterns=(); for t in "${SEEN[@]}"; do patterns+=(-e "$t"); done
if grep -rlF "${patterns[@]}" "$EV"; then echo "LEAK: token found in evidence" | tee "$EV/99-leak-check.txt"; exit 1; fi
echo "leak check: none of the ${#SEEN[@]} throwaway tokens appears in the evidence files" | tee "$EV/99-leak-check.txt"
if grep -l '"FAIL"\|^FAIL ' "$EV"/*.txt; then FAILED+=(expectations); fi
if (( ${#FAILED[@]} )); then echo "e2e FAILED: ${FAILED[*]}"; exit 1; fi
echo "e2e OK"
