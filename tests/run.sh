#!/usr/bin/env bash
# The local gate. This must pass before any push, and CI runs this same script.
#
# Lanes, in order (each depends on the one before):
#   0  layout resolution + chart asset extraction (one `helm template`)
#   1  tests/validate.py            static metadata, pinning, secret hygiene
#   2  tests/workflow-policy.test.py  CI least-privilege + immutable release
#   3  tests/chart.test.sh          lint / render / kubeconform / server dry-run
#   4  node --check, bash -n        syntax gates
#   5  node --test tests/*.test.mjs unit tests
#   6  shellcheck, nginx -t         when installed
#
# The container lane (tests/container-smoke.sh) is NOT run here: it needs a
# built image and podman. CI runs it in its own job; run it by hand on the
# podman host.
#
# Layout overrides: REPO_ROOT CHART_DIR OPT_DIR LAUNCHER
set -Eeuo pipefail

# shellcheck source=lib/layout.sh
source "$(dirname "$0")/lib/layout.sh"
cd "$REPO_ROOT"

echo "== layout =="
echo "REPO_ROOT=$REPO_ROOT"
echo "CHART_DIR=$CHART_DIR"
echo "OPT_DIR=$OPT_DIR"
echo "LAUNCHER=$LAUNCHER"

require_command python3 "test gate"
require_command node "test gate"
require_command helm "test gate"

echo "== chart asset extraction =="
python3 tests/lib/extract-chart-assets.py

echo "== static validation =="
python3 tests/validate.py

echo "== workflow policy =="
python3 tests/workflow-policy.test.py

echo "== chart lane =="
bash tests/chart.test.sh

echo "== syntax gates =="
shopt -s nullglob
javascript=("$OPT_DIR"/*.js "$OPT_DIR"/*.mjs tests/*.mjs tests/lib/*.mjs "$ARTIFACTS/od-export-bridge.js")
shopt -u nullglob
if (( ${#javascript[@]} == 0 )); then
  die_missing "syntax gate" "no JavaScript sources found under $OPT_DIR or tests/"
fi
for file in "${javascript[@]}"; do
  node --check "$file"
done
echo "node --check: ${#javascript[@]} file(s) OK"

shell_scripts=("$LAUNCHER" tests/run.sh tests/chart.test.sh tests/container-smoke.sh tests/lib/layout.sh)
[[ -f .github/scripts/release-preflight.sh ]] && shell_scripts+=(.github/scripts/release-preflight.sh)
bash -n "${shell_scripts[@]}"
echo "bash -n: ${#shell_scripts[@]} script(s) OK"

echo "== unit tests =="
node --test tests/*.test.mjs

echo "== optional linters =="
if command -v shellcheck >/dev/null 2>&1; then
  # Info-level findings are not gate failures: SC1091 is just shellcheck
  # declining to follow a sourced path, and SC2016 flags the in-container
  # scripts that are single-quoted precisely so the OUTER shell does not
  # expand them.
  shellcheck --external-sources --severity=warning "${shell_scripts[@]}"
  echo "shellcheck: OK"
else
  echo "shellcheck: SKIP (not installed)"
fi

if command -v nginx >/dev/null 2>&1; then
  nginx_root=$(mktemp -d)
  trap 'rm -rf "$nginx_root"' EXIT
  mkdir -p "$nginx_root"/od-nginx
  nginx_test_config="$nginx_root/nginx.conf"
  # nginx -t cannot reopen /dev/stdout under some sandboxes, and the sidecar's
  # /tmp paths do not exist on the developer's machine, so both are retargeted.
  sed -e "s#/dev/stderr#$nginx_root/error.log#" \
      -e "s#/dev/stdout#$nginx_root/access.log#" \
      -e "s#/tmp/od-nginx#$nginx_root/od-nginx#g" \
      "$ARTIFACTS/nginx.conf" >"$nginx_test_config"
  nginx -t -c "$nginx_test_config" -p "$nginx_root"
  rm -rf "$nginx_root"
  trap - EXIT
  echo "nginx -t: OK"
else
  echo "nginx -t: SKIP (not installed) — the sidecar config was NOT syntax-checked"
fi

echo
echo "all non-container validation passed"
echo "container lane not run here: tests/container-smoke.sh <image>  (needs podman + a built image)"
