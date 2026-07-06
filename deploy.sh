#!/bin/bash
set -euo pipefail

# =============================================================
# Open Design — K3s Deployment Script
#
# Builds the Docker image (with Claude Code + opencode pre-installed),
# imports it into K3s containerd, and applies all K8s manifests.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/k8s-manifests"
NAMESPACE="open-design"
IMAGE_NAME="open-design"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "============================================================"
echo "  Open Design — K3s Deployment"
echo "  (includes Claude Code + opencode agent CLIs)"
echo "============================================================"
echo ""

# ─────────────────────────────────────────────────
# Step 0: Validate prerequisites
# ─────────────────────────────────────────────────
info "Checking prerequisites..."
command -v buildah >/dev/null 2>&1 || fail "buildah is not installed."
command -v podman >/dev/null 2>&1 || fail "podman is not installed."
command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed."
ok "Prerequisites validated."
echo ""

# ─────────────────────────────────────────────────
# Step 1: Generate OD_API_TOKEN if not in secrets
# ─────────────────────────────────────────────────
SECRETS_FILE="${MANIFESTS_DIR}/01-secrets.yaml"
if grep -q "PLACEHOLDER_RUN_openssl_rand_hex_32" "${SECRETS_FILE}"; then
    info "Generating OD_API_TOKEN..."
    OD_TOKEN=$(openssl rand -hex 32)
    sed -i "s/PLACEHOLDER_RUN_openssl_rand_hex_32/${OD_TOKEN}/" "${SECRETS_FILE}"
    ok "OD_API_TOKEN generated: ${OD_TOKEN:0:8}..."
    echo ""
fi

# ─────────────────────────────────────────────────
# Step 2: Build Docker image (using buildah)
# ─────────────────────────────────────────────────
info "Building Open Design Docker image (this may take 5-10 minutes)..."
info "  Image includes: Node.js 24, open-design daemon+web, Claude Code, opencode"
buildah bud -t ${IMAGE_NAME}:latest -f "${SCRIPT_DIR}/Dockerfile.open-design" "${SCRIPT_DIR}"
ok "Docker image built: ${IMAGE_NAME}:latest"
echo ""

# Verify agent CLIs are in the image
info "Verifying agent CLIs in image..."
podman run --rm ${IMAGE_NAME}:latest which claude && ok "  claude: found" || warn "  claude: NOT FOUND"
podman run --rm ${IMAGE_NAME}:latest which opencode && ok "  opencode: found" || warn "  opencode: NOT FOUND"
echo ""

# ─────────────────────────────────────────────────
# Step 3: Import into K3s containerd
# ─────────────────────────────────────────────────
info "Importing image into K3s containerd..."
podman save ${IMAGE_NAME}:latest | sudo k3s ctr images import -
ok "Image imported into K3s."
echo ""

# ─────────────────────────────────────────────────
# Step 4: Apply namespace first
# ─────────────────────────────────────────────────
info "Creating namespace..."
kubectl apply -f "${MANIFESTS_DIR}/00-namespace.yaml"
ok "Namespace '${NAMESPACE}' ready."
echo ""

# ─────────────────────────────────────────────────
# Step 5: Apply all manifests
# ─────────────────────────────────────────────────
info "Applying K8s manifests..."
kubectl apply -f "${MANIFESTS_DIR}/"
ok "All manifests applied."
echo ""

# ─────────────────────────────────────────────────
# Step 6: Wait for rollout
# ─────────────────────────────────────────────────
info "Waiting for deployment rollout (timeout 300s)..."
kubectl rollout status deployment/open-design -n "${NAMESPACE}" --timeout=300s || warn "Rollout not complete yet, check manually."
echo ""

# ─────────────────────────────────────────────────
# Step 7: Verify deployment
# ─────────────────────────────────────────────────
info "Deployment status:"
echo ""
echo "  Pods:"
kubectl get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""
echo "  Services:"
kubectl get svc -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""
echo "  PVCs:"
kubectl get pvc -n "${NAMESPACE}" -o wide 2>/dev/null || true
echo ""

echo "============================================================"
ok "Open Design deployed to K3s!"
echo ""
echo "  Internal: http://open-design-svc.${NAMESPACE}.svc.cluster.local:7457"
echo "  Public:   https://open-design.woowtech.io (after tunnel config)"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ NEXT STEPS:                                             │"
echo "  │                                                         │"
echo "  │ 1. Add Cloudflare Tunnel route:                         │"
echo "  │    hostname: open-design.woowtech.io                    │"
echo "  │    service:  http://open-design-svc.open-design.svc.    │"
echo "  │              cluster.local:7457                         │"
echo "  │                                                         │"
echo "  │ 2. Set ANTHROPIC_API_KEY in 01-secrets.yaml:            │"
echo "  │    kubectl edit secret od-secrets -n open-design        │"
echo "  │                                                         │"
echo "  │ 3. Verify agent CLIs work inside the pod:               │"
echo "  │    kubectl exec -n open-design deploy/open-design --    │"
echo "  │      claude --version                                   │"
echo "  │    kubectl exec -n open-design deploy/open-design --    │"
echo "  │      opencode version                                   │"
echo "  └─────────────────────────────────────────────────────────┘"
echo "============================================================"
