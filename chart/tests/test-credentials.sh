#!/usr/bin/env bash
#
# Tenant credential contract (0.2.0):
#   - authProxy.basicAuth.username is tenant-changeable from the platform; the
#     SAME value reaches the auth-proxy htpasswd init (BASIC_USER) and the
#     console (CONSOLE_BASIC_USER → ttyd -c + Flask dashboard)
#   - an unsafe username (':' / whitespace / empty / too long) FAILS the render
#     instead of silently splitting the htpasswd / ttyd credential
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

# Default username stays "admin" on both surfaces.
OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
U1="$(printf '%s' "$OUT" | yq "$daemon"' | .spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .env[] | select(.name=="BASIC_USER") | .value')"
[ "$U1" = "admin" ] || fail "default BASIC_USER='$U1', expected admin"

# A custom username reaches BOTH the htpasswd init and the console.
OUT="$($HELM template t "$CHART_DIR" --set authProxy.basicAuth.username=design.team@woow 2>/dev/null)"
U1="$(printf '%s' "$OUT" | yq "$daemon"' | .spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .env[] | select(.name=="BASIC_USER") | .value')"
U2="$(printf '%s' "$OUT" | yq "$console"' | .spec.template.spec.containers[0].env[] | select(.name=="CONSOLE_BASIC_USER") | .value')"
[ "$U1" = "design.team@woow" ] || fail "custom BASIC_USER='$U1'"
[ "$U2" = "design.team@woow" ] || fail "custom CONSOLE_BASIC_USER='$U2' (console must share the daemon credential)"

# Unsafe usernames must fail the render (helm keeps the previous release).
LONG="$(printf 'a%.0s' $(seq 1 65))"
for bad in 'a:b' 'a b' '' "$LONG" 'tab	x' 'ünïcode'; do
  if $HELM template t "$CHART_DIR" --set-string "authProxy.basicAuth.username=$bad" >/dev/null 2>&1; then
    fail "username '$bad' rendered — must be rejected"
  fi
done

# OpenRouter key: absent by default, present when set, env ref always optional.
OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
H="$(printf '%s' "$OUT" | yq "$secret"' | .stringData | has("OPENROUTER_API_KEY")')"
[ "$H" = "false" ] || fail "OPENROUTER_API_KEY in Secret although auth.openrouterApiKey is empty"
OPT="$(printf '%s' "$OUT" | yq "$daemon"' | .spec.template.spec.containers[0].env[] | select(.name=="OPENROUTER_API_KEY") | .valueFrom.secretKeyRef.optional')"
[ "$OPT" = "true" ] || fail "daemon OPENROUTER_API_KEY env must be an optional secretKeyRef (got '$OPT')"

OUT="$($HELM template t "$CHART_DIR" --set auth.openrouterApiKey=sk-or-test 2>/dev/null)"
V="$(printf '%s' "$OUT" | yq "$secret"' | .stringData.OPENROUTER_API_KEY')"
[ "$V" = "sk-or-test" ] || fail "auth.openrouterApiKey not rendered into the Secret (got '$V')"

echo "PASS (credentials): username shared by htpasswd + console, unsafe usernames rejected, OpenRouter key optional."
