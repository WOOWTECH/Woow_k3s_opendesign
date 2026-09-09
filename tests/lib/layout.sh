# shellcheck shell=bash
# Shared layout resolution for the shell lanes of the test suite.
# Source this, never execute it. Mirrors tests/lib/repolayout.py.
#
# Exports: REPO_ROOT CHART_DIR OPT_DIR LAUNCHER ARTIFACTS
# Provides: die_missing <what> <path...>   loud, exit 2 (missing input)

REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
export REPO_ROOT

if [[ -z "${CHART_DIR:-}" ]]; then
  if [[ -f "$REPO_ROOT/chart/Chart.yaml" ]]; then
    CHART_DIR="$REPO_ROOT/chart"
  elif [[ -f "$REPO_ROOT/Chart.yaml" ]]; then
    CHART_DIR="$REPO_ROOT"
  else
    CHART_DIR="$REPO_ROOT/chart"
  fi
elif [[ "$CHART_DIR" != /* ]]; then
  CHART_DIR="$REPO_ROOT/$CHART_DIR"
fi
export CHART_DIR

OPT_DIR=${OPT_DIR:-rootfs/opt/woow-opendesign}
[[ "$OPT_DIR" == /* ]] || OPT_DIR="$REPO_ROOT/$OPT_DIR"
export OPT_DIR

LAUNCHER=${LAUNCHER:-rootfs/usr/local/bin/k3s-opendesign}
[[ "$LAUNCHER" == /* ]] || LAUNCHER="$REPO_ROOT/$LAUNCHER"
export LAUNCHER

ARTIFACTS="$REPO_ROOT/tests/.artifacts"
export ARTIFACTS

die_missing() {
  local what=$1
  shift
  {
    printf '%s\n' "========================================================================"
    printf 'MISSING INPUT — %s cannot run\n' "$what"
    printf '%s\n' "========================================================================"
    printf 'repo root : %s\n' "$REPO_ROOT"
    printf 'chart dir : %s\n' "$CHART_DIR"
    printf 'These required paths do not exist:\n'
    printf '  - %s\n' "$@"
    printf '\nThis is NOT a pass. Override REPO_ROOT / CHART_DIR / OPT_DIR / LAUNCHER\n'
    printf 'if the repository layout is intentionally different.\n'
  } >&2
  exit 2
}

require_paths() {
  local what=$1
  shift
  local missing=()
  local path
  for path in "$@"; do
    [[ -e "$path" ]] || missing+=("$path")
  done
  (( ${#missing[@]} == 0 )) || die_missing "$what" "${missing[@]}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die_missing "$2" "command not found: $1"
}
