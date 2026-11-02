#!/usr/bin/env bash
#
# console-ttyd-exposure (AI-HER-006-4 / X-SEC-002-1 / X-SEC-005-4), open-design 0.5.3:
#   - the admin password never reaches an argv or the pod log: ttyd runs on loopback with a
#     per-boot credential and the entrypoint's Basic front (public :7681) checks admin_password
#     — exercised for real by shared/console-authfront/check_console_entrypoint.py against the
#     RENDERED entrypoint.py (fake ttyd; plus the real ttyd binary when one is on PATH), in both
#     console modes (baked, runtimeInstall)
#   - the console Role has no Secret access (nothing in the console reads or writes it) and
#     keeps only get/patch on its own StatefulSet (rollout restart)
#   (the console container's own non-root spec is 0.5.1, tests/test-hardening.sh)
#
# Usage:    bash charts/open-design/tests/test-console-credential.sh
# Requires: helm + yq (mikefarah) + python3.
set -uo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CHART_DIR/../.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (console-credential): yq (mikefarah) required"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', expected '$3'"; fi; }
cl() { sed -e '/^---$/d' -e '/^$/d'; }
R="$TMP/r.yaml"
render() { $HELM template t "$CHART_DIR" "$@" > "$R" 2>"$R.err" || { cat "$R.err"; exit 1; }; }
SCRIPTS='select(.kind == "ConfigMap" and .metadata.name == "t-open-design-console-scripts")'
ROLE='select(.kind == "Role" and .metadata.name == "t-open-design-console")'

for mode in baked runtimeInstall; do
  echo "== entrypoint ($mode): the admin password stays out of argv and logs"
  if [ "$mode" = baked ]; then render; else render --set console.runtimeInstall=true; fi
  yq "$SCRIPTS | .data.\"entrypoint.py\"" "$R" > "$TMP/entrypoint.py"
  grep -q '"-c", "%s:%s" % (BASIC_USER, TUI_PASSWORD)' "$TMP/entrypoint.py" && bad "entrypoint.py still passes the admin password to ttyd -c"
  python3 "$REPO_DIR/shared/console-authfront/check_console_entrypoint.py" "$TMP/entrypoint.py" || rc=1
  [ "$mode" = baked ] && { python3 "$REPO_DIR/shared/console-authfront/check_console_entrypoint.py" "$TMP/entrypoint.py" --real-ttyd || rc=1; }
done

echo "== console Role"
render
yq "$ROLE" "$R" > "$TMP/role.yaml"
qr() { yq "$1" "$TMP/role.yaml" | cl; }
t "no secrets rule" "$(qr "[.rules[] | select(.resources[] == \"secrets\")] | length")" "0"
t "statefulsets: get,patch on the daemon StatefulSet only" "$(qr ".rules[] | select(.resources[0] == \"statefulsets\") | (.verbs | join(\",\")) + \"@\" + (.resourceNames | join(\",\"))")" "get,patch@t-open-design"
t "resources" "$(qr "[.rules[].resources[]] | sort | join(\",\")")" "pods,pods/exec,pods/log,statefulsets"
t "no verbs beyond get/patch except pods/exec create" "$(qr "[.rules[] | select(.resources[0] != \"pods/exec\") | .verbs[] | select(. != \"get\" and . != \"patch\")] | length")" "0"

[ $rc -eq 0 ] && echo "PASS (console-credential)" || echo "FAIL (console-credential)"
exit $rc
