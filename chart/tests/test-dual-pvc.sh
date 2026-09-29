#!/usr/bin/env bash
#
# Dual-PVC contract:
#   - two PVCs: <fullname>-data (8Gi → /app/.od) + <fullname>-home (2Gi → /home/opendesign)
#   - accessModes ReadWriteOnce
#   - storageClass OMITTED when empty (cluster default) / present when set
#   - platform storageClass injection works per-volume
#
# Usage:    bash charts/open-design/tests/test-dual-pvc.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (dual-pvc): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (dual-pvc): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"

DATA="$(printf '%s' "$OUT" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-data")')"
[ -n "$DATA" ] || fail "no data PVC (t-open-design-data) rendered"
DSIZE="$(printf '%s' "$DATA" | yq '.spec.resources.requests.storage')"
[ "$DSIZE" = "8Gi" ] || fail "data PVC size='$DSIZE', expected 8Gi"
DAM="$(printf '%s' "$DATA" | yq '.spec.accessModes[0]')"
[ "$DAM" = "ReadWriteOnce" ] || fail "data PVC accessMode='$DAM', expected ReadWriteOnce"

HOME="$(printf '%s' "$OUT" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-home")')"
[ -n "$HOME" ] || fail "no home PVC (t-open-design-home) rendered"
HSIZE="$(printf '%s' "$HOME" | yq '.spec.resources.requests.storage')"
[ "$HSIZE" = "2Gi" ] || fail "home PVC size='$HSIZE', expected 2Gi"

# storageClass omitted by default (empty → field absent → cluster default).
DSC="$(printf '%s' "$DATA" | yq '.spec | has("storageClassName")')"
[ "$DSC" = "false" ] || fail "data PVC storageClassName present by default (expected omitted)"

# platform injects storageClass via the FLAT persistence.storageClass key (the
# operator's _inject_storage_class target) → BOTH PVCs inherit it.
FLAT="$($HELM template t "$CHART_DIR" --set persistence.storageClass=longhorn-delete 2>/dev/null)"
FDATA="$(printf '%s' "$FLAT" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-data") | .spec.storageClassName')"
FHOME="$(printf '%s' "$FLAT" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-home") | .spec.storageClassName')"
[ "$FDATA" = "longhorn-delete" ] || fail "flat persistence.storageClass not inherited by data PVC (got '$FDATA')"
[ "$FHOME" = "longhorn-delete" ] || fail "flat persistence.storageClass not inherited by home PVC (got '$FHOME')"

# per-volume override wins over the flat key.
OVR="$($HELM template t "$CHART_DIR" --set persistence.storageClass=flat-sc --set persistence.data.storageClass=data-sc 2>/dev/null)"
ODATA="$(printf '%s' "$OVR" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-data") | .spec.storageClassName')"
OHOME="$(printf '%s' "$OVR" | yq 'select(.kind=="PersistentVolumeClaim" and .metadata.name=="t-open-design-home") | .spec.storageClassName')"
[ "$ODATA" = "data-sc" ] || fail "per-volume storageClass override not honoured (data got '$ODATA')"
[ "$OHOME" = "flat-sc" ] || fail "home PVC should inherit flat storageClass (got '$OHOME')"

echo "PASS (dual-pvc): data 8Gi /app/.od + home 2Gi /home/opendesign, RWO, flat storageClass inherited by both + per-vol override."
