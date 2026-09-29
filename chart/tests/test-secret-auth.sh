#!/usr/bin/env bash
#
# Auth contract (Option C — issue #380 comment 2650):
#   - ConfigMap must NOT contain OD_DISABLE_API_AUTH; carries OD_PORT/OD_BIND_HOST/ORIGINS
#   - OD_BIND_HOST is loopback (127.0.0.1) by default — daemon only reachable via the proxy
#   - chart Secret carries admin_password (tenant credential) + OD_API_TOKEN (internal)
#   - config.sensitive.admin_password pin honoured (platform #357 injection point)
#   - daemon OD_API_TOKEN env is optional (loopback-exempt); sourced from the Secret
#   - auth.existingSecret → chart creates NO Secret; daemon refs the external one
#
# Usage:    bash charts/open-design/tests/test-secret-auth.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (secret-auth): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (secret-auth): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"

CM="$(printf '%s' "$OUT" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-config")')"
[ -n "$CM" ] || fail "no daemon ConfigMap rendered"
HASDISABLE="$(printf '%s' "$CM" | yq '.data | has("OD_DISABLE_API_AUTH")')"
[ "$HASDISABLE" = "false" ] || fail "ConfigMap contains OD_DISABLE_API_AUTH — auth must stay ON (拍板)"
ODPORT="$(printf '%s' "$CM" | yq '.data.OD_PORT')"
[ "$ODPORT" = "7457" ] || fail "ConfigMap OD_PORT='$ODPORT', expected 7457"
BINDHOST="$(printf '%s' "$CM" | yq '.data.OD_BIND_HOST')"
[ "$BINDHOST" = "127.0.0.1" ] || fail "ConfigMap OD_BIND_HOST='$BINDHOST', expected 127.0.0.1 (Option C loopback)"

# chart Secret present + carries admin_password + OD_API_TOKEN, NOT TUI_PASSWORD.
SEC="$(printf '%s' "$OUT" | yq 'select(.kind=="Secret" and .metadata.name=="t-open-design-secrets")')"
[ -n "$SEC" ] || fail "no chart Secret rendered by default"
for k in admin_password OD_API_TOKEN; do
  H="$(printf '%s' "$SEC" | yq ".stringData | has(\"$k\")")"
  [ "$H" = "true" ] || fail "chart Secret missing $k"
done
HASTUI="$(printf '%s' "$SEC" | yq '.stringData | has("TUI_PASSWORD")')"
[ "$HASTUI" = "false" ] || fail "chart Secret still carries TUI_PASSWORD (console now uses admin_password)"

# daemon injects OD_API_TOKEN as env from the Secret (optional — loopback-exempt).
ENVREF="$(printf '%s' "$OUT" \
  | yq 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.template.spec.containers[0].env[] | select(.name=="OD_API_TOKEN") | .valueFrom.secretKeyRef.name')"
[ "$ENVREF" = "t-open-design-secrets" ] || fail "daemon OD_API_TOKEN secretRef='$ENVREF', expected t-open-design-secrets"

# config.sensitive.admin_password pin honoured (platform #357 injection point).
PIN="$($HELM template t "$CHART_DIR" --set config.sensitive.admin_password=PINNED_PW 2>/dev/null \
  | yq 'select(.kind=="Secret" and .metadata.name=="t-open-design-secrets") | .stringData.admin_password')"
[ "$PIN" = "PINNED_PW" ] || fail "config.sensitive.admin_password pin not honoured (got '$PIN')"

# existingSecret → NO chart Secret, daemon refs the external one.
EXT="$($HELM template t "$CHART_DIR" --set auth.existingSecret=od-ext 2>/dev/null)"
EXTSEC="$(printf '%s' "$EXT" | yq 'select(.kind=="Secret" and .metadata.name=="t-open-design-secrets") | .metadata.name')"
[ -z "$EXTSEC" ] || fail "existingSecret set but chart still rendered its own Secret"
EXTREF="$(printf '%s' "$EXT" | yq 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.template.spec.containers[0].env[] | select(.name=="OD_API_TOKEN") | .valueFrom.secretKeyRef.name')"
[ "$EXTREF" = "od-ext" ] || fail "daemon OD_API_TOKEN secretRef='$EXTREF', expected od-ext"

echo "PASS (secret-auth): no OD_DISABLE_API_AUTH, loopback bind, admin_password+OD_API_TOKEN in Secret, #357 pin honoured, existingSecret suppresses chart Secret."
