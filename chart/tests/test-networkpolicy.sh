#!/usr/bin/env bash
#
# NetworkPolicy contract (aligned with mcp-server #279/#280):
#   - default-deny (Ingress+Egress) NP present, selecting the whole release
#   - daemon-allow NP present; egress DNS + allowAllEgress toggle
#   - ingressNamespaces EMPTY (default) → NO from-less ingress allow rule (the #280
#     hole); operator baseline governs CS-ns ingress
#   - ingressNamespaces set → a proper namespaceSelector `from:` rule on :7457
#   - console-allow NP present only when console.enabled
#
# Usage:    bash charts/open-design/tests/test-networkpolicy.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (networkpolicy): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (networkpolicy): $1"; exit 1; }

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"

DD="$(printf '%s' "$OUT" | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-default-deny")')"
[ -n "$DD" ] || fail "no default-deny NetworkPolicy rendered"
DDI="$(printf '%s' "$DD" | yq '.spec.policyTypes | length')"
[ "$DDI" = "2" ] || fail "default-deny policyTypes count='$DDI', expected 2 (Ingress+Egress)"

# empty ingressNamespaces (default) → daemon-allow ingress has NO rules (null/empty).
ALLOW="$(printf '%s' "$OUT" | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow")')"
[ -n "$ALLOW" ] || fail "no daemon-allow NetworkPolicy rendered"
NRULES="$(printf '%s' "$ALLOW" | yq '.spec.ingress // [] | length')"
[ "$NRULES" = "0" ] || fail "daemon-allow has $NRULES from-less ingress rule(s) by default — expected 0 (#280 hole guard)"

# ── Egress converged (np-audit #42 F-1/2/3/7) — NEVER a bare `- {}` allow-all ──
# No open `- {}` egress rule anywhere, in ANY scenario (the root F-1 defect).
for ARGS in "" "--set networkPolicy.allowAllEgress=false" "--set console.runtimeInstall=true" "--set console.enabled=false"; do
  OPEN="$($HELM template t "$CHART_DIR" $ARGS 2>/dev/null | yq 'select(.kind=="NetworkPolicy") | .spec.egress[] | select(. == {})' 2>/dev/null | grep -c '{}' || true)"
  [ "${OPEN:-0}" = "0" ] || fail "bare '- {}' allow-all egress present with [$ARGS] (F-1)"
done

# daemon internet egress = ipBlock 0.0.0.0/0 with the cluster+metadata excludes, TCP 443/80.
CIDR="$(printf '%s' "$ALLOW" | yq '.spec.egress[] | select(.to[0].ipBlock != null) | .to[0].ipBlock.cidr')"
[ "$CIDR" = "0.0.0.0/0" ] || fail "daemon internet ipBlock cidr='$CIDR', expected 0.0.0.0/0"
for X in 169.254.0.0/16 10.0.0.0/8 127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
  printf '%s' "$ALLOW" | yq -e ".spec.egress[] | select(.to[0].ipBlock) | .to[0].ipBlock.except | contains([\"$X\"])" >/dev/null 2>&1 \
    || fail "daemon internet ipBlock does not exclude $X (F-2/F-3)"
done
IPORTS="$(printf '%s' "$ALLOW" | yq '.spec.egress[] | select(.to[0].ipBlock != null) | .ports[].port' | sort | tr '\n' ',')"
[ "$IPORTS" = "443,80," ] || fail "daemon internet egress ports='$IPORTS', expected 80,443 only"

# DNS narrowed to kube-dns pods (F-7).
KDNS="$(printf '%s' "$ALLOW" | yq '.spec.egress[0].to[0].podSelector.matchLabels."k8s-app"')"
[ "$KDNS" = "kube-dns" ] || fail "DNS egress not narrowed to k8s-app=kube-dns (F-7), got '$KDNS'"

# allowAllEgress=false → daemon egress carries NO internet ipBlock. It may still
# hold the in-cluster console-ttyd hole (console.externalPath default /console, gap
# #49) alongside DNS — an explicit pod-scoped allow, never 0.0.0.0/0. So assert the
# security invariant (no internet egress) rather than a fixed rule count.
OFFA="$($HELM template t "$CHART_DIR" --set networkPolicy.allowAllEgress=false 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow")')"
OFFNET="$(printf '%s' "$OFFA" | yq '[.spec.egress[] | select(.to[0].ipBlock.cidr == "0.0.0.0/0")] | length')"
[ "$OFFNET" = "0" ] || fail "allowAllEgress=false daemon still exposes internet ipBlock egress (expected DNS + optional in-cluster console only)"
# and with the console route also off, egress is DNS-only (single rule).
OFFE="$($HELM template t "$CHART_DIR" --set networkPolicy.allowAllEgress=false --set console.externalPath="" 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow") | .spec.egress | length')"
[ "$OFFE" = "1" ] || fail "allowAllEgress=false + no console route → daemon egress count='$OFFE', expected 1 (DNS only)"

# console egress = DNS + explicit apiserver ipBlock (NOT allow-all), no internet in baked mode.
CALLOW="$(printf '%s' "$OUT" | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-console-allow")')"
CAPI="$(printf '%s' "$CALLOW" | yq '.spec.egress[] | select(.to[0].ipBlock.cidr == "10.43.0.1/32") | .to[0].ipBlock.cidr')"
[ "$CAPI" = "10.43.0.1/32" ] || fail "console egress missing explicit apiserver ipBlock (10.43.0.1/32)"
CEGN="$(printf '%s' "$CALLOW" | yq '.spec.egress | length')"
[ "$CEGN" = "2" ] || fail "console egress count='$CEGN', expected 2 (DNS + apiserver, no internet in baked mode)"
CEGRT="$($HELM template t "$CHART_DIR" --set console.runtimeInstall=true 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-console-allow") | .spec.egress | length')"
[ "$CEGRT" = "3" ] || fail "console runtimeInstall egress count='$CEGRT', expected 3 (DNS + apiserver + internet)"

# ingressNamespaces set → proper from rule on the auth-proxy port (8080, Option C:
# external ingress lands on the proxy, not the loopback daemon).
WITHNS="$($HELM template t "$CHART_DIR" --set 'networkPolicy.ingressNamespaces[0]=paas-system' 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow") | .spec.ingress[0].ports[0].port')"
[ "$WITHNS" = "8080" ] || fail "ingressNamespaces set → allow port='$WITHNS', expected 8080 (proxy)"
# authProxy off → ingress allow reverts to the daemon port 7457.
WITHNS2="$($HELM template t "$CHART_DIR" --set 'networkPolicy.ingressNamespaces[0]=paas-system' --set authProxy.enabled=false --set config.bindHost=0.0.0.0 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-allow") | .spec.ingress[0].ports[0].port')"
[ "$WITHNS2" = "7457" ] || fail "authProxy off → allow port='$WITHNS2', expected 7457 (daemon)"

# console-allow NP gated on console.enabled.
CNP="$(printf '%s' "$OUT" | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-console-allow") | .metadata.name')"
[ "$CNP" = "t-open-design-console-allow" ] || fail "console-allow NP missing when console.enabled"
CNPOFF="$($HELM template t "$CHART_DIR" --set console.enabled=false 2>/dev/null \
  | yq 'select(.kind=="NetworkPolicy" and .metadata.name=="t-open-design-console-allow") | .metadata.name')"
[ -z "$CNPOFF" ] || fail "console-allow NP rendered even with console.enabled=false"

echo "PASS (networkpolicy): default-deny, no from-less ingress, NO bare-{} egress, ipBlock excludes cluster+metadata, apiserver-scoped console, kube-dns DNS, console NP gated."
