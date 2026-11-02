#!/usr/bin/env bash
#
# Out-of-the-box agent (#1437 / #1438): files/agent-defaults.py against throw-away
# data/home dirs, plus the render contract of the agent-defaults initContainer.
#   - fresh instance with only an OpenRouter key → default agent opencode, onboarding
#     done, OpenCode's default model pinned in opencode.jsonc
#   - Anthropic key or a `claude login` → claude; no key at all → nothing changed
#   - an unusable "amr" / unsigned "claude" is replaced; a tenant's own pick is kept;
#     the chart's previous default follows the keys (Anthropic key added later → claude)
#   - opencode.jsonc: OpenCode's trivial {"$schema"} file is taken over, a tenant-edited
#     file never touched, a model in opencode.json wins, the managed file follows model /
#     key changes
#   - broken JSON is left alone and the script still exits 0; key values never printed
#   - render: initContainer (daemon image, hardened, od-data + od-home + script), env,
#     agentDefaults.enabled=false, validation of defaultAgent / opencodeModel
#
# Usage:    bash charts/open-design/tests/test-agent-defaults.sh
# Requires: python3; helm + yq (mikefarah) for the render part.
set -uo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
SCRIPT="$CHART_DIR/files/agent-defaults.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', expected '$3'"; fi; }

MODEL=openrouter/openai/gpt-5-mini
KEY_OR="sk-or-v1-NEVER-PRINT-THIS-0123456789"
KEY_AN="sk-ant-NEVER-PRINT-THIS-0123456789"

new_case() { D="$TMP/$1"; mkdir -p "$D/data" "$D/home"; }
run() { # run [VAR=value ...] — inside the current case
  env -i PATH="$PATH" OD_DATA_PATH="$D/data" OD_HOME_PATH="$D/home" OD_DEFAULT_AGENT=auto \
    OD_OPENCODE_MODEL="$MODEL" "$@" python3 "$SCRIPT" > "$D/out.log" 2>&1
  echo $?
}
agent() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agentId"))' "$D/data/app-config.json" 2>/dev/null || echo "<none>"; }
onboard() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("onboardingCompleted"))' "$D/data/app-config.json"; }
ocmodel() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model", "<none>"))' "$D/home/.config/opencode/opencode.jsonc" 2>/dev/null || echo "<nofile>"; }
setagent() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["agentId"]=sys.argv[2]; json.dump(d, open(p, "w"))' "$D/data/app-config.json" "$1"; }

command -v python3 >/dev/null || { echo "SKIP (agent-defaults): python3 required"; exit 0; }

echo "== fresh instance, only an OpenRouter key (#1437 / #1438)"
new_case fresh-or
t "exit 0" "$(run OPENROUTER_API_KEY="$KEY_OR")" 0
t "default agent opencode" "$(agent)" opencode
t "onboarding marked done (no upstream cloud sign-up page)" "$(onboard)" True
t "OpenCode default model pinned" "$(ocmodel)" "$MODEL"
if grep -rq "NEVER-PRINT" "$D/out.log" "$D/data" "$D/home"; then bad "a key value leaked into output or files"; else ok "key values never printed or stored"; fi
cp "$D/home/.config/opencode/opencode.jsonc" "$TMP/managed.jsonc"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "second start: nothing to do" "$(wc -l < "$D/out.log" | tr -d ' ')" 0
t "second start: file unchanged" "$(cmp -s "$TMP/managed.jsonc" "$D/home/.config/opencode/opencode.jsonc" && echo same)" same

echo "== the chart's default follows the keys, the tenant's pick is kept"
run OPENROUTER_API_KEY="$KEY_OR" ANTHROPIC_API_KEY="$KEY_AN" >/dev/null
t "Anthropic key added later → claude" "$(agent)" claude
setagent opencode
run OPENROUTER_API_KEY="$KEY_OR" ANTHROPIC_API_KEY="$KEY_AN" >/dev/null
t "tenant switched back to opencode → kept" "$(agent)" opencode
setagent codex
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "tenant's other agent kept" "$(agent)" codex
setagent amr
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "amr (OpenDesign Cloud, not installed) replaced" "$(agent)" opencode

echo "== OpenRouter key cleared again → upstream default back (AI-OD-004-1)"
new_case clear-or
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "only an OpenRouter key → opencode" "$(agent)" opencode
t "exit 0 with the key gone" "$(run)" 0
t "key cleared → claude (upstream default) is back" "$(agent)" claude
run >/dev/null
t "next start without a key: claude stays, quiet" "$(agent)|$(wc -l < "$D/out.log" | tr -d ' ')" "claude|1"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "key set again → opencode again" "$(agent)" opencode
new_case clear-or-tenant
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
setagent codex
run >/dev/null
t "tenant's own pick survives the key removal" "$(agent)" codex
new_case clear-or-fresh-nokeys
run >/dev/null
t "never had a key: app-config still untouched" "$(agent)" "<none>"

echo "== existing instance (upgrade from 0.3.0): unsigned claude replaced, data kept"
new_case upgrade
printf '%s' '{"agentId":"claude","designSystemId":"default","installationId":"abc"}' > "$D/data/app-config.json"
mkdir -p "$D/home/.config/opencode"
printf '%s\n' '{' '  "$schema": "https://opencode.ai/config.json"' '}' > "$D/home/.config/opencode/opencode.jsonc"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "claude without key / login → opencode" "$(agent)" opencode
t "other app-config keys kept" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["installationId"], d["designSystemId"], d.get("onboardingCompleted"))' "$D/data/app-config.json")" "abc default None"
t "OpenCode's trivial opencode.jsonc taken over" "$(ocmodel)" "$MODEL"

echo "== claude when it can run, nothing without keys"
new_case login
mkdir -p "$D/home/.claude"; echo '{}' > "$D/home/.claude/.credentials.json"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "claude login on od-home → claude" "$(agent)" claude
new_case anthropic
run ANTHROPIC_API_KEY="$KEY_AN" >/dev/null
t "only an Anthropic key → claude" "$(agent)" claude
t "no OpenRouter key → no openrouter model pinned" "$(ocmodel)" "<none>"
new_case nokeys
run >/dev/null
t "no key, no login → app-config untouched" "$(agent)" "<none>"
new_case keep
run OPENROUTER_API_KEY="$KEY_OR" OD_DEFAULT_AGENT=keep >/dev/null
t "defaultAgent=keep → app-config untouched" "$(agent)" "<none>"
new_case forced
run OD_DEFAULT_AGENT=opencode >/dev/null
t "defaultAgent=opencode forced" "$(agent)" opencode

echo "== opencode.jsonc ownership"
new_case tenant-oc
mkdir -p "$D/home/.config/opencode"
printf '%s\n' '{' '  // my model' '  "$schema": "https://opencode.ai/config.json",' '  "model": "openrouter/x/y",' '}' > "$D/home/.config/opencode/opencode.jsonc"
cp "$D/home/.config/opencode/opencode.jsonc" "$TMP/tenant.jsonc"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "tenant-edited opencode.jsonc untouched" "$(cmp -s "$TMP/tenant.jsonc" "$D/home/.config/opencode/opencode.jsonc" && echo same)" same
new_case other-file
mkdir -p "$D/home/.config/opencode"; echo '{"model":"openrouter/a/b"}' > "$D/home/.config/opencode/opencode.json"
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
t "model in opencode.json wins (managed file has none)" "$(ocmodel)" "<none>"
new_case follow
run OPENROUTER_API_KEY="$KEY_OR" >/dev/null
run OPENROUTER_API_KEY="$KEY_OR" OD_OPENCODE_MODEL=openrouter/google/gemini-2.5-flash >/dev/null
t "managed file follows a model change" "$(ocmodel)" openrouter/google/gemini-2.5-flash
run >/dev/null
t "OpenRouter key removed → managed model dropped" "$(ocmodel)" "<none>"

echo "== broken input"
new_case broken
echo '{not json' > "$D/data/app-config.json"
t "invalid app-config.json → exit 0" "$(run OPENROUTER_API_KEY="$KEY_OR")" 0
t "invalid app-config.json left alone" "$(cat "$D/data/app-config.json")" '{not json'
new_case readonly
chmod 0555 "$D/data"
t "unwritable data dir → still exit 0" "$(run OPENROUTER_API_KEY="$KEY_OR")" 0
chmod 0755 "$D/data"

# ── render contract ─────────────────────────────────────────────────────────────
if ! command -v yq >/dev/null 2>&1; then echo "SKIP (agent-defaults render): yq (mikefarah) required"; exit $rc; fi
echo "== render"
R="$TMP/r.yaml"
$HELM template t "$CHART_DIR" > "$R" 2>"$R.err" || { cat "$R.err"; exit 1; }
IC='select(.kind == "StatefulSet") | .spec.template.spec.initContainers[] | select(.name == "agent-defaults")'
ic() { yq "$IC" "$1" > "$TMP/ic.yaml"; }
envv() { ic "$2"; yq ".env[] | select(.name == \"$1\") | (.value // .valueFrom.secretKeyRef.key)" "$TMP/ic.yaml"; }
icq() { ic "$2"; yq "$1" "$TMP/ic.yaml"; }
t "initContainer uses the daemon image" "$(icq .image "$R")" "jcr-prod.woowtech.io/woow-paas-docker-local/open-design:$(yq '.appVersion' "$CHART_DIR/Chart.yaml")"
t "runs the chart's script" "$(icq '.command | join(" ")' "$R")" "python3 /etc/od-agent-defaults/agent-defaults.py"
t "hardened: runAsNonRoot uid 1001" "$(icq '[.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.allowPrivilegeEscalation] | join(",")' "$R")" "true,1001,false"
t "mounts od-data, od-home and the script" "$(icq '[.volumeMounts[].mountPath] | join(",")' "$R")" "/app/.od,/home/opendesign,/etc/od-agent-defaults"
t "env OD_OPENCODE_MODEL default" "$(envv OD_OPENCODE_MODEL "$R")" "$MODEL"
t "env OD_DEFAULT_AGENT default" "$(envv OD_DEFAULT_AGENT "$R")" auto
t "keys from the Secret (optional)" "$(icq '[.env[] | select(.valueFrom) | .valueFrom.secretKeyRef.optional] | join(",")' "$R")" "true,true"
t "requests+limits incl. ephemeral-storage" "$(icq '[(.resources.requests | has("ephemeral-storage")), (.resources.limits | has("ephemeral-storage")), (.resources.limits | has("cpu"))] | join(",")' "$R")" "true,true,true"
t "script ConfigMap = files/agent-defaults.py" "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "t-open-design-agent-defaults") | .data."agent-defaults.py"' "$R" | python3 -c 'import sys; print("same" if sys.stdin.read().rstrip() == open(sys.argv[1]).read().rstrip() else "differs")' "$SCRIPT")" same
t "pod rolls when the script changes" "$(yq 'select(.kind == "StatefulSet") | .spec.template.metadata.annotations | has("checksum/agent-defaults")' "$R")" true
$HELM template t "$CHART_DIR" --set agentDefaults.opencodeModel=openrouter/google/gemini-2.5-flash --set agentDefaults.defaultAgent=claude > "$R" 2>/dev/null
t "opencodeModel override" "$(envv OD_OPENCODE_MODEL "$R")" openrouter/google/gemini-2.5-flash
t "defaultAgent override" "$(envv OD_DEFAULT_AGENT "$R")" claude
$HELM template t "$CHART_DIR" --set agentDefaults.enabled=false > "$R" 2>/dev/null
t "enabled=false: no initContainer" "$(yq "$IC | .name" "$R" | grep -c agent-defaults)" 0
# the ConfigMap is shared with the prune-runs initContainer (0.5.1): it stays while that one is on
t "enabled=false, prune-runs on: ConfigMap stays (shared)" "$(yq '[select(.kind == "ConfigMap" and .metadata.name == "t-open-design-agent-defaults")] | length' "$R" | grep -c '^1$')" 1
$HELM template t "$CHART_DIR" --set agentDefaults.enabled=false --set runsPrune.enabled=false > "$R" 2>/dev/null
t "both off: no ConfigMap" "$(yq '[select(.kind == "ConfigMap" and .metadata.name == "t-open-design-agent-defaults")] | length' "$R" | grep -c '^1$')" 0
t "both off: no script volume" "$(yq 'select(.kind == "StatefulSet") | [.spec.template.spec.volumes[].name] | contains(["agent-defaults"])' "$R" | grep -c '^true$')" 0
for bad_v in "agentDefaults.opencodeModel=gpt 5" "agentDefaults.defaultAgent=Claude!"; do
  if $HELM template t "$CHART_DIR" --set-string "$bad_v" >/dev/null 2>&1; then bad "render must fail: $bad_v"; else ok "rejects $bad_v"; fi
done

[ $rc -eq 0 ] && echo "PASS (agent-defaults)" || echo "FAIL (agent-defaults)"
exit $rc
