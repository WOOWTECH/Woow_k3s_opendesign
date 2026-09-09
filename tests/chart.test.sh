#!/usr/bin/env bash
# Chart rendering lane.
#
# The whole reason this repo is being rewritten is that its chart was never
# actually installed: `helm install` was rejected by the API server because the
# nodeSelector carried a literal `__K3S_NODE_HOSTNAME__`. This lane makes that
# class of defect impossible to merge:
#
#   1. `helm lint` with the values a real install uses
#   2. `helm template` must SUCCEED with a public URL and FAIL without one
#   3. schema validation of every rendered object (kubeconform, when present)
#   4. server-side dry-run against woow-k3s (read-only, when a kubeconfig exists)
#   5. tests/chart-manifest.test.py — the property assertions
#
# Step 4 never mutates the cluster: `kubectl apply --dry-run=server` only asks
# the API server to admit-and-discard. There is no `apply` in this file.
set -Eeuo pipefail

# shellcheck source=lib/layout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/layout.sh"
cd "$REPO_ROOT"

require_command helm "chart lane"
require_paths "chart lane" \
  "$CHART_DIR/Chart.yaml" \
  "$CHART_DIR/values.yaml" \
  "$CHART_DIR/templates" \
  "$REPO_ROOT/tests/values/full.yaml" \
  "$REPO_ROOT/tests/values/minimal.yaml" \
  "$REPO_ROOT/tests/values/no-public-url.yaml"

mkdir -p "$ARTIFACTS"
namespace=${OD_TEST_NAMESPACE:-pi-agent-woow}
release=${OD_TEST_RELEASE:-od}

echo "== helm lint (full values) =="
helm lint "$CHART_DIR" --values tests/values/full.yaml
echo "== helm lint (minimal values, backup disabled) =="
helm lint "$CHART_DIR" --values tests/values/minimal.yaml

echo "== helm template must reject an empty publicUrl =="
if helm template "$release" "$CHART_DIR" --namespace "$namespace" \
     --values tests/values/no-public-url.yaml >/dev/null 2>"$ARTIFACTS/no-public-url.err"; then
  echo 'FAIL: the chart rendered with an empty publicUrl. OD_ALLOWED_ORIGINS and' >&2
  echo '      OD_PUBLIC_BASE_URL would be empty, silently disabling the CSRF' >&2
  echo '      defence the sidecar depends on. publicUrl must be required.' >&2
  exit 1
fi
echo "rejected as required: $(head -1 "$ARTIFACTS/no-public-url.err" 2>/dev/null || echo '(no message captured)')"

rendered="$ARTIFACTS/rendered.yaml"
require_paths "chart lane (run tests/lib/extract-chart-assets.py first)" "$rendered"

echo "== kubeconform =="
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -summary \
    -kubernetes-version "${OD_TEST_KUBE_VERSION:-1.34.5}" \
    "$rendered"
else
  echo "kubeconform: SKIP (not installed) — schema validation NOT performed"
fi

echo "== server-side dry-run (read-only) =="
# `apply --dry-run=server` asks the API server to admit-and-discard. It never
# persists anything, and it is the only check that catches a manifest the
# server refuses. An unreachable cluster is a SKIP; a reachable cluster that
# refuses an object is a FAILURE. Never confuse the two.
context_args=()
[[ -n "${OD_TEST_KUBE_CONTEXT:-}" ]] && context_args=(--context "$OD_TEST_KUBE_CONTEXT")
if ! command -v kubectl >/dev/null 2>&1; then
  echo "server dry-run: SKIP (kubectl not installed) — API-server admission NOT verified"
elif ! kubectl "${context_args[@]}" get --raw /version >/dev/null 2>"$ARTIFACTS/kube-probe.err"; then
  echo "server dry-run: SKIP (no reachable cluster) — API-server admission NOT verified"
  echo "  reason: $(head -1 "$ARTIFACTS/kube-probe.err" 2>/dev/null)"
  echo "  to run it: KUBECONFIG=<file> OD_TEST_KUBE_CONTEXT=woow-k3s bash tests/chart.test.sh"
elif kubectl "${context_args[@]}" -n "$namespace" apply --dry-run=server -f "$rendered"; then
  echo "server dry-run: the API server admits every object"
else
  echo 'FAIL: the API server rejected a rendered object. This is exactly the' >&2
  echo '      failure mode that shipped at HEAD 6f742b3 (a literal' >&2
  echo '      __K3S_NODE_HOSTNAME__ nodeSelector).' >&2
  exit 1
fi

echo "== rendered manifest assertions =="
python3 tests/chart-manifest.test.py

echo "chart lane: passed"
