#!/usr/bin/env bash
#
# Orphan run records (0.5.1, AI-OD-007-6): files/prune-orphan-runs.py against throw-away data
# dirs with a real sqlite database, plus the render contract of the prune-runs initContainer.
#   - a run whose project is neither in the database nor on disk is removed (with its
#     diagnostics dir); every other run is kept: project in `projects`, project only in
#     `workspace_projects`, project directory only, no projectId, unreadable state.json,
#     a symlinked run dir (target untouched), a projectId that is not a plain name
#   - fail-safe: no database, no `projects` table, runs dir missing, dry run -> nothing removed,
#     exit 0 every time; output has counts only (no prompt text, no ids, no paths)
#   - render: initContainer in the daemon image, hardened uid 1001, od-data + script only,
#     requests+limits incl. ephemeral-storage, default on (also without a runsPrune block),
#     runsPrune.enabled=false removes it, dryRun reaches the env, pod rolls when the script changes
#
# Usage:    bash charts/open-design/tests/test-runs-prune.sh
# Requires: python3; helm + yq (mikefarah) for the render part.
set -uo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
SCRIPT="$CHART_DIR/files/prune-orphan-runs.py"
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
rc=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', expected '$3'"; fi; }
command -v python3 >/dev/null || { echo "SKIP (runs-prune): python3 required"; exit 0; }

SECRET_PROMPT="PROMPT-NEVER-PRINT-0123456789"
mkdb() { # mkdb <data> [no-projects-table]
  python3 - "$1" "${2:-}" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1] + "/app.sqlite")
if sys.argv[2] != "no-projects-table":
    con.execute("CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
    con.execute("INSERT INTO projects VALUES ('proj-live', 'live')")
    con.execute("CREATE TABLE workspace_projects (project_id TEXT, workspace_id TEXT)")
    con.execute("INSERT INTO workspace_projects VALUES ('proj-ws-only', 'w1')")
else:
    con.execute("CREATE TABLE other (x TEXT)")
con.commit(); con.close()
PY
}
mkrun() { # mkrun <data> <runId> <projectId|-> [raw]
  mkdir -p "$1/runs/$2"
  if [ "${4:-}" != "" ]; then printf '%s' "$4" > "$1/runs/$2/state.json"
  elif [ "$3" = "-" ]; then printf '{"id":"%s","userPrompt":"%s"}' "$2" "$SECRET_PROMPT" > "$1/runs/$2/state.json"
  else printf '{"id":"%s","projectId":"%s","userPrompt":"%s"}' "$2" "$3" "$SECRET_PROMPT" > "$1/runs/$2/state.json"; fi
}
has() { [ -e "$D/data/runs/$1" ] && echo kept || echo gone; }
run() { env -i PATH="$PATH" OD_DATA_PATH="$D/data" "$@" python3 "$SCRIPT" > "$D/out.log" 2>&1; echo $?; }
new_case() { D="$TMP/$1"; mkdir -p "$D/data/projects"; }

echo "== orphan runs go, everything else stays"
new_case main
mkdb "$D/data"
mkrun "$D/data" r-orphan proj-gone
mkdir -p "$D/data/diagnostics/r-orphan"; echo x > "$D/data/diagnostics/r-orphan/d.json"
mkrun "$D/data" r-live proj-live
mkrun "$D/data" r-ws proj-ws-only
mkrun "$D/data" r-dironly proj-dir-only; mkdir -p "$D/data/projects/proj-dir-only"
mkrun "$D/data" r-noproj -
mkrun "$D/data" r-broken proj-gone '{not json'
mkrun "$D/data" r-unsafe '../proj-gone'
mkrun "$D/data" r-orphan2 proj-gone2
mkdir -p "$TMP/elsewhere/r-target"; printf '{"projectId":"proj-gone"}' > "$TMP/elsewhere/r-target/state.json"
ln -s "$TMP/elsewhere/r-target" "$D/data/runs/r-link"
t "exit 0" "$(run)" 0
t "orphan run removed" "$(has r-orphan)" gone
t "second orphan removed" "$(has r-orphan2)" gone
t "orphan's diagnostics dir removed" "$([ -e "$D/data/diagnostics/r-orphan" ] && echo kept || echo gone)" gone
t "project in projects -> kept" "$(has r-live)" kept
t "project only in workspace_projects -> kept" "$(has r-ws)" kept
t "project directory only -> kept" "$(has r-dironly)" kept
t "no projectId -> kept" "$(has r-noproj)" kept
t "unreadable state.json -> kept" "$(has r-broken)" kept
t "projectId that is not a plain name -> kept" "$(has r-unsafe)" kept
t "symlinked run dir -> kept, target untouched" "$(has r-link)/$([ -e "$TMP/elsewhere/r-target/state.json" ] && echo intact)" "kept/intact"
t "summary counts" "$(cat "$D/out.log")" "[prune-runs] runs=8 orphan=2 removed=2 failed=0"
if grep -rq "NEVER-PRINT\|proj-gone\|r-orphan" "$D/out.log"; then bad "prompt text, id or path leaked into the output"; else ok "output has counts only"; fi
run >/dev/null
t "second start: nothing left to do" "$(cat "$D/out.log")" "[prune-runs] runs=6 orphan=0 removed=0 failed=0"

echo "== fail-safe"
new_case dry; mkdb "$D/data"; mkrun "$D/data" r-orphan proj-gone
t "dry run: exit 0" "$(run OD_RUNS_PRUNE_DRY_RUN=true)" 0
t "dry run: nothing removed" "$(has r-orphan)" kept
t "dry run: says so" "$(cat "$D/out.log")" "[prune-runs] runs=1 orphan=1 removed=0 failed=0 (dry run)"
new_case nodb; mkrun "$D/data" r-orphan proj-gone
t "no database: exit 0" "$(run)" 0
t "no database: nothing removed" "$(has r-orphan)" kept
new_case noproj; mkdb "$D/data" no-projects-table; mkrun "$D/data" r-orphan proj-gone
t "no projects table: exit 0" "$(run)" 0
t "no projects table: nothing removed" "$(has r-orphan)" kept
new_case garbage; echo 'not a database' > "$D/data/app.sqlite"; mkrun "$D/data" r-orphan proj-gone
t "unreadable database: exit 0" "$(run)" 0
t "unreadable database: nothing removed" "$(has r-orphan)" kept
new_case noruns; mkdb "$D/data"
t "no runs dir: exit 0" "$(run)" 0
new_case ro; mkdb "$D/data"; mkrun "$D/data" r-orphan proj-gone; chmod 0555 "$D/data/runs"
t "unwritable runs dir: still exit 0" "$(run)" 0
chmod 0755 "$D/data/runs"

# ── render contract ─────────────────────────────────────────────────────────────
if ! command -v yq >/dev/null 2>&1; then echo "SKIP (runs-prune render): yq (mikefarah) required"; [ $rc -eq 0 ] && echo "PASS (runs-prune)" || echo "FAIL (runs-prune)"; exit $rc; fi
echo "== render"
R="$TMP/r.yaml"
IC='select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "prune-runs")'
cl() { sed -e '/^---$/d' -e '/^$/d'; }   # yq prints an empty document for every non-matching resource
icq() { yq "$IC | $1" "$R" | cl; }
$HELM template t "$CHART_DIR" > "$R" 2>"$R.err" || { cat "$R.err"; exit 1; }
t "initContainer uses the daemon image" "$(icq .image)" "jcr-prod.woowtech.io/woow-paas-docker-local/open-design:$(yq '.appVersion' "$CHART_DIR/Chart.yaml")"
t "runs the chart's script" "$(icq '.command | join(" ")')" "python3 /etc/od-agent-defaults/prune-orphan-runs.py"
t "hardened: runAsNonRoot uid 1001, drop ALL, no escalation, seccomp" "$(icq '[.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.allowPrivilegeEscalation, .securityContext.capabilities.drop[0], .securityContext.seccompProfile.type] | join(",")')" "true,1001,false,ALL,RuntimeDefault"
t "mounts od-data (not od-home) and the script" "$(icq '[.volumeMounts[].mountPath] | join(",")')" "/app/.od,/etc/od-agent-defaults"
t "env OD_DATA_PATH / dry run off" "$(icq '[.env[] | .name + "=" + .value] | join(",")')" "OD_DATA_PATH=/app/.od,OD_RUNS_PRUNE_DRY_RUN=false"
t "requests+limits incl. ephemeral-storage" "$(icq '[(.resources.requests | has("ephemeral-storage")), (.resources.limits | has("ephemeral-storage")), (.resources.limits | has("memory")), (.resources.requests | has("memory"))] | join(",")')" "true,true,true,true"
t "after seed-home and agent-defaults, before the daemon" "$(yq 'select(.kind == "StatefulSet") | [.spec.template.spec.initContainers[].name] | join(",")' "$R" | cl)" "seed-home,agent-defaults,prune-runs"
t "script ConfigMap carries files/prune-orphan-runs.py" "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "t-open-design-agent-defaults") | .data."prune-orphan-runs.py"' "$R" | python3 -c 'import sys; print("same" if sys.stdin.read().strip() == open(sys.argv[1]).read().strip() else "differs")' "$SCRIPT")" same
t "pod rolls when the script changes" "$(yq 'select(.kind == "StatefulSet") | .spec.template.metadata.annotations | has("checksum/agent-defaults")' "$R" | cl)" true
$HELM template t "$CHART_DIR" --set runsPrune.dryRun=true > "$R" 2>/dev/null
t "dryRun reaches the env" "$(icq '.env[] | select(.name == "OD_RUNS_PRUNE_DRY_RUN") | .value')" true
$HELM template t "$CHART_DIR" --set runsPrune=null > "$R" 2>/dev/null
t "a values set without the runsPrune block (--reuse-values) still prunes" "$(icq '.name' | grep -c prune-runs)" 1
$HELM template t "$CHART_DIR" --set runsPrune.enabled=false > "$R" 2>/dev/null
t "enabled=false: no initContainer" "$(icq '.name' | grep -c prune-runs)" 0
t "enabled=false: agent-defaults untouched" "$(yq 'select(.kind == "StatefulSet") | [.spec.template.spec.initContainers[].name] | join(",")' "$R" | cl)" "seed-home,agent-defaults"
$HELM template t "$CHART_DIR" --set persistence.data.mountPath=/data/od > "$R" 2>/dev/null
t "follows persistence.data.mountPath" "$(icq '[.env[0].value, .volumeMounts[0].mountPath] | join(",")')" "/data/od,/data/od"

[ $rc -eq 0 ] && echo "PASS (runs-prune)" || echo "FAIL (runs-prune)"
exit $rc
