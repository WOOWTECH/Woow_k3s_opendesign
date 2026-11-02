#!/usr/bin/env bash
#
# auth-proxy logs carry no MCP token / query string (0.5.4, 商用驗收
# sensitive-data-in-logs / X-SEC-002).
#
# WHY. The auth-proxy's `main` log_format logged "$request" and "$http_referer", both with
# the query string. `location = /mcp` is logged (by design — its token normally travels in the
# Authorization header), so a client that puts the token in the URL (`POST /mcp?token=…`) had
# it written to the pod log. The secret-path variant /private_<token>/mcp turns its access log
# off, but (a) a near-miss URL (`/private_<token>/mcp/`, `/private_<token>/sse`) falls through
# to `location /` and was logged with the token in the path, and (b) nginx's error log adds the
# raw request line ("request: \"POST /private_<token>/mcp …\"") whenever the mcp container is
# down or slow — exactly the moments an operator reads the log.
#
# Asserts:
#   1. nginx.conf: log_format main logs $woow_log_path (request path, query string cut,
#      /private_<token> masked) and no query-string-bearing variable ($request,
#      $request_uri, $args, $arg_*, $query_string, $is_args, raw $http_referer)
#   2. every access_log is `off`, `main`, or the authguard /dev/null hook — no location
#      logs with another format
#   3. mcp.enabled=true: /mcp and /private_<token>/mcp both send their error log to
#      /dev/null; /private_<token>/mcp keeps access_log off
#   4. behaviour (needs nginx; guard off — the CI nginx has no njs, and the guard does not
#      touch the main format): the rendered conf in front of a fake daemon + fake mcp logs
#        GET /mcp?token=…            → "GET /mcp HTTP/1.1" 200, token absent
#        GET /private_<tok>/mcp      → not in the access log at all
#        GET /private_<tok>/mcp/     → logged as /private_<redacted>/mcp/, token absent
#        GET /api/health?probe=…     → "GET /api/health …" (the original path, not the
#                                       internal /_woow/probe rewrite), probe value absent
#        Referer with ?token=…        → logged without its query
#      with the mcp container DOWN: /mcp?token= and /private_<tok>/mcp → 502, and the error
#      log holds neither token. Controls: the same conf with the old "$request" format leaks
#      the token into the access log, and without the two error_log lines the error log leaks
#      it — so the harness really sees both leaks.
#
# nginx: $NGINX_BIN (a command; may be a wrapper) or `nginx` on PATH. Missing → 4 is
# SKIPPED with a message, unless REQUIRE_NGINX=1 (set in CI) → FAIL.
#
# Usage:    bash charts/open-design/tests/test-log-redaction.sh
# Requires: helm + yq (mikefarah) + python3; nginx for 4.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (od-log-redaction): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (od-log-redaction): $1" >&2; exit 1; }

render() {
  $HELM template t "$CHART_DIR" --namespace paas-ws-test "$@" 2>/dev/null && return 0
  echo "FAIL (od-log-redaction): helm template t $* failed: $($HELM template t "$CHART_DIR" --namespace paas-ws-test "$@" 2>&1 >/dev/null | head -2 | tr '\n' ' ')" >&2
  exit 1
}
cm() { printf '%s' "$1" | K="$2" yq -N 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data[strenv(K)]'; }
directives() { printf '%s\n' "$1" | sed -E 's/[[:space:]]+#.*$//' | grep -vE '^[[:space:]]*#' || true; }
block() {  # block <conf> <ERE matching the location line> → that location's lines
  # The ERE goes in through ENVIRON, not `awk -v`: -v expands backslash escapes, and gawk
  # (the CI runner's awk) turns `\^` into `^` — an anchor mid-pattern that never matches.
  printf '%s\n' "$1" | BLOCK_RE="$2" awk '$0 ~ ENVIRON["BLOCK_RE"] {inb=1} inb {print} inb && /^[[:space:]]*\}[[:space:]]*$/ {exit}'
}

OUT="$(render --set mcp.enabled=true)"
MAIN="$(directives "$(cm "$OUT" nginx.conf)")"
CONF="$(directives "$(cm "$OUT" default.conf)")"
[ -n "$MAIN" ] && [ -n "$CONF" ] || fail "authproxy ConfigMap has no nginx.conf / default.conf"

# ── 1. log_format main ──────────────────────────────────────────────────────
FMT="$(printf '%s\n' "$MAIN" | awk '/^[[:space:]]*log_format[[:space:]]+main[[:space:]]/{inb=1} inb{print} inb && /;[[:space:]]*$/{exit}')"
[ -n "$FMT" ] || fail "nginx.conf defines no 'log_format main'"
printf '%s\n' "$FMT" | grep -qF '$woow_log_path' || fail "log_format main does not log \$woow_log_path (path without query): $FMT"
BAD="$(printf '%s\n' "$FMT" | grep -oE '\$(request|request_uri|args|arg_[A-Za-z0-9_]+|query_string|is_args|http_referer)\b' | sort -u | tr '\n' ' ' || true)"
[ -z "$BAD" ] || fail "log_format main logs query-string-bearing variable(s): $BAD"
printf '%s\n' "$MAIN" | grep -qE '^[[:space:]]*map[[:space:]]+\$request_uri[[:space:]]+\$woow_log_path[[:space:]]*\{' \
  || fail "no 'map \$request_uri \$woow_log_path' in nginx.conf"

# ── 2. access_log directives ────────────────────────────────────────────────
ALL="$(printf '%s\n%s\n' "$MAIN" "$CONF" | grep -oE 'access_log[[:space:]]+[^;]*;' || true)"
OTHER="$(printf '%s\n' "$ALL" | grep -vE '^access_log[[:space:]]+off;$' \
  | grep -vE '^access_log[[:space:]]+/var/log/nginx/access\.log[[:space:]]+main;$' \
  | grep -vE '^access_log[[:space:]]+/dev/null[[:space:]]+authguard[[:space:]]+if=\$authguard_watch;$' || true)"
[ -z "$OTHER" ] || fail "access_log directive(s) with another format: $OTHER"

# ── 3. MCP locations: no error log ──────────────────────────────────────────
B_MCP="$(block "$CONF" '^[[:space:]]*location = /mcp \{')"
B_PRIV="$(block "$CONF" '^[[:space:]]*location ~ "\^/private_')"
[ -n "$B_MCP" ] && [ -n "$B_PRIV" ] || fail "mcp.enabled=true renders no /mcp or /private_<token>/mcp location"
printf '%s\n' "$B_MCP"  | grep -qE '^[[:space:]]*error_log[[:space:]]+/dev/null;' || fail "/mcp keeps an error log — upstream errors print the raw request line (?token=…)"
printf '%s\n' "$B_PRIV" | grep -qE '^[[:space:]]*error_log[[:space:]]+/dev/null;' || fail "/private_<token>/mcp keeps an error log — upstream errors print the token path"
printf '%s\n' "$B_PRIV" | grep -qE '^[[:space:]]*access_log[[:space:]]+off;' || fail "/private_<token>/mcp lost access_log off"

STATIC_OK="log_format main = \$woow_log_path (no \$request/\$args/raw referer), every access_log main/off/authguard, /mcp + /private_<token>/mcp error_log /dev/null"

# ── 4. live: needs nginx ────────────────────────────────────────────────────
NGINX_CMD=()
if [ -n "${NGINX_BIN:-}" ]; then
  read -r -a NGINX_CMD <<< "$NGINX_BIN"
elif command -v nginx >/dev/null 2>&1; then
  NGINX_CMD=(nginx)
fi
if [ "${#NGINX_CMD[@]}" = "0" ]; then
  [ "${REQUIRE_NGINX:-0}" = "1" ] && fail "REQUIRE_NGINX=1 but no nginx (set NGINX_BIN or put nginx on PATH)"
  echo "PASS (od-log-redaction): $STATIC_OK — SKIPPED live nginx log check (no nginx binary; set NGINX_BIN)"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || fail "python3 required for the live check"
NGINX_E=()
"${NGINX_CMD[@]}" -e stderr -v >/dev/null 2>&1 && NGINX_E=(-e stderr)

WORK="$(mktemp -d)"
# CI runs as root, so the nginx workers run as `nobody` and cannot enter mktemp's 0700 dir.
# `try_files /_woow_none @od_probe_ok` (anonymous /api/health probe) then hits EACCES instead
# of ENOENT, and nginx logs that at [crit] WITH the raw request line — a harness artefact (the
# pod's root /usr/share/nginx/html is readable), not the leak under test. Mirror the pod: a
# traversable prefix with an existing html root.
chmod 755 "$WORK"; mkdir -p "$WORK/html"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  if [ -f "$WORK/tmp/nginx.pid" ]; then kill "$(cat "$WORK/tmp/nginx.pid")" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

cat > "$WORK/upstream.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
cat > "$WORK/client.py" <<'PY'
import http.client, sys
port = int(sys.argv[1])
out = []
for item in sys.argv[2:]:
    path, _, ref = item.partition(" ")
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("GET", path, headers={"Referer": ref} if ref else {})
    r = c.getresponse(); r.read()
    out.append(str(r.status))
print(" ".join(out))
PY

DAEMON_PORT="$(free_port)"; MCP_UP_PORT="$(free_port)"; MCP_DOWN_PORT="$(free_port)"
python3 "$WORK/upstream.py" "$DAEMON_PORT" 2>/dev/null & PIDS+=("$!")
python3 "$WORK/upstream.py" "$MCP_UP_PORT" 2>/dev/null & PIDS+=("$!")

# Live render: guard off (no njs in the CI nginx; the guard only adds the /dev/null hook),
# console off (its proxy_pass names a Service nginx would have to resolve at load time).
LOUT="$(render --set mcp.enabled=true --set authProxy.guard.enabled=false --set console.enabled=false)"
LMAIN="$(cm "$LOUT" nginx.conf)"; LCONF="$(cm "$LOUT" default.conf)"

# Adapt ONLY the environment-bound bits: upstream ports, listen port, file paths.
prep() {  # prep <nginx.conf> <default.conf> <listen port> <mcp port>
  mkdir -p "$WORK/tmp"; : > "$WORK/htpasswd"; : > "$WORK/mime.types"
  printf '%s\n' "$2" | sed -E \
      -e "s#proxy_pass http://127\.0\.0\.1:8081#proxy_pass http://127.0.0.1:$4#" \
      -e "s#proxy_pass http://127\.0\.0\.1:7457#proxy_pass http://127.0.0.1:${DAEMON_PORT}#" \
      -e "s#^([[:space:]]*)listen[[:space:]]+[0-9]+;#\1listen 127.0.0.1:$3;#" \
      -e "s#/etc/nginx/auth/\.htpasswd#${WORK}/htpasswd#" \
    > "$WORK/default.conf"
  printf '%s\n' "$1" | sed -E \
      -e "s#/tmp/#${WORK}/tmp/#g" \
      -e "s#/var/log/nginx/#${WORK}/#g" \
      -e "s#/etc/nginx/mime\.types#${WORK}/mime.types#" \
      -e "s#/etc/nginx/conf\.d/\*\.conf#${WORK}/default.conf#" \
      -e "s#^worker_processes .*#worker_processes 1;#" \
    > "$WORK/nginx.conf"
  grep -q "listen 127.0.0.1:$3;" "$WORK/default.conf" || fail "test harness: listen not rewritten (conf shape changed?)"
  grep -q "proxy_pass http://127.0.0.1:$4;" "$WORK/default.conf" || fail "test harness: mcp proxy_pass not rewritten (conf shape changed?)"
  grep -q "${WORK}/access.log" "$WORK/nginx.conf" || fail "test harness: access log path not rewritten (conf shape changed?)"
}
run() {  # run <nginx.conf> <default.conf> <mcp port> <expected statuses> <requests…> → access+error log
  local main="$1" conf="$2" mport="$3" want="$4" port st; shift 4
  port="$(free_port)"
  rm -f "$WORK/access.log" "$WORK/error.log" "$WORK/tmp/nginx.pid"
  prep "$main" "$conf" "$port" "$mport"
  "${NGINX_CMD[@]}" "${NGINX_E[@]}" -p "$WORK" -c "$WORK/nginx.conf" -g 'daemon on;' >"$WORK/nginx.out" 2>"$WORK/nginx.err" \
    || { cat "$WORK/nginx.err" >&2; fail "nginx failed to start on the rendered conf"; }
  for _ in $(seq 1 50); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$port),0.2)" 2>/dev/null && break; sleep 0.1; done
  st="$(python3 "$WORK/client.py" "$port" "$@")"
  kill "$(cat "$WORK/tmp/nginx.pid")" 2>/dev/null || true
  for _ in $(seq 1 50); do [ -f "$WORK/tmp/nginx.pid" ] || break; sleep 0.1; done
  [ "$st" = "$want" ] || fail "statuses '$st', expected '$want' (requests: $*)"
  echo "=== access"; cat "$WORK/access.log" 2>/dev/null || true
  echo "=== error";  cat "$WORK/error.log" 2>/dev/null || true
}
section() { printf '%s\n' "$1" | awk -v s="=== $2" '$0==s{inb=1;next} /^=== /{inb=0} inb'; }
leaks() { printf '%s\n' "$1" | grep -oE 'SECRET[A-Z]+[0-9]' | sort -u | tr '\n' ' ' || true; }

UP_REQS=("/mcp?token=SECRETQUERY1 https://od.example.test/?token=SECRETREF2"
         "/private_SECRETPATH3/mcp"
         "/private_SECRETPATH4/mcp/"
         "/api/health?probe=SECRETPROBE5")
# /private_<tok>/mcp/ falls to `location /` → 401 (empty htpasswd); everything else 200.
R="$(run "$LMAIN" "$LCONF" "$MCP_UP_PORT" "200 200 401 200" "${UP_REQS[@]}")"
A="$(section "$R" access)"
printf '%s\n' "$A" | grep -qE '"GET /mcp HTTP/1\.1" 200 ' || fail "access log lacks '\"GET /mcp HTTP/1.1\" 200': $A"
printf '%s\n' "$A" | grep -qF '"https://od.example.test/"' || fail "access log lacks the Referer without its query: $A"
printf '%s\n' "$A" | grep -qE '"GET /private_<redacted>/mcp/ HTTP/1\.1" 401 ' || fail "near-miss /private_<tok>/mcp/ not logged as /private_<redacted>/mcp/: $A"
printf '%s\n' "$A" | grep -qE '"GET /api/health HTTP/1\.1" 200 ' || fail "probe not logged under its original path /api/health: $A"
[ "$(printf '%s\n' "$A" | grep -c 'private_' || true)" = "1" ] || fail "/private_<tok>/mcp (access_log off) appears in the access log: $A"
L="$(leaks "$R")"; [ -z "$L" ] || fail "log(s) still carry credential(s): $L — $R"

# mcp container down → 502; the error log must not carry the token.
DOWN_REQS=("/mcp?token=SECRETQUERY6" "/private_SECRETPATH7/mcp")
R2="$(run "$LMAIN" "$LCONF" "$MCP_DOWN_PORT" "502 502" "${DOWN_REQS[@]}")"
L2="$(leaks "$R2")"; [ -z "$L2" ] || fail "mcp down: log(s) carry credential(s): $L2 — $R2"

# controls — the harness must see both leaks without the fix
CTRL_MAIN="$(printf '%s\n' "$LMAIN" | sed -E 's#"\$request_method \$woow_log_path \$server_protocol"#"$request"#')"
[ "$CTRL_MAIN" != "$LMAIN" ] || fail "test harness: control could not swap the request field (log_format shape changed?)"
C1="$(run "$CTRL_MAIN" "$LCONF" "$MCP_UP_PORT" "200 200 401 200" "${UP_REQS[@]}")"
printf '%s\n' "$(section "$C1" access)" | grep -qF SECRETQUERY1 || fail "control: the old \"\$request\" format did not log ?token= — the live check is not exercising the leak"
CTRL_CONF="$(printf '%s\n' "$LCONF" | grep -vE '^[[:space:]]*error_log[[:space:]]+/dev/null;')"
C2="$(run "$LMAIN" "$CTRL_CONF" "$MCP_DOWN_PORT" "502 502" "${DOWN_REQS[@]}")"
printf '%s\n' "$(section "$C2" error)" | grep -qF SECRETPATH7 || fail "control: without error_log /dev/null the error log did not show the token path — the live check is not exercising the leak"

echo "PASS (od-log-redaction): $STATIC_OK; live: /mcp?token= logged as /mcp, /private_<tok>/mcp absent, near-miss masked, /api/health original path, referer query cut, mcp-down error log clean (controls leak)"
