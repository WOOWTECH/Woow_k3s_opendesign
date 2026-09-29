#!/usr/bin/env bash
#
# Auth-proxy contract (Option C — the tenant-facing gate; issue #380 comment 2650):
#   - daemon pod has an nginx sidecar `authproxy` on authProxy.port (8080) + an
#     init container that writes the basic-auth htpasswd from admin_password
#   - daemon Service targetPort → proxy (not the daemon directly)
#   - nginx config: basic-auth on / , health/ready/version OPEN, proxy_pass loopback,
#     SSE-friendly (proxy_buffering off)
#   - console gate reuses admin_password (ttyd + Flask basic-auth = "同一閘")
#   - authProxy.enabled=false + bindHost=127.0.0.1 → render FAILS (footgun guard)
#   - authProxy.enabled=false + bindHost=0.0.0.0 → daemon direct, no sidecar
#
# Usage:    bash charts/open-design/tests/test-auth-proxy.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (auth-proxy): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (auth-proxy): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design")')"

# daemon CMD is overridden to enforce the loopback bind (image CMD hardcodes
# --host 0.0.0.0, which CLI>env would otherwise win).
DARGS="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].args | join(" ")')"
printf '%s' "$DARGS" | grep -q -- '--host 127.0.0.1' || fail "daemon args do not enforce --host 127.0.0.1 (got '$DARGS')"
# enforceBindHost=false → no args override (stub/alt image uses its own CMD).
NOARGS="$($HELM template t "$CHART_DIR" --set image.enforceBindHost=false 2>/dev/null \
  | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design") | .spec.template.spec.containers[0] | has("args")')"
[ "$NOARGS" = "false" ] || fail "image.enforceBindHost=false should NOT emit daemon args"

# nginx sidecar present on 8080.
SIDE="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .ports[0].containerPort')"
[ "$SIDE" = "8080" ] || fail "authproxy sidecar port='$SIDE', expected 8080"
# nginx liveness hits the nginx-LOCAL /healthz stub (NOT the daemon), readiness hits /api/health.
NLIVE="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .livenessProbe.httpGet.path')"
[ "$NLIVE" = "/healthz" ] || fail "nginx livenessProbe path='$NLIVE', expected /healthz (nginx-local, not the daemon)"
NREADY="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="authproxy") | .readinessProbe.httpGet.path')"
[ "$NREADY" = "/api/health" ] || fail "nginx readinessProbe path='$NREADY', expected /api/health"

# init container writes htpasswd from admin_password.
INITK="$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .env[] | select(.name=="ADMIN_PASSWORD") | .valueFrom.secretKeyRef.key')"
[ "$INITK" = "admin_password" ] || fail "authproxy-init ADMIN_PASSWORD key='$INITK', expected admin_password"

# Service routes to the proxy, not the daemon.
SVCT="$(printf '%s' "$OUT" | yq 'select(.kind=="Service" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.ports[0].targetPort')"
[ "$SVCT" = "proxy" ] || fail "daemon Service targetPort='$SVCT', expected proxy"

# nginx config: basic-auth on / , health open, loopback proxy_pass, SSE off.
CONF="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-authproxy") | .data."default.conf"')"
printf '%s' "$CONF" | grep -q 'auth_basic_user_file /etc/nginx/auth/.htpasswd' || fail "nginx config missing basic-auth user file"
printf '%s' "$CONF" | grep -q 'listen 8080' || fail "nginx not listening on 8080"
printf '%s' "$CONF" | grep -Eq 'location = /api/health .*auth_basic off' || fail "/api/health not exempt from basic-auth"
printf '%s' "$CONF" | grep -q 'proxy_pass http://127.0.0.1:7457' || fail "nginx does not proxy_pass to the loopback daemon"
printf '%s' "$CONF" | grep -q 'proxy_buffering off' || fail "nginx missing SSE-friendly proxy_buffering off"
printf '%s' "$CONF" | grep -Eq 'location = /healthz .*return 200' || fail "nginx missing the local /healthz liveness stub"

# console gate reuses admin_password (ttyd + Flask basic-auth).
CTUI="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].env[] | select(.name=="TUI_PASSWORD") | .valueFrom.secretKeyRef.key')"
[ "$CTUI" = "admin_password" ] || fail "console TUI_PASSWORD key='$CTUI', expected admin_password (同一閘)"
SCRIPTS="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-console-scripts")')"
printf '%s' "$SCRIPTS" | yq '.data."app.py"' | grep -q 'WWW-Authenticate' || fail "console Flask app is missing the basic-auth gate"
# ttyd basic-auth uses the configurable user (not a hardcoded 'admin').
printf '%s' "$SCRIPTS" | yq '.data."entrypoint.py"' | grep -q 'CONSOLE_BASIC_USER' || fail "console ttyd does not use the configurable basic-auth user"

# footgun guard: authProxy off + loopback bind → FAIL.
if $HELM template t "$CHART_DIR" --set authProxy.enabled=false >/dev/null 2>&1; then
  fail "authProxy.enabled=false with default loopback bindHost should FAIL the render"
fi

# authProxy off + bindHost=0.0.0.0 → daemon direct, no sidecar, Service→http.
OFF="$($HELM template t "$CHART_DIR" --set authProxy.enabled=false --set config.bindHost=0.0.0.0 2>/dev/null)"
DEPOFF="$(printf '%s' "$OFF" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design")')"
OFFC="$(printf '%s' "$DEPOFF" | yq '[.spec.template.spec.containers[].name] | join(",")')"
[ "$OFFC" = "open-design" ] || fail "authProxy off should leave only the daemon container (got '$OFFC')"
OFFT="$(printf '%s' "$OFF" | yq 'select(.kind=="Service" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.ports[0].targetPort')"
[ "$OFFT" = "http" ] || fail "authProxy off Service targetPort='$OFFT', expected http"

echo "PASS (auth-proxy): nginx sidecar :8080 + htpasswd init, Service→proxy, basic-auth+health-exempt+SSE nginx, console 同一閘, footgun guard, off-path reverts."
