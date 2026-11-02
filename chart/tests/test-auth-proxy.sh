#!/usr/bin/env bash
#
# Auth-proxy contract (Option C — the tenant-facing gate; issue #380 comment 2650):
#   - daemon pod has an nginx sidecar `authproxy` on authProxy.port (8080); the
#     basic-auth htpasswd is the chart Secret's `htpasswd` key mounted as a Secret
#     VOLUME (no subPath → a password reset reaches nginx without a restart, #1360);
#     auth.existingSecret keeps the init container that renders it from admin_password
#   - daemon Service targetPort → proxy (not the daemon directly)
#   - nginx config: basic-auth on / , health/ready/version OPEN, proxy_pass loopback,
#     SSE-friendly (proxy_buffering off)
#   - console gate reuses admin_password (ttyd + Flask basic-auth = "同一閘")
#   - authProxy.enabled=false + bindHost=127.0.0.1 → render FAILS (footgun guard)
#   - authProxy.enabled=false + bindHost=0.0.0.0 → daemon direct, no sidecar
#   - /_woow/support → 302 whiteLabel.supportUrl (white label #1439), URL validated
#   - Host forwarded verbatim ($http_host, keeps the port; $host only without a Host
#     header) so a host:port URL in allowedOrigins is not 403'd (#1517)
#   - #1538: the daemon's loopback-only routes that the web UI calls get their own
#     regex location: same basic-auth gate, Origin checked by nginx against
#     config.allowedOrigins (or absent), then Host 127.0.0.1:<port> + Origin cleared;
#     daemon shutdown / db vacuum always 403; authProxy.localRoutes.enabled=false or a
#     missing map behave as specified; the route regex matches exactly the intended
#     paths (checked with grep -P against a path list, both directions)
#
# Usage:    bash charts/open-design/tests/test-auth-proxy.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (auth-proxy): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (auth-proxy): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="StatefulSet" and .metadata.name=="t-open-design")')"

# daemon CMD is overridden to enforce the loopback bind (image CMD hardcodes
# --host 0.0.0.0, which CLI>env would otherwise win).
DARGS="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].args | join(" ")')"
grep -q -- '--host 127.0.0.1' <<<"$DARGS" || fail "daemon args do not enforce --host 127.0.0.1 (got '$DARGS')"
# enforceBindHost=false → no args override (stub/alt image uses its own CMD).
NOARGS="$($HELM template t "$CHART_DIR" --set image.enforceBindHost=false 2>/dev/null \
  | yq 'select(.kind=="StatefulSet" and .metadata.name=="t-open-design") | .spec.template.spec.containers[0] | has("args")')"
[ "$NOARGS" = "false" ] || fail "image.enforceBindHost=false should NOT emit daemon args"

# nginx sidecar present on 8080.
SIDE="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .ports[0].containerPort')"
[ "$SIDE" = "8080" ] || fail "authproxy sidecar port='$SIDE', expected 8080"
# nginx liveness hits the nginx-LOCAL /healthz stub (NOT the daemon), readiness hits /api/health.
NLIVE="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .livenessProbe.httpGet.path')"
[ "$NLIVE" = "/healthz" ] || fail "nginx livenessProbe path='$NLIVE', expected /healthz (nginx-local, not the daemon)"
NREADY="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .readinessProbe.httpGet.path')"
[ "$NREADY" = "/api/health" ] || fail "nginx readinessProbe path='$NREADY', expected /api/health"

# chart-managed Secret: htpasswd is a Secret key, mounted as a directory (live reload).
HTK="$(printf '%s' "$DEP" | yq '.spec.template.spec.volumes[] | select(.name=="authproxy-auth") | .secret | [.secretName, .items[0].key, .items[0].path] | join(",")')"
[ "$HTK" = "t-open-design-secrets,htpasswd,.htpasswd" ] || fail "authproxy-auth must be the Secret key htpasswd → .htpasswd (got '$HTK')"
[ "$(yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .volumeMounts[] | select(.name=="authproxy-auth") | has("subPath")' <<<"$DEP")" = "false" ] \
  || fail "htpasswd must be mounted as a directory — a subPath mount never sees a password reset"
[ -z "$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .name')" ] \
  || fail "chart-managed Secret: no authproxy-init expected (htpasswd comes from the Secret)"
HTP="$($HELM template t "$CHART_DIR" --set authProxy.basicAuth.username=ops --set-string config.sensitive.admin_password=$'pw\r\nx' 2>/dev/null | yq 'select(.kind=="Secret") | .stringData.htpasswd')"
[ "$HTP" = "ops:{PLAIN}pwx" ] || fail "Secret htpasswd='$HTP', expected ops:{PLAIN}pwx (CR/LF stripped)"
# existingSecret: no htpasswd key available → init container renders it at start.
EXTD="$($HELM template t "$CHART_DIR" --set auth.existingSecret=od-ext 2>/dev/null | yq 'select(.kind=="StatefulSet" and .metadata.name=="t-open-design")')"
INITK="$(printf '%s' "$EXTD" | yq '.spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .env[] | select(.name=="ADMIN_PASSWORD") | .valueFrom.secretKeyRef | [.name, .key] | join(",")')"
[ "$INITK" = "od-ext,admin_password" ] || fail "existingSecret: authproxy-init ADMIN_PASSWORD ref='$INITK', expected od-ext,admin_password"
[ "$(printf '%s' "$EXTD" | yq '.spec.template.spec.volumes[] | select(.name=="authproxy-auth") | has("emptyDir")')" = "true" ] \
  || fail "existingSecret: authproxy-auth must be the init container's emptyDir"

# Service routes to the proxy, not the daemon.
SVCT="$(printf '%s' "$OUT" | yq 'select(.kind=="Service" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.ports[0].targetPort')"
[ "$SVCT" = "proxy" ] || fail "daemon Service targetPort='$SVCT', expected proxy"

# nginx config: basic-auth on / , health open, loopback proxy_pass, SSE off.
CONF="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
# PLAT-01: Cloudflare must not rewrite responses (e-mail obfuscation / injected
# scripts end up in exported HTML) → server-level Cache-Control: no-transform, on
# every status, and no location overrides add_header (which would drop it there).
grep -Eq '^[[:space:]]*add_header Cache-Control "no-transform" always;$' <<<"$CONF" || fail "nginx server block lacks add_header Cache-Control \"no-transform\" always (PLAT-01)"
# AI-FIX-SEC-1: the server block also carries the security headers (add_header ... $woow_h_*) and
# the 429 page (location @woow_locked) repeats them with its own no-store, no-transform. No OTHER
# location may set add_header — that would drop the server-level headers (no-transform included).
printf '%s' "$CONF" | python3 -c '
import re, sys
depth, loc_depth, loc, bad = 0, None, None, []
for line in sys.stdin.read().splitlines():
    code = line.split("#", 1)[0]
    m = re.match(r"\s*location\s+(.*?)\s*\{", code)
    if m and loc is None:
        loc, loc_depth = m.group(1), depth
    if loc is not None and "add_header" in code and loc != "@woow_locked":
        bad.append(loc)
    depth += code.count("{") - code.count("}")
    if loc is not None and depth <= loc_depth:
        loc = None
sys.exit("locations with their own add_header: %s" % sorted(set(bad)) if bad else 0)
' || fail "a location sets its own add_header → it would drop the server-level no-transform (PLAT-01)"
grep -Eq 'add_header Cache-Control "no-store, no-transform" always;' <<<"$CONF" || fail "the 429 page lost no-transform"
grep -q 'auth_basic_user_file /etc/nginx/auth/.htpasswd' <<<"$CONF" || fail "nginx config missing basic-auth user file"
grep -q 'listen 8080' <<<"$CONF" || fail "nginx not listening on 8080"
# AI-OD-007-3: /api/health|ready|version answer a caller WITHOUT credentials with a bare
# {"ok":true} (rewrite to the internal /_woow/probe, which only needs the daemon to answer 2xx);
# a caller WITH an Authorization header is checked against the htpasswd like any other.
for ep in health ready version; do
  printf '%s' "$CONF" | python3 -c '
import re, sys
conf, ep = sys.stdin.read(), sys.argv[1]
m = re.search(r"location = /api/%s \{(.*?)\n  \}" % ep, conf, re.S)
assert m, "no location for /api/" + ep
b = m.group(1)
assert "if ($od_probe_anon) { rewrite ^ /_woow/probe last; }" in b, "anonymous callers are not diverted to the bare probe"
assert "auth_basic_user_file /etc/nginx/auth/.htpasswd;" in b, "credentials are not checked"
assert "proxy_pass http://127.0.0.1:7457;" in b
' "$ep" || fail "/api/$ep: anonymous → bare probe, authenticated → basic-auth + daemon JSON"
done
grep -Eq 'map \$http_authorization \$od_probe_anon' <<<"$CONF" || fail "od_probe_anon map missing"
grep -q 'location = /_woow/probe-daemon' <<<"$CONF" || fail "internal daemon probe missing"
grep -Eq "return 200 '\{\"ok\":true\}" <<<"$CONF" || fail "bare probe body is not {\"ok\":true}"
grep -q 'proxy_pass http://127.0.0.1:7457' <<<"$CONF" || fail "nginx does not proxy_pass to the loopback daemon"
grep -q 'proxy_buffering off' <<<"$CONF" || fail "nginx missing SSE-friendly proxy_buffering off"
grep -Eq 'location = /healthz .*return 200' <<<"$CONF" || fail "nginx missing the local /healthz liveness stub"

# #1517: Host is forwarded VERBATIM ($http_host keeps the port; $host drops it and the
# daemon then rejects a host:port URL listed in allowedOrigins with 403 on
# /api/app-config). Every proxy_set_header Host uses the map var, whose default is
# $http_host and whose only fallback (no Host header) is $host. Here-strings, not
# `printf | grep -q` (pipefail + SIGPIPE flakes).
HOSTMAP="$(grep -A3 'map $http_host $od_upstream_host' <<<"$CONF" | tr '\n' ' ' | tr -s ' ')"
case "$HOSTMAP" in *'map $http_host $od_upstream_host { default $http_host; '"''"' $host; }'*) ;;
  *) fail "#1517: missing map \$http_host → \$od_upstream_host (default \$http_host, '' → \$host): '$HOSTMAP'" ;; esac
# #1538: the loopback-route location is the ONE place that sends a fixed loopback Host;
# every other proxied location keeps the verbatim map var.
NHOST="$(grep -c 'proxy_set_header Host ' <<<"$CONF" || true)"
NHOSTOK="$(grep -Ec '^[[:space:]]*proxy_set_header Host \$od_upstream_host;$' <<<"$CONF" || true)"
NHOSTLO="$(grep -Ec '^[[:space:]]*proxy_set_header Host 127\.0\.0\.1:7457;$' <<<"$CONF" || true)"
# 0.5.0: the built-in MCP admin page (/mcp-admin/ → admin.sock) sends the fixed Host localhost
# (a Unix-socket upstream, as in the HA add-on); only rendered with mcp.enabled (off by default).
NHOSTADM="$(grep -Ec '^[[:space:]]*proxy_set_header Host localhost;$' <<<"$CONF" || true)"
[ "$NHOSTLO" = "1" ] || fail "#1538: expected exactly 1 location sending Host 127.0.0.1:7457, got $NHOSTLO"
[ "$NHOSTADM" = "0" ] || fail "0.5.0: mcp.enabled=false must render no /mcp-admin/ location (got $NHOSTADM Host localhost)"
[ "$NHOST" -ge 1 ] && [ "$NHOST" = "$((NHOSTOK + NHOSTLO))" ] || fail "#1517: every other proxy_set_header Host must use \$od_upstream_host (got $NHOSTOK+$NHOSTLO of $NHOST)"
# mcp.enabled=true (the platform's 0.5.0 values): exactly one more fixed Host (localhost, /mcp-admin/);
# /mcp and /private_<token>/mcp set no Host; / and /console/ keep the verbatim map var.
CONFMCP="$($HELM template t "$CHART_DIR" --set mcp.enabled=true 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
NHOSTM="$(grep -c 'proxy_set_header Host ' <<<"$CONFMCP" || true)"
NHOSTMOK="$(grep -Ec '^[[:space:]]*proxy_set_header Host \$od_upstream_host;$' <<<"$CONFMCP" || true)"
NHOSTMLO="$(grep -Ec '^[[:space:]]*proxy_set_header Host 127\.0\.0\.1:7457;$' <<<"$CONFMCP" || true)"
NHOSTMADM="$(grep -Ec '^[[:space:]]*proxy_set_header Host localhost;$' <<<"$CONFMCP" || true)"
[ "$NHOSTMOK" = "2" ] && [ "$NHOSTMLO" = "1" ] && [ "$NHOSTMADM" = "1" ] && [ "$NHOSTM" = "4" ] \
  || fail "0.5.0 mcp.enabled: expected Host \$od_upstream_host×2 + 127.0.0.1:7457×1 + localhost×1 (/mcp-admin/), got $NHOSTMOK+$NHOSTMLO+$NHOSTMADM of $NHOSTM"
if grep -Eq 'proxy_set_header Host \$host;' <<<"$CONF"; then fail "#1517: proxy_set_header Host \$host drops the port"; fi
# The console /console/ location (ttyd) is included by default → both proxied paths covered.
[ "$NHOSTOK" = "2" ] || fail "#1517: expected 2 proxied locations with the verbatim Host (/ and /console/), got $NHOSTOK"
# console off: the remaining location still forwards the verbatim Host.
CONFNC="$($HELM template t "$CHART_DIR" --set console.enabled=false 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
[ "$(grep -Ec '^[[:space:]]*proxy_set_header Host \$od_upstream_host;$' <<<"$CONFNC" || true)" = "1" ] \
  || fail "#1517: console.enabled=false — location / must still forward Host \$od_upstream_host"

# ── #1538: loopback-only daemon routes ───────────────────────────────────────
LOOPRE_LINE="$(grep -E '^[[:space:]]*location ~ \^/api/\(\?:live-artifacts' <<<"$CONF" || true)"
[ -n "$LOOPRE_LINE" ] || fail "#1538: loopback-route location missing"
LOOPRE="$(sed -E 's/^[[:space:]]*location ~ //; s/[[:space:]]*\{[[:space:]]*$//' <<<"$LOOPRE_LINE")"
# The block of that location (up to its closing brace at the location indent).
LOOPBLK="$(awk '/location ~ \^\/api\/\(\?:live-artifacts/{f=1} f{print} f&&/^      }$/{exit}' <<<"$CONF")"
grep -q 'auth_basic_user_file /etc/nginx/auth/.htpasswd' <<<"$LOOPBLK" || fail "#1538: loopback routes must keep the basic-auth gate"
grep -Eq '^[[:space:]]*proxy_set_header Origin "";$' <<<"$LOOPBLK" || fail "#1538: loopback routes must clear Origin"
grep -Eq '^[[:space:]]*proxy_set_header Host 127\.0\.0\.1:7457;$' <<<"$LOOPBLK" || fail "#1538: loopback routes must send Host 127.0.0.1:7457 (not localhost: powered-preview origin)"
grep -q 'proxy_pass http://127.0.0.1:7457;' <<<"$LOOPBLK" || fail "#1538: loopback routes must proxy to the loopback daemon"
# The Origin check sits BEFORE proxying (if → return 403) and uses the map.
grep -q 'if ($od_local_route_origin_ok = 0) { return 403; }' <<<"$(tr -s ' \n' ' ' <<<"$LOOPBLK")" || fail "#1538: loopback routes must 403 a foreign Origin"
[ "$(grep -c 'proxy_set_header Origin' <<<"$CONF")" = "1" ] || fail "#1538: only the loopback-route location may touch Origin"
# Origin map: '' → 1, default 0, every config.allowedOrigins entry normalised, '*' dropped.
ORIGCONF="$($HELM template t "$CHART_DIR" --set-string 'config.allowedOrigins=https://od-a.example.com\, HTTPS://OD-B.example.com:8443/\,*' 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
OMAP="$(awk '/map \$http_origin \$od_local_route_origin_ok/{f=1} f{print} f&&/^}$/{exit}' <<<"$ORIGCONF" | tr -s ' \n' ' ')"
case "$OMAP" in *'map $http_origin $od_local_route_origin_ok { default 0; '"''"' 1; "https://od-a.example.com" 1; "https://od-b.example.com:8443" 1; }'*) ;;
  *) fail "#1538: Origin map wrong: '$OMAP'" ;; esac
# no allowedOrigins → only the empty Origin passes.
OMAP0="$(awk '/map \$http_origin \$od_local_route_origin_ok/{f=1} f{print} f&&/^}$/{exit}' <<<"$CONF" | tr -s ' \n' ' ')"
case "$OMAP0" in *'map $http_origin $od_local_route_origin_ok { default 0; '"''"' 1; }'*) ;;
  *) fail "#1538: Origin map without allowedOrigins must only accept an empty Origin: '$OMAP0'" ;; esac
# destructive maintenance routes are refused outright.
DENY="$(grep -A2 -E 'location ~ \^/api/daemon/\(\?:shutdown\|db/vacuum\)\$' <<<"$CONF" | tr -s ' \n' ' ')"
case "$DENY" in *'{ return 403; }'*) ;; *) fail "#1538: /api/daemon/shutdown and db/vacuum must be refused by nginx: '$DENY'" ;; esac
# The regex matches exactly the intended routes (PCRE ≈ nginx regex for this pattern).
if command -v grep >/dev/null && echo x | grep -qP 'x' 2>/dev/null; then
  MATCH=(
    /api/live-artifacts/la-1/preview /api/live-artifacts/la-1/refresh
    /api/plugins/example-fs-editorial-forest/duplicate-project
    /api/connectors/composio/config /api/connectors/auth-configs/prepare
    /api/connectors/github/connect /api/connectors/github/authorization/cancel /api/connectors/github/connection
    /api/diagnostics/export /api/diagnostics/chat-scroll-forensics /api/strategies/od-next/rollout
    /api/library/pair /api/library/connection /api/library/sync /api/library/assets/a1
    /api/library/assets/a1/apply /api/library/assets/a1/edit-as-page
    /api/memory/connectors/suggest /api/memory/connectors/extract
    /api/agents/deepseek-harness/companion/install /api/agents/antigravity/oauth-launch
  )
  NOMATCH=(
    /api/daemon/shutdown /api/daemon/db/vacuum /api/daemon/db/verify /api/plugins/events/purge
    /api/applied-plugins/export /api/applied-plugins/prune /api/diagnostics/amr-terminal-reports
    /api/library/pair/confirm /api/library/ingest /api/library/assets /api/library/assets/a1/raw
    /api/library/events /api/live-artifacts /api/live-artifacts/la-1 /api/live-artifacts/la-1/refreshes
    /api/connectors /api/connectors/status /api/connectors/oauth/callback/github /api/connectors/github
    /api/projects /api/app-config /api/plugins/a/b/duplicate-project /api/diagnostics/export/
    /x/api/diagnostics/export /api/library/assets/a/b/apply
  )
  for pth in "${MATCH[@]}"; do grep -qP -- "$LOOPRE" <<<"$pth" || fail "#1538: loopback regex must match $pth"; done
  for pth in "${NOMATCH[@]}"; do if grep -qP -- "$LOOPRE" <<<"$pth"; then fail "#1538: loopback regex must NOT match $pth"; fi; done
fi
# basicAuth off → the loopback location is not gated either (mirrors /), still checks Origin.
NBA="$($HELM template t "$CHART_DIR" --set authProxy.basicAuth.enabled=false 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
[ "$(grep -c 'auth_basic_user_file' <<<"$NBA" || true)" = "0" ] || fail "#1538: basicAuth.enabled=false must not reference the htpasswd anywhere"
grep -q 'if ($od_local_route_origin_ok = 0)' <<<"$NBA" || fail "#1538: basicAuth off must still check Origin on loopback routes"
# localRoutes off → none of it is rendered (0.4.3 behaviour).
LOFF="$($HELM template t "$CHART_DIR" --set authProxy.localRoutes.enabled=false 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
for needle in 'od_local_route_origin_ok' 'proxy_set_header Origin' 'proxy_set_header Host 127.0.0.1' 'api/daemon/(?:shutdown'; do
  if grep -qF -- "$needle" <<<"$LOFF"; then fail "#1538: localRoutes.enabled=false must not render '$needle'"; fi
done
# missing localRoutes map (--reuse-values from 0.4.3) → enabled.
LNULL="$($HELM template t "$CHART_DIR" --set authProxy.localRoutes=null 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
grep -q 'proxy_set_header Host 127.0.0.1:7457;' <<<"$LNULL" || fail "#1538: a missing authProxy.localRoutes map must default to enabled"
# the port follows service.targetPort.
P2="$($HELM template t "$CHART_DIR" --set service.targetPort=7999 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
grep -q 'proxy_set_header Host 127.0.0.1:7999;' <<<"$P2" || fail "#1538: loopback Host must follow service.targetPort"

# The pre-/console/ Home Assistant terminal path redirects to the console route (no auth needed for a redirect).
CONF="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
grep -Eq 'location = /terminal \{ +auth_basic off; +absolute_redirect off; +return 301 /console/; +\}' <<<"$(tr '\n' ' ' <<<"$CONF")" \
  || fail "/terminal must 301 to /console/"
grep -Eq 'location \^~ /terminal/ \{ +auth_basic off; +absolute_redirect off; +return 301 /console/; +\}' <<<"$(tr '\n' ' ' <<<"$CONF")" \
  || fail "/terminal/… must 301 to /console/"
CONFOFF="$($HELM template t "$CHART_DIR" --set console.externalPath= 2>/dev/null | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
grep -q 'location = /terminal' <<<"$CONFOFF" && fail "no console route → no /terminal redirect either"

# console gate reuses admin_password (ttyd + Flask basic-auth).
CTUI="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].env[] | select(.name=="TUI_PASSWORD") | .valueFrom.secretKeyRef.key')"
[ "$CTUI" = "admin_password" ] || fail "console TUI_PASSWORD key='$CTUI', expected admin_password (同一閘)"
SCRIPTS="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-console-scripts")')"
grep -q 'WWW-Authenticate' <<<"$(yq '.data."app.py"' <<<"$SCRIPTS")" || fail "console Flask app is missing the basic-auth gate"
# ttyd basic-auth uses the configurable user (not a hardcoded 'admin').
grep -q 'CONSOLE_BASIC_USER' <<<"$(yq '.data."entrypoint.py"' <<<"$SCRIPTS")" || fail "console ttyd does not use the configurable basic-auth user"

# #1439: /_woow/support answers with whiteLabel.supportUrl (no basic-auth), validated.
CONF="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
SUP="$(printf '%s' "$CONF" | grep -A3 'location = /_woow/support' | tr -s ' ' | tr '\n' ' ')"
case "$SUP" in *"auth_basic off;"*'return 302 "https://aiot.woowtech.io/woow";'*) ;; *) fail "/_woow/support redirect missing or wrong: '$SUP'" ;; esac
CUSTOM="$($HELM template t "$CHART_DIR" --set whiteLabel.supportUrl=https://help.example.com/od 2>/dev/null | grep -c 'return 302 "https://help.example.com/od";')"
[ "$CUSTOM" = "1" ] || fail "whiteLabel.supportUrl override not rendered"
for badurl in 'https://x.io/a;b' 'javascript:alert(1)' 'https://x.io/$host'; do
  if $HELM template t "$CHART_DIR" --set-string "whiteLabel.supportUrl=$badurl" >/dev/null 2>&1; then fail "whiteLabel.supportUrl=$badurl must fail the render"; fi
done

# footgun guard: authProxy off + loopback bind → FAIL.
if $HELM template t "$CHART_DIR" --set authProxy.enabled=false >/dev/null 2>&1; then
  fail "authProxy.enabled=false with default loopback bindHost should FAIL the render"
fi

# authProxy off + bindHost=0.0.0.0 → daemon direct, no sidecar, Service→http.
OFF="$($HELM template t "$CHART_DIR" --set authProxy.enabled=false --set config.bindHost=0.0.0.0 2>/dev/null)"
DEPOFF="$(printf '%s' "$OFF" | yq 'select(.kind=="StatefulSet" and .metadata.name=="t-open-design")')"
OFFC="$(printf '%s' "$DEPOFF" | yq '[.spec.template.spec.containers[].name] | join(",")')"
[ "$OFFC" = "open-design" ] || fail "authProxy off should leave only the daemon container (got '$OFFC')"
OFFT="$(printf '%s' "$OFF" | yq 'select(.kind=="Service" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.ports[0].targetPort')"
[ "$OFFT" = "http" ] || fail "authProxy off Service targetPort='$OFFT', expected http"

echo "PASS (auth-proxy): nginx sidecar :8080 + htpasswd Secret volume (init only for existingSecret), Service→proxy, basic-auth+health-exempt+SSE nginx, console 同一閘, Cache-Control no-transform (PLAT-01), Host verbatim \$http_host (#1517), loopback-only routes via Host 127.0.0.1 + Origin cleared after an allowedOrigins check, shutdown/vacuum refused (#1538), footgun guard, off-path reverts."
