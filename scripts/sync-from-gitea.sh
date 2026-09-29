#!/usr/bin/env bash
# Sync this mirror from the Gitea source of truth.
#
# This repository is a read-only MIRROR of the WOOW PaaS open-design cloud
# service. The authoritative copies live on the internal Gitea
# (git-prod.woowtech.io); edits made here are overwritten by the next sync.
#
#   image/    <- woow-paas/paas-odoo-ci      open-design/
#   console/  <- woow-paas/paas-odoo-ci      open-design-console/
#   chart/    <- woow-paas/woow-paas-charts  charts/open-design/
#
# Usage:  scripts/sync-from-gitea.sh [paas-odoo-ci-ref] [woow-paas-charts-ref]
#         (both refs default to "main")
#
# Needs git read access to the Gitea repos (e.g. a credential helper for
# https://git-prod.woowtech.io). Writes the resolved commits into MIRROR.md so
# every mirrored file can be traced back to the exact source revision.
set -Eeuo pipefail

GITEA="${GITEA_URL:-https://git-prod.woowtech.io}"
CI_REF="${1:-main}"
CHARTS_REF="${2:-main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <repo> <ref> <dir>
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$GITEA/$1.git" "$2"
  git -C "$3" checkout -q FETCH_HEAD
  git -C "$3" rev-parse HEAD
}

CI_SHA="$(fetch woow-paas/paas-odoo-ci "$CI_REF" "$WORK/ci")"
CHARTS_SHA="$(fetch woow-paas/woow-paas-charts "$CHARTS_REF" "$WORK/charts")"

replace() {  # replace <src-dir> <dst-dir>
  [ -d "$1" ] || { echo "missing source directory: $1" >&2; exit 1; }
  rm -rf "$2"
  mkdir -p "$2"
  cp -a "$1/." "$2/"
}

replace "$WORK/ci/open-design"               "$ROOT/image"
replace "$WORK/ci/open-design-console"       "$ROOT/console"
replace "$WORK/charts/charts/open-design"    "$ROOT/chart"

CHART_VERSION="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml")"
APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$ROOT/chart/Chart.yaml")"

# Rewrite only the generated block of MIRROR.md; the prose around it is kept.
python3 - "$ROOT/MIRROR.md" "$CI_SHA" "$CHARTS_SHA" "$CHART_VERSION" "$APP_VERSION" <<'PY'
import sys, re, datetime
path, ci, charts, chart_ver, app_ver = sys.argv[1:6]
block = (
    "<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->\n"
    f"| Mirror path | Source repository | Source path | Commit |\n"
    f"|---|---|---|---|\n"
    f"| `image/` | `woow-paas/paas-odoo-ci` | `open-design/` | `{ci}` |\n"
    f"| `console/` | `woow-paas/paas-odoo-ci` | `open-design-console/` | `{ci}` |\n"
    f"| `chart/` | `woow-paas/woow-paas-charts` | `charts/open-design/` | `{charts}` |\n"
    f"\n"
    f"Chart `{chart_ver}` / OpenDesign `{app_ver}` — synced "
    f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC.\n"
    "<!-- END GENERATED -->"
)
text = open(path, encoding="utf-8").read()
new, n = re.subn(r"<!-- BEGIN GENERATED.*?<!-- END GENERATED -->", block, text, flags=re.S)
if n != 1:
    sys.exit("MIRROR.md is missing its generated block markers")
open(path, "w", encoding="utf-8").write(new)
PY

echo "synced: paas-odoo-ci@${CI_SHA:0:8}  woow-paas-charts@${CHARTS_SHA:0:8}  chart ${CHART_VERSION} / OpenDesign ${APP_VERSION}"
