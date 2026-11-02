#!/usr/bin/env bash
#
# Console contract:
#   - console.enabled=true (default) → console Deployment/Service/SA/Role/RoleBinding/ConfigMaps
#   - console.enabled=false → NONE of the above rendered (daemon only)
#   - baked mode (default) → image = console.image.*, command has NO downloads
#   - runtimeInstall=true → image = python:3.9-slim, command downloads ttyd/kubectl
#   - console env targets templatized (DAEMON_POD/DAEMON_STATEFULSET match the release)
#   - #1360: EVERY Role rule is pinned by resourceNames to this release's objects —
#     pods / pods/exec / pods/log to the daemon pod <fullname>-0 (StatefulSet), the
#     statefulset by name; no Secret access (0.5.3); no list/watch/*; no label selectors
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
cenv() { printf '%s' "$ON" | yq 'select(.kind=="Deployment" and .metadata.name=="t-open-design-console") | .spec.template.spec.containers[0].env[] | select(.name=="'"$1"'") | .value'; }
[ "$(cenv DAEMON_POD)" = "t-open-design-0" ] || fail "console DAEMON_POD='$(cenv DAEMON_POD)', expected t-open-design-0"
[ "$(cenv DAEMON_STATEFULSET)" = "t-open-design" ] || fail "console DAEMON_STATEFULSET='$(cenv DAEMON_STATEFULSET)', expected t-open-design"
for gone in POD_LABEL DAEMON_DEPLOYMENT DAEMON_SERVICE; do
  [ -z "$(cenv $gone)" ] || fail "console env $gone must be gone (#1360: fixed pod name, no discovery)"
done
# The pod name the console targets IS the StatefulSet's ordinal-0 pod.
STS="$(printf '%s' "$ON" | yq 'select(.kind=="StatefulSet" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .metadata.name')"
[ "$STS-0" = "$(cenv DAEMON_POD)" ] || fail "DAEMON_POD does not match the daemon StatefulSet ordinal 0 ('$STS')"

# #1360: every rule pinned by name — no namespace-wide grant of any kind.
ROLE="$(printf '%s' "$ON" | yq 'select(.kind=="Role")')"
UNPINNED="$(printf '%s' "$ROLE" | yq '[.rules[] | select((.resourceNames // []) | length == 0)] | length')"
[ "$UNPINNED" = "0" ] || fail "console Role has $UNPINNED rule(s) without resourceNames — namespace-wide (#1360)"
printf '%s' "$ROLE" | yq '.rules[].verbs[]' | grep -qxE 'list|watch|\*' && fail "console Role must not list/watch/* anything (#1360)"
rn() { printf '%s' "$ROLE" | yq '.rules[] | select(.resources[0]=="'"$1"'") | .resourceNames | join(",")'; }
for r in pods pods/exec pods/log; do
  [ "$(rn $r)" = "t-open-design-0" ] || fail "Role $r resourceNames='$(rn $r)', expected t-open-design-0 only"
done
[ "$(rn statefulsets)" = "t-open-design" ] || fail "Role statefulsets resourceNames='$(rn statefulsets)', expected t-open-design"
[ -z "$(rn secrets)" ] || fail "Role must not grant secrets (console-ttyd-exposure, 0.5.3)"
[ -z "$(rn deployments)$(rn endpoints)" ] || fail "Role must not grant deployments/endpoints any more"
RES="$(printf '%s' "$ROLE" | yq '[.rules[].resources[]] | sort | join(",")')"
[ "$RES" = "pods,pods/exec,pods/log,statefulsets" ] || fail "unexpected Role resources '$RES'"
# fullnameOverride flows into every pinned name.
FO="$($HELM template t "$CHART_DIR" --set fullnameOverride=od 2>/dev/null | yq 'select(.kind=="Role") | .rules[] | select(.resources[0]=="pods/exec") | .resourceNames[0]')"
[ "$FO" = "od-0" ] || fail "fullnameOverride: pods/exec resourceName='$FO', expected od-0"
# A name too long for a StatefulSet fails the render instead of breaking the rollout.
if $HELM template t "$CHART_DIR" --set fullnameOverride="$(printf 'a%.0s' $(seq 1 53))" >/dev/null 2>&1; then
  fail "a 53-character fullname must fail the render (StatefulSet name limit)"
fi
SCRIPTS="$(printf '%s' "$ON" | yq 'select(.kind=="ConfigMap" and .metadata.name=="t-open-design-console-scripts") | .data | to_entries | .[].value')"
# here-strings, not `printf | grep -q`: under pipefail an early grep exit SIGPIPEs printf.
grep -qE '"-l"|get pods? -l|get endpoints|get pods(\s|")' <<<"$SCRIPTS" && fail "console scripts must only address the fixed daemon pod (no -l / listing)"
grep -q '"statefulset/%s" % DAEMON_STATEFULSET' <<<"$SCRIPTS" || fail "console restart must target the daemon StatefulSet"
grep -q 'POD="${DAEMON_POD' <<<"$SCRIPTS" || fail "connect.sh must use DAEMON_POD"

echo "PASS (console-toggle): enable/disable, baked vs runtimeInstall, env targets templatized, every RBAC rule pinned to the daemon pod / own objects (#1360)."
