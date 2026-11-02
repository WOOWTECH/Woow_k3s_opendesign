#!/usr/bin/env bash
#
# egress profile label（商用驗收 egress-all-ports-open；AI-HER-008-2、AI-OD-007-9）。
# 平台 baseline（paas-baseline-egress，podSelector {}）的公網規則是任意埠，NetworkPolicy 是聯集，
# chart 自己把公網限在 80/443 也會被抵銷。帶 paas.woowtech.io/egress-profile=web 的 pod 在 operator
# 開 TENANT_BASELINE_EGRESS_WEB_PROFILE 後改由 paas-baseline-egress-web（公網只有 TCP 80/443）管。
#   - 公網限埠的 pod：預設帶 label=web；label 只進 pod template、不進 selector（selector 不可變）
#   - networkPolicy.egressProfile="" 或 networkPolicy.enabled=false → 不帶
#   - chart 沒給公網限埠規則的 pod 不帶（不改它們現在的 baseline）
#
# Usage:    bash charts/open-design/tests/test-egress-profile.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (egress-profile): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (egress-profile): $1"; exit 1; }
KEY='paas.woowtech.io/egress-profile'
PIN=()

# <kind> <name> <field: template|selector> [helm args...] → label value or <none>
lab() {
  local kind="$1" name="$2" field="$3"; shift 3
  local path='.spec.template.metadata.labels'
  [ "$field" = selector ] && path='.spec.selector.matchLabels'
  $HELM template t "$CHART_DIR" "${PIN[@]}" "$@" 2>/dev/null \
    | yq "select(.kind==\"$kind\" and .metadata.name==\"$name\") | ${path}.\"$KEY\" // \"<none>\""
}
expect_web() { # <kind> <name> [helm args...]
  local kind="$1" name="$2"; shift 2
  local got
  got="$(lab "$kind" "$name" template "$@")"
  [ "$got" = "web" ] || fail "$kind/$name [$*]: pod template $KEY='$got', expected web"
  got="$(lab "$kind" "$name" selector "$@")"
  [ "$got" = "<none>" ] || fail "$kind/$name: $KEY leaked into spec.selector ('$got')"
  got="$(lab "$kind" "$name" template "$@" --set-string networkPolicy.egressProfile=)"
  [ "$got" = "<none>" ] || fail "$kind/$name egressProfile='': $KEY='$got', expected none"
  got="$(lab "$kind" "$name" template "$@" --set networkPolicy.enabled=false)"
  [ "$got" = "<none>" ] || fail "$kind/$name networkPolicy.enabled=false: $KEY='$got', expected none"
}
expect_none() { # <kind> <name> [helm args...]
  local kind="$1" name="$2"; shift 2
  local got
  got="$(lab "$kind" "$name" template "$@")"
  [ "$got" = "<none>" ] || fail "$kind/$name [$*]: $KEY='$got', expected none (no port-limited internet rule)"
}

expect_web  StatefulSet t-open-design
# console：只有 runtimeInstall（啟動時下載 kubectl／pip）才有公網 80/443 規則
expect_none Deployment  t-open-design-console
expect_web  Deployment  t-open-design-console --set console.runtimeInstall=true
expect_none Deployment  t-open-design-console --set console.runtimeInstall=true --set networkPolicy.allowAllEgress=false
echo "PASS (egress-profile)"
