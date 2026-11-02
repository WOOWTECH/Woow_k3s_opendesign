#!/usr/bin/env bash
#
# Built-in OpenDesign MCP server (chart 0.5.0, values `mcp.*`; image runtime: paas-odoo-ci
# open-design/mcp-runtime = the HA add-on's built-in MCP runtime):
#   - default (mcp.enabled=false) and a --reuse-values upgrade from <= 0.4.x (no `mcp` key at all):
#     nothing rendered — no `mcp` container, no od-mcp-run volume, no /mcp* nginx locations
#   - mcp.enabled=true: sidecar `mcp` = the daemon image, command /opt/woow/bin/paas-opendesign-mcp,
#     uid/gid 10001, read-only root FS, all capabilities dropped, no privilege escalation, no probes
#     (pod readiness stays the auth proxy's), no secret / envFrom, only the three WOOW_OD_* settings;
#     state = od-data subPath at /data/mcp; od-mcp-run emptyDir (Memory) mounted by mcp + authproxy
#     ONLY (never the daemon container)
#   - nginx: /mcp and /private_<token>/mcp → 127.0.0.1:<mcp.port> WITHOUT basic-auth, the secret path
#     never logged; /mcp-admin/ behind basic-auth → admin.sock with X-Remote-User-Id = $remote_user
#     (client value overwritten), X-Ingress-Path /mcp-admin, Origin cleared; /mcp-admin → 301
#   - WOOW_OD_MCP_PUBLIC_ORIGIN = first plain origin of config.allowedOrigins ("*" / none → unset)
#   - mcp.port follows into env and nginx; guards: authProxy off, bad dataSubPath, clashing port → render fails
#   - workspace quota: with the platform's values every container's memory limit fits even a 9Gi quota
#     (the platform gives a single Open Design 10Gi: min_ram_gb 3.5 × 3 = 10.5, int-truncated → 10Gi)
#
# Usage:    bash charts/open-design/tests/test-mcp.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (mcp): yq (mikefarah) required"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
yy() { yq "$1" "$2" 2>/dev/null | grep -v -e '^---$' -e '^$' | head -n 1; }
cnt() { yq "$1" "$2" 2>/dev/null | grep -v -e '^---$' -e '^$' | wc -l | tr -d ' '; }
render() { local out=$1; shift; "$HELM" template t "$CHART_DIR" --namespace paas-ws-test "$@" >"$out" 2>"$out.err"; }
STS='select(.kind == "StatefulSet" and .metadata.name == "t-open-design") | .spec.template.spec'
MCP="$STS | .containers[] | select(.name == \"mcp\")"
CONF='select(.kind == "ConfigMap" and .metadata.name == "t-open-design-authproxy") | .data."default.conf"'
mounts_of() { yy "$STS | .containers[] | select(.name == \"$1\") | [.volumeMounts[] | select(.name == \"od-mcp-run\") | .mountPath] | join(\",\")" "$2"; }

echo "== default: nothing of the MCP server"
R=$TMP/default.yaml
render "$R" || { cat "$R.err"; exit 1; }
t "no mcp container" "$(cnt "$MCP | .name" "$R")" "0"
t "no od-mcp-run volume" "$(cnt "$STS | .volumes[] | select(.name == \"od-mcp-run\") | .name" "$R")" "0"
yq "$CONF" "$R" > "$TMP/default.conf"
t "no /mcp* nginx location" "$(grep -c -E 'location (= /mcp|~ "\^/private_|\^~ /mcp-admin/|= /mcp-admin)' "$TMP/default.conf" || true)" "0"

echo "== --reuse-values from <= 0.4.x (no mcp key): renders as disabled"
R0=$TMP/reuse.yaml
render "$R0" --set mcp=null || { cat "$R0.err"; exit 1; }
t "mcp=null: no mcp container" "$(cnt "$MCP | .name" "$R0")" "0"

echo "== mcp.enabled=true (platform 0.5.0 values)"
R1=$TMP/on.yaml
render "$R1" --set mcp.enabled=true --set image.tag=20991231.0000 \
  --set-string 'config.allowedOrigins=https://od-x.woowtech.io\,https://custom.example.com' || { cat "$R1.err"; exit 1; }
t "containers" "$(yy "$STS | [.containers[].name] | join(\",\")" "$R1")" "open-design,mcp,authproxy"
t "same image as the daemon" "$(yy "$MCP | .image" "$R1")" "$(yy "$STS | .containers[] | select(.name == \"open-design\") | .image" "$R1")"
t "command" "$(yy "$MCP | .command | join(\" \")" "$R1")" "/opt/woow/bin/paas-opendesign-mcp"
t "no args" "$(cnt "$MCP | .args[]" "$R1")" "0"
t "runAsUser 10001" "$(yy "$MCP | .securityContext.runAsUser" "$R1")" "10001"
t "runAsGroup 10001" "$(yy "$MCP | .securityContext.runAsGroup" "$R1")" "10001"
t "runAsNonRoot" "$(yy "$MCP | .securityContext.runAsNonRoot" "$R1")" "true"
t "readOnlyRootFilesystem" "$(yy "$MCP | .securityContext.readOnlyRootFilesystem" "$R1")" "true"
t "allowPrivilegeEscalation false" "$(yy "$MCP | .securityContext.allowPrivilegeEscalation" "$R1")" "false"
t "capabilities drop ALL" "$(yy "$MCP | .securityContext.capabilities.drop | join(\",\")" "$R1")" "ALL"
t "seccomp RuntimeDefault" "$(yy "$MCP | .securityContext.seccompProfile.type" "$R1")" "RuntimeDefault"
t "no probes (pod readiness stays the auth proxy's)" \
  "$(cnt "$MCP | (.readinessProbe, .livenessProbe, .startupProbe) | select(. != null) | kind" "$R1")" "0"
t "env names (only the three settings)" "$(yy "$MCP | [.env[].name] | join(\",\")" "$R1")" \
  "WOOW_OD_BACKEND_URL,WOOW_OD_MCP_PORT,WOOW_OD_MCP_PUBLIC_ORIGIN"
t "no secret reaches the mcp container" "$(cnt "$MCP | (.env[] | select(.valueFrom != null) | .name), (.envFrom[]? | kind)" "$R1")" "0"
t "backend = daemon over loopback" "$(yy "$MCP | .env[] | select(.name == \"WOOW_OD_BACKEND_URL\") | .value" "$R1")" "http://127.0.0.1:7457"
t "MCP port" "$(yy "$MCP | .env[] | select(.name == \"WOOW_OD_MCP_PORT\") | .value" "$R1")" "8081"
t "public origin = first allowedOrigins entry" "$(yy "$MCP | .env[] | select(.name == \"WOOW_OD_MCP_PUBLIC_ORIGIN\") | .value" "$R1")" "https://od-x.woowtech.io"
t "state = od-data subPath .woow-mcp at /data/mcp" \
  "$(yy "$MCP | .volumeMounts[] | select(.name == \"od-data\") | [.mountPath, .subPath] | join(\" \")" "$R1")" "/data/mcp .woow-mcp"
t "mcp mounts od-mcp-run" "$(mounts_of mcp "$R1")" "/run/od-mcp"
t "authproxy mounts od-mcp-run" "$(mounts_of authproxy "$R1")" "/run/od-mcp"
t "daemon container does NOT mount od-mcp-run" "$(mounts_of open-design "$R1")" ""
t "od-mcp-run = Memory emptyDir" "$(yy "$STS | .volumes[] | select(.name == \"od-mcp-run\") | .emptyDir.medium" "$R1")" "Memory"
t "mcp limits" "$(yy "$MCP | .resources.limits | [.cpu, .memory] | join(\" \")" "$R1")" "500m 320Mi"
t "mcp requests" "$(yy "$MCP | .resources.requests | [.cpu, .memory] | join(\" \")" "$R1")" "50m 160Mi"
t "ephemeral-storage limit set (#1434)" "$(yy "$MCP | .resources.limits.\"ephemeral-storage\"" "$R1")" "128Mi"

echo "== nginx locations"
yq "$CONF" "$R1" > "$TMP/on.conf"
block() { awk -v start="$1" 'index($0, start) { p = 1 } p { print } p && /^  }$/ { exit }' "$TMP/on.conf"; }
B=$(block 'location = /mcp {')
case "$B" in *'auth_basic off;'*'proxy_pass http://127.0.0.1:8081;'*'proxy_buffering off;'*) ok "/mcp → 127.0.0.1:8081, basic-auth off, unbuffered" ;; *) bad "/mcp location: $B" ;; esac
case "$B" in *'access_log off'*) bad "/mcp needs no log suppression (no secret in the path)" ;; *) ok "/mcp is logged (no secret in its path)" ;; esac
B=$(block 'location ~ "^/private_[A-Za-z0-9_-]{1,128}/mcp$" {')
case "$B" in *'auth_basic off;'*'access_log off;'*'proxy_pass http://127.0.0.1:8081;'*) ok "/private_<token>/mcp → 8081, basic-auth off, never logged (#1614)" ;; *) bad "/private location: $B" ;; esac
B=$(block 'location ^~ /mcp-admin/ {')
case "$B" in *'auth_basic "Open Design";'*'auth_basic_user_file /etc/nginx/auth/.htpasswd;'*'proxy_pass http://unix:/run/od-mcp/admin.sock:/;'*'proxy_set_header Origin "";'*'proxy_set_header X-Remote-User-Id $remote_user;'*'proxy_set_header X-Ingress-Path /mcp-admin;'*)
  ok "/mcp-admin/ behind basic-auth → admin.sock, user = \$remote_user, Origin cleared" ;; *) bad "/mcp-admin/ location: $B" ;; esac
B=$(block 'location = /mcp-admin {')
case "$B" in *'auth_basic "Open Design";'*'absolute_redirect off;'*'return 301 /mcp-admin/;'*) ok "/mcp-admin → relative 301 (behind basic-auth)" ;; *) bad "/mcp-admin redirect: $B" ;; esac
# nginx ends an unquoted location token at "{": a regex with a {m,n} quantifier must be quoted.
t "no unquoted regex location with a {m,n} quantifier" "$(grep -cE '^[[:space:]]*location ~ [^"].*\{[0-9]' "$TMP/on.conf" || true)" "0"
# The regex matches exactly the secret paths (grep -P on a path list, both directions).
RE='^/private_[A-Za-z0-9_-]{1,128}/mcp$'
for p in /private_abcDEF012_-xyz/mcp "/private_$(printf 'a%.0s' $(seq 1 128))/mcp"; do
  grep -qP "$RE" <<<"$p" && ok "matches ${p:0:30}…" || bad "regex misses $p"
done
for p in /private_/mcp /private_a/mcp/ /private_a/b/mcp /private_a.b/mcp /xprivate_a/mcp "/private_$(printf 'a%.0s' $(seq 1 129))/mcp"; do
  if grep -qP "$RE" <<<"$p"; then bad "regex matches $p"; else ok "does not match ${p:0:30}"; fi
done
t "pod rolls when the nginx config changes" \
  "$( [ "$(yy "select(.kind == \"StatefulSet\") | .spec.template.metadata.annotations.\"checksum/authproxy-config\"" "$R1")" != "$(yy "select(.kind == \"StatefulSet\") | .spec.template.metadata.annotations.\"checksum/authproxy-config\"" "$R")" ] && echo changed)" "changed"

echo "== basic-auth disabled: /mcp-admin/ renders without auth_basic (the admin app then refuses: no user)"
R2=$TMP/nobasic.yaml
render "$R2" --set mcp.enabled=true --set authProxy.basicAuth.enabled=false || { cat "$R2.err"; exit 1; }
yq "$CONF" "$R2" > "$TMP/on.conf"
B=$(block 'location ^~ /mcp-admin/ {')
case "$B" in *'auth_basic "Open Design"'*) bad "basic-auth disabled but /mcp-admin/ still has auth_basic" ;; *'X-Remote-User-Id $remote_user'*) ok "/mcp-admin/ without basic-auth forwards an empty user" ;; *) bad "$B" ;; esac

echo "== public origin"
R3=$TMP/star.yaml
render "$R3" --set mcp.enabled=true --set config.allowedOrigins='*' || { cat "$R3.err"; exit 1; }
t "allowedOrigins=* → no WOOW_OD_MCP_PUBLIC_ORIGIN" "$(cnt "$MCP | .env[] | select(.name == \"WOOW_OD_MCP_PUBLIC_ORIGIN\") | .name" "$R3")" "0"
render "$R3" --set mcp.enabled=true --set config.allowedOrigins=' HTTPS://Od-Y.Example.com/ ' || { cat "$R3.err"; exit 1; }
t "origin normalised (trim, lower case, no trailing /)" "$(yy "$MCP | .env[] | select(.name == \"WOOW_OD_MCP_PUBLIC_ORIGIN\") | .value" "$R3")" "https://od-y.example.com"

echo "== mcp.port follows into env and nginx"
R4=$TMP/port.yaml
render "$R4" --set mcp.enabled=true --set mcp.port=9091 || { cat "$R4.err"; exit 1; }
t "env port" "$(yy "$MCP | .env[] | select(.name == \"WOOW_OD_MCP_PORT\") | .value" "$R4")" "9091"
t "nginx upstreams on 9091" "$(yq "$CONF" "$R4" | grep -c 'proxy_pass http://127.0.0.1:9091;' || true)" "2"

echo "== guards"
must_fail() { local what=$1; shift; if render "$TMP/f.yaml" "$@"; then bad "$what: render should fail"; else ok "$what: render fails"; fi; }
must_fail "mcp without the auth proxy" --set mcp.enabled=true --set authProxy.enabled=false --set config.bindHost=0.0.0.0
must_fail "dataSubPath with a slash" --set mcp.enabled=true --set mcp.dataSubPath=a/b
must_fail "dataSubPath with .." --set mcp.enabled=true --set mcp.dataSubPath=..
must_fail "mcp.port = daemon port" --set mcp.enabled=true --set mcp.port=7457
must_fail "mcp.port = auth proxy port" --set mcp.enabled=true --set mcp.port=8080
must_fail "mcp.port < 1024" --set mcp.enabled=true --set mcp.port=80

echo "== workspace quota: every container limit with the platform's values fits 9Gi (platform gives 10Gi: min_ram_gb 3.5)"
R5=$TMP/plan.yaml
render "$R5" --set mcp.enabled=true --set resources.limits.memory=8Gi --set resources.limits.cpu=4 \
  --set console.enabled=true || { cat "$R5.err"; exit 1; }
total=$(yq 'select(.kind == "StatefulSet" or .kind == "Deployment") | .spec.template.spec.containers[].resources.limits.memory' "$R5" \
  | grep -v -e '^---$' -e '^$' | awk '/Gi$/ { s += $0 * 1024; next } /Mi$/ { s += $0 + 0; next } { print "unknown unit " $0 > "/dev/stderr"; s += 1e9 } END { print s }')
quota=$(( 9 * 1024 ))
if [ "$total" -le "$quota" ]; then ok "limits ${total}Mi ≤ quota ${quota}Mi"; else bad "limits ${total}Mi exceed the 9Gi quota"; fi

[ "$rc" = 0 ] && echo "PASS (mcp): off by default and after --reuse-values; sidecar uid 10001 read-only, no secrets/probes, od-data subPath, od-mcp-run only in mcp+authproxy; /mcp + /private_<token>/mcp without basic-auth (secret path unlogged), /mcp-admin/ behind basic-auth with \$remote_user; public origin; port; guards; quota."
exit "$rc"
