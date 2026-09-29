#!/usr/bin/env bash
#
# Console contract:
#   - console.enabled=true (default) → console Deployment/Service/SA/Role/RoleBinding/ConfigMaps
#   - console.enabled=false → NONE of the above rendered (daemon only)
#   - baked mode (default) → image = console.image.*, command has NO downloads
#   - runtimeInstall=true → image = python:3.9-slim, command downloads ttyd/kubectl
#   - console env targets templatized (POD_LABEL/DAEMON_DEPLOYMENT match the release)
#   - RBAC Role resourceNames scoped to THIS release's daemon Deployment + Secret
#
# Usage:    bash charts/open-design/tests/test-console-toggle.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (console-toggle): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (console-toggle): $1"; exit 1; }

# console enabled by default → console Deployment present.
ON="$($HELM template t "$CHART_DIR" 2>/dev/null)"
CDEP="$(printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .metadata.name')"
[ "$CDEP" = "t-open-design-console" ] || fail "console Deployment missing when console.enabled=true"
for k in ServiceAccount Role RoleBinding Service; do
  n="$(printf '%s' "$ON" | yq "select(.kind==\"$k\" and .metadata.name==\"t-open-design-console\") | .metadata.name")"
  [ "$n" = "t-open-design-console" ] || fail "console $k missing when enabled"
done

# console disabled → NO console objects at all.
OFF="$($HELM template t "$CHART_DIR" --set console.enabled=false 2>/dev/null)"
LEFT="$(printf '%s' "$OFF" | yq -r 'select(.metadata.name != null) | .metadata.name' | grep -c 'console' || true)"
[ "$LEFT" = "0" ] || fail "console.enabled=false still rendered $LEFT console object(s)"

# baked mode (default): console image + no download in command.
CIMG="$(printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].image')"
[ "$CIMG" = "jcr-prod.woowtech.io/woow-paas-docker-local/open-design-console:latest" ] \
  || fail "baked console image='$CIMG', expected the open-design-console coordinate"
CCMD="$(printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].command[2]')"
printf '%s' "$CCMD" | grep -q 'dl.k8s.io' && fail "baked mode command contains a download (dl.k8s.io) — expected none"

# runtimeInstall=true: python base + bootstrap downloads.
RT="$($HELM template t "$CHART_DIR" --set console.runtimeInstall=true 2>/dev/null)"
RIMG="$(printf '%s' "$RT" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].image')"
[ "$RIMG" = "python:3.9-slim" ] || fail "runtimeInstall image='$RIMG', expected python:3.9-slim"
RCMD="$(printf '%s' "$RT" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].command[2]')"
printf '%s' "$RCMD" | grep -q 'dl.k8s.io' || fail "runtimeInstall command missing the kubectl download"

# console env targets templatized to THIS release.
POD_LABEL="$(printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].env[] | select(.name=="POD_LABEL") | .value')"
printf '%s' "$POD_LABEL" | grep -q 'app.kubernetes.io/instance=t' || fail "console POD_LABEL not templatized to release (got '$POD_LABEL')"
DDEP="$(printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].env[] | select(.name=="DAEMON_DEPLOYMENT") | .value')"
[ "$DDEP" = "t-open-design" ] || fail "console DAEMON_DEPLOYMENT='$DDEP', expected t-open-design"

# RBAC resourceNames scoped to the release's daemon Deployment + Secret.
DEPRN="$(printf '%s' "$ON" | yq 'select(.kind=="Role") | .rules[] | select(.resources[0]=="deployments") | .resourceNames[0]')"
[ "$DEPRN" = "t-open-design" ] || fail "Role deployment resourceName='$DEPRN', expected t-open-design"
SECRN="$(printf '%s' "$ON" | yq 'select(.kind=="Role") | .rules[] | select(.resources[0]=="secrets") | .resourceNames[0]')"
[ "$SECRN" = "t-open-design-secrets" ] || fail "Role secret resourceName='$SECRN', expected t-open-design-secrets"

echo "PASS (console-toggle): enable/disable, baked vs runtimeInstall, env targets templatized, RBAC scoped by name."
