#!/usr/bin/env bash
#
# Daemon deployment contract: the invariants the platform/operator depend on.
#   - StatefulSet (#1360: fixed pod name <fullname>-0 for the console RBAC), one replica,
#     RollingUpdate (= delete-then-create for 1 replica, the dual RWO PVC guard that
#     Recreate gave the Deployment), Parallel pod management (a broken pod never
#     blocks the fix), PVCs referenced by claimName (no volumeClaimTemplates), and the
#     upgrade anti-affinity against the old Deployment pod
#   - container port 7457 (OD_PORT)
#   - image = image.repository:tag(|appVersion), overridable
#   - readiness + liveness httpGet /api/health
#   - podSecurityContext.fsGroup 1001
#   - dual volume mounts: /app/.od (data) + /home/opendesign (home)
#   - resources requests 1c/2Gi, limits 4c/8Gi; ephemeral-storage on every container (#1434)
#   - checksum/api-keys: an LLM key change rolls the daemon, a password change does not (#1435)
#
# Usage:    bash charts/open-design/tests/test-deployment-contract.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (deployment-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (deployment-contract): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="StatefulSet" and .metadata.labels."app.kubernetes.io/component"=="daemon")')"
[ -n "$DEP" ] || fail "no daemon Deployment rendered"

STRAT="$(printf '%s' "$DEP" | yq '[.spec.updateStrategy.type, .spec.podManagementPolicy, .spec.replicas, .spec.serviceName] | join(",")')"
[ "$STRAT" = "RollingUpdate,Parallel,1,t-open-design" ] || fail "StatefulSet updateStrategy/podManagementPolicy/replicas/serviceName='$STRAT'"
[ "$(printf '%s' "$DEP" | yq '.spec | has("volumeClaimTemplates")')" = "false" ] || fail "volumeClaimTemplates would orphan the existing PVCs — reference pvc.yaml by claimName"
AA="$(printf '%s' "$DEP" | yq '.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0] | [.topologyKey, .labelSelector.matchLabels."app.kubernetes.io/instance", .labelSelector.matchExpressions[0].key, .labelSelector.matchExpressions[0].operator] | join(",")')"
[ "$AA" = "kubernetes.io/hostname,t,pod-template-hash,Exists" ] || fail "upgrade anti-affinity against the old Deployment pod missing (got '$AA')"
if $HELM template t "$CHART_DIR" --set replicaCount=2 >/dev/null 2>&1; then fail "replicaCount=2 must fail the render"; fi

PORT="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].ports[0].containerPort')"
[ "$PORT" = "7457" ] || fail "containerPort='$PORT', expected 7457 (OD_PORT)"

# default tag is empty in values → falls back to Chart.appVersion.
APPVER="$(yq '.appVersion' "$CHART_DIR/Chart.yaml")"
IMG="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].image')"
[ "$IMG" = "jcr-prod.woowtech.io/woow-paas-docker-local/open-design:${APPVER}" ] \
  || fail "image='$IMG', expected jcr-prod.woowtech.io/woow-paas-docker-local/open-design:${APPVER} (tag falls back to appVersion)"

# image overridable via values (platform helm_default_values aligns image.*).
IMG2="$($HELM template t "$CHART_DIR" --set image.repository=example.com/od --set image.tag=dev 2>/dev/null \
  | yq 'select(.kind=="StatefulSet" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.template.spec.containers[0].image')"
[ "$IMG2" = "example.com/od:dev" ] || fail "override image='$IMG2', expected example.com/od:dev"

# Option C default (authProxy on): daemon binds loopback → exec liveness (curl
# 127.0.0.1/api/health); pod readiness comes from the nginx sidecar. No httpGet on
# the daemon (the kubelet can't reach a loopback-bound port).
LIVE="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].livenessProbe.exec.command | join(" ")')"
printf '%s' "$LIVE" | grep -q '/api/health' || fail "daemon livenessProbe exec does not curl /api/health (got '$LIVE')"
HASRP="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0] | has("readinessProbe")')"
[ "$HASRP" = "false" ] || fail "daemon should have NO readinessProbe under authProxy (nginx sidecar governs pod readiness)"

FSG="$(printf '%s' "$DEP" | yq '.spec.template.spec.securityContext.fsGroup')"
[ "$FSG" = "1001" ] || fail "podSecurityContext.fsGroup='$FSG', expected 1001"

DATA_MP="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].volumeMounts[] | select(.name=="od-data") | .mountPath')"
[ "$DATA_MP" = "/app/.od" ] || fail "od-data mountPath='$DATA_MP', expected /app/.od"
HOME_MP="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].volumeMounts[] | select(.name=="od-home") | .mountPath')"
[ "$HOME_MP" = "/home/opendesign" ] || fail "od-home mountPath='$HOME_MP', expected /home/opendesign"

CPU_REQ="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources.requests.cpu')"
[ "$CPU_REQ" = "1" ] || fail "resources.requests.cpu='$CPU_REQ', expected 1"
MEM_LIM="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources.limits.memory')"
[ "$MEM_LIM" = "8Gi" ] || fail "resources.limits.memory='$MEM_LIM', expected 8Gi"

# #1434: every container (incl. init + console) carries an ephemeral-storage request and
# limit — also when the platform pins only cpu/memory (Helm merges the maps).
PIN='{"resources":{"requests":{"cpu":"1","memory":"2Gi"},"limits":{"cpu":"4","memory":"8Gi"}}}'
for args in "" "--set-json resources=$PIN" "--set auth.existingSecret=ext"; do
  # shellcheck disable=SC2086
  R="$($HELM template t "$CHART_DIR" $args 2>/dev/null)"
  MISSING="$(printf '%s' "$R" | yq '(select(.kind=="StatefulSet" or .kind=="Deployment") | .spec.template.spec | (.initContainers // []) + .containers | .[] | select((.resources.limits | has("ephemeral-storage") | not) or (.resources.requests | has("ephemeral-storage") | not)) | .name)' | grep -v -e '^---$' -e '^$' || true)"
  [ -z "$MISSING" ] || fail "containers without ephemeral-storage request/limit ($args): $MISSING"
done
EPH="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].resources | [.requests."ephemeral-storage", .limits."ephemeral-storage"] | join(",")')"
[ "$EPH" = "1Gi,4Gi" ] || fail "daemon ephemeral-storage='$EPH', expected 1Gi,4Gi"

# #1435: an LLM API key change rolls the daemon (checksum/api-keys), a password change
# does not (the htpasswd Secret volume refreshes in place, #1360).
ck() { $HELM template t "$CHART_DIR" "$@" 2>/dev/null | yq 'select(.kind=="StatefulSet") | .spec.template.metadata.annotations."checksum/api-keys"'; }
C0="$(ck --set auth.openrouterApiKey=sk-or-a)"
[ -n "$C0" ] && [ "$C0" != "null" ] || fail "no checksum/api-keys annotation on the daemon pod template"
[ "$C0" != "$(ck --set auth.openrouterApiKey=sk-or-b)" ] || fail "OpenRouter key change does not change checksum/api-keys"
[ "$C0" != "$(ck --set auth.openrouterApiKey=sk-or-a --set auth.anthropicApiKey=sk-ant-x)" ] || fail "Anthropic key change does not change checksum/api-keys"
[ "$C0" = "$(ck --set auth.openrouterApiKey=sk-or-a --set config.sensitive.admin_password=other-pw)" ] || fail "admin_password change must NOT roll the daemon"
if $HELM template t "$CHART_DIR" --set auth.openrouterApiKey=sk-or-SECRET123 2>/dev/null | yq 'select(.kind=="StatefulSet")' | grep -q SECRET123; then
  fail "the API key value appears in the StatefulSet"
fi

echo "PASS (deployment-contract): StatefulSet RollingUpdate/Parallel/1 replica + upgrade anti-affinity, daemon :7457, image overridable, exec /api/health liveness, fsGroup 1001, dual mounts, 1c/2Gi–4c/8Gi, ephemeral-storage on every container (#1434), API-key checksum (#1435)."
