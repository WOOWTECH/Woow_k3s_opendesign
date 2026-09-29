#!/usr/bin/env bash
#
# Daemon deployment contract: the invariants the platform/operator depend on.
#   - strategy Recreate (dual RWO PVC Multi-Attach guard)
#   - container port 7457 (OD_PORT)
#   - image = image.repository:tag(|appVersion), overridable
#   - readiness + liveness httpGet /api/health
#   - podSecurityContext.fsGroup 1001
#   - dual volume mounts: /app/.od (data) + /home/opendesign (home)
#   - resources requests 1c/2Gi, limits 4c/8Gi
#
# Usage:    bash charts/open-design/tests/test-deployment-contract.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (deployment-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (deployment-contract): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon")')"
[ -n "$DEP" ] || fail "no daemon Deployment rendered"

STRAT="$(printf '%s' "$DEP" | yq '.spec.strategy.type')"
[ "$STRAT" = "Recreate" ] || fail "strategy.type='$STRAT', expected Recreate (RWO Multi-Attach guard)"

PORT="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].ports[0].containerPort')"
[ "$PORT" = "7457" ] || fail "containerPort='$PORT', expected 7457 (OD_PORT)"

# default tag is empty in values → falls back to Chart.appVersion.
APPVER="$(yq '.appVersion' "$CHART_DIR/Chart.yaml")"
IMG="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].image')"
[ "$IMG" = "jcr-prod.woowtech.io/woow-paas-docker-local/open-design:${APPVER}" ] \
  || fail "image='$IMG', expected jcr-prod.woowtech.io/woow-paas-docker-local/open-design:${APPVER} (tag falls back to appVersion)"

# image overridable via values (platform helm_default_values aligns image.*).
IMG2="$($HELM template t "$CHART_DIR" --set image.repository=example.com/od --set image.tag=dev 2>/dev/null \
  | yq 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon") | .spec.template.spec.containers[0].image')"
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

echo "PASS (deployment-contract): Recreate, daemon :7457, image overridable, exec /api/health liveness, fsGroup 1001, dual mounts, 1c/2Gi–4c/8Gi."
