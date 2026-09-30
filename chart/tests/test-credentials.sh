#!/usr/bin/env bash
#
# Tenant credential contract (0.2.1):
#   - authProxy.basicAuth.username is tenant-changeable from the platform; it is
#     rendered into the chart Secret (admin_username) and BOTH the auth-proxy
#     htpasswd init (BASIC_USER) and the console (CONSOLE_BASIC_USER → ttyd -c +
#     Flask dashboard) read it via secretKeyRef — one credential for both
#   - REGRESSION GUARD: changing the username must NOT change any pod template.
#     The operator resets credentials with `helm upgrade --atomic --timeout 15s`
#     (i.e. --wait); a pod-template change makes helm wait for new pods
#     (30-70 s), so every username change used to roll back after ~1 min of
#     downtime. With the username in the Secret only the Secret changes.
#   - auth.existingSecret keeps the literal value (an external Secret may not
#     carry admin_username)
#   - an unsafe username (':' / whitespace / empty / too long / non-ASCII)
#     FAILS the render instead of silently splitting the htpasswd / ttyd credential
#   - auth.openrouterApiKey is optional: absent → no Secret key; set → Secret key
#     OPENROUTER_API_KEY; the daemon env ref is always present and optional
#
# Usage:    bash charts/open-design/tests/test-credentials.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (credentials): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (credentials): $1"; exit 1; }

daemon='select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon")'
console='select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="console")'
secret='select(.kind=="Secret" and .metadata.name=="t-open-design-secrets")'

render() { $HELM template t "$CHART_DIR" "$@" 2>/dev/null; }
init_user() { yq "$daemon"' | .spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .env[] | select(.name=="BASIC_USER")'; }
console_user() { yq "$console"' | .spec.template.spec.containers[0].env[] | select(.name=="CONSOLE_BASIC_USER")'; }
templates() { yq 'select(.kind=="Deployment") | .spec.template'; }

# Default: username in the Secret; both consumers read it from there.
OUT="$(render)"
[ "$(printf '%s' "$OUT" | yq "$secret"' | .stringData.admin_username')" = "admin" ] || fail "Secret admin_username must default to admin"
for who in init_user console_user; do
  KEY="$(printf '%s' "$OUT" | $who | yq '.valueFrom.secretKeyRef.key')"
  [ "$KEY" = "admin_username" ] || fail "$who must come from secretKeyRef admin_username (got '$KEY')"
  [ "$(printf '%s' "$OUT" | $who | yq 'has("value")')" = "false" ] || fail "$who must not carry a literal value"
done

# Custom username reaches the Secret ...
CUSTOM="$(render --set authProxy.basicAuth.username=design.team@woow)"
[ "$(printf '%s' "$CUSTOM" | yq "$secret"' | .stringData.admin_username')" = "design.team@woow" ] \
  || fail "custom username did not reach the Secret"

# ... and every pod template (daemon AND console) is byte-identical.
[ "$(printf '%s' "$OUT" | templates)" = "$(printf '%s' "$CUSTOM" | templates)" ] \
  || fail "changing the username changed a pod template — the 15 s credential reset would roll back"

# existingSecret: literal value on both consumers.
EXT="$(render --set auth.existingSecret=od-ext --set authProxy.basicAuth.username=ops)"
[ "$(printf '%s' "$EXT" | init_user | yq '.value')" = "ops" ] || fail "existingSecret mode must keep the literal BASIC_USER"
[ "$(printf '%s' "$EXT" | console_user | yq '.value')" = "ops" ] || fail "existingSecret mode must keep the literal CONSOLE_BASIC_USER"

# Unsafe usernames must fail the render (helm keeps the previous release).
LONG="$(printf 'a%.0s' $(seq 1 65))"
for bad in 'a:b' 'a b' '' "$LONG" 'tab	x' 'ünïcode'; do
  if $HELM template t "$CHART_DIR" --set-string "authProxy.basicAuth.username=$bad" >/dev/null 2>&1; then
    fail "username '$bad' rendered — must be rejected"
  fi
done

# OpenRouter key: absent by default, present when set, env ref always optional.
H="$(printf '%s' "$OUT" | yq "$secret"' | .stringData | has("OPENROUTER_API_KEY")')"
[ "$H" = "false" ] || fail "OPENROUTER_API_KEY in Secret although auth.openrouterApiKey is empty"
OPT="$(printf '%s' "$OUT" | yq "$daemon"' | .spec.template.spec.containers[0].env[] | select(.name=="OPENROUTER_API_KEY") | .valueFrom.secretKeyRef.optional')"
[ "$OPT" = "true" ] || fail "daemon OPENROUTER_API_KEY env must be an optional secretKeyRef (got '$OPT')"
V="$(render --set auth.openrouterApiKey=sk-or-test | yq "$secret"' | .stringData.OPENROUTER_API_KEY')"
[ "$V" = "sk-or-test" ] || fail "auth.openrouterApiKey not rendered into the Secret (got '$V')"

echo "PASS (credentials): username in Secret for htpasswd + console, pod templates unchanged by a username change, existingSecret literal, unsafe usernames rejected, OpenRouter key optional."
