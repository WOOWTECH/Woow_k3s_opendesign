#!/usr/bin/env bash
#
# open-design × shared omnigent-host kit (IN-CONTAINER mode: the host runs inside the
# daemon container; shared/omnigent-host/README.md).
#   - vendored kit byte-identical to shared/omnigent-host (sha256), kit ConfigMap too
#   - kit_assert_in_container (image launch: the daemon keeps the image ENTRYPOINT
#     tini → omnigent-host-entry; the chart never overrides `command`)
#   - pod = exactly the containers it had before the Omnigent work (daemon + authproxy),
#     daemon resources = the full plan values (no budget split), also after
#     --reuse-values from 0.2.1
#   - OpenDesign parameters: ~/.omnigent on od-home, ~/studio, claude-subscription,
#     OD_API_TOKEN unset for the host, the platform's LLM keys passed on (#1440; all
#     stripped with stripApiKeys=true), workspace seed (CLAUDE.md-only
#     updates), /console/ bash hook, telemetry env even when disabled
#   - serverUrl is runtime data: never in the pod template (kit_assert_runtime_server_url)
#   - NetworkPolicy: Omnigent SERVER pods :8000 only (name + component=server, plus
#     the instance when serverUrl names an in-cluster release); off with the host
#   - render-time validation; enabled=false leaves no trace (kit_assert_disabled)
#   - the real vendored og_helper.py seeds the rendered workspace files with the
#     manifest rules (deleted stays deleted, unedited CLAUDE.md is updated)
#
# Usage:    bash charts/open-design/tests/test-omnigent-host-kit.sh
# Requires: helm, yq (mikefarah v4), python3 + PyYAML, sha256sum.
set -uo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$CHART_DIR/../.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (omnigent-host-kit): yq (mikefarah) required"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP (omnigent-host-kit): python3 required"; exit 0; }
# shellcheck source=../../../shared/omnigent-host/chart/kit-test-lib.sh
. "$REPO_DIR/shared/omnigent-host/chart/kit-test-lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
yy() { yq "$1" "$2" 2>/dev/null | grep -v -e '^---$' -e '^$' | head -n 1; }
# Number of scalar results (never `[...] | length`: yq evaluates that once per
# document, so an unrelated document would answer 0).
cnt() { yq "$1" "$2" 2>/dev/null | grep -v -e '^---$' -e '^$' | wc -l | tr -d ' '; }
# 0.5.0: omnigentHost.enabled defaults to false (Omnigent paused on the PaaS). Every kit check below
# renders with the kit ON (so it keeps working when it is turned back on); render_default() is the
# chart's own default (section "0.5.0 default").
render() { local out=$1; shift; "$HELM" template t "$CHART_DIR" --namespace paas-ws-test --set omnigentHost.enabled=true "$@" >"$out" 2>"$out.err"; }
render_default() { local out=$1; shift; "$HELM" template t "$CHART_DIR" --namespace paas-ws-test "$@" >"$out" 2>"$out.err"; }
DEP='select(.kind == "StatefulSet" and .metadata.labels."app.kubernetes.io/component" == "daemon") | .spec.template'
MC="$DEP | .spec.containers[] | select(.name == \"open-design\")"
env_of() { yy "$MC | .env[] | select(.name == \"$1\") | .value" "$2"; }
NP='select(.kind == "NetworkPolicy" and .metadata.name == "t-open-design-allow") | .spec.egress[] | select(.ports[0].port == 8000)'

echo "== vendored kit"
kit_assert_vendored "$CHART_DIR" || rc=1

echo "== 0.5.0 default: Omnigent host OFF (paused) — nothing of the kit is rendered"
RD=$TMP/off.yaml
render_default "$RD" --set config.allowedOrigins=https://od.example.com || { cat "$RD.err"; exit 1; }
t "off: no OG_* env in the daemon" "$(cnt "$MC | .env[] | select(.name | test(\"^OG_\")) | .name" "$RD")" "0"
t "off: no kit mounts" "$(cnt "$MC | .volumeMounts[] | select(.name | test(\"omnigent\")) | .name" "$RD")" "0"
t "off: no kit volumes" "$(cnt "$DEP | .spec.volumes[] | select(.name | test(\"omnigent\")) | .name" "$RD")" "0"
t "off: no Omnigent ConfigMaps" "$(cnt 'select(.kind == "ConfigMap" and (.metadata.name | test("omnigent"))) | .metadata.name' "$RD")" "0"
t "off: no NetworkPolicy hole to Omnigent :8000" "$(cnt "$NP | .ports[0].port" "$RD")" "0"
t "off: no checksum/omnigent-* annotation" "$(cnt "$DEP | .metadata.annotations | keys | .[] | select(test(\"omnigent\"))" "$RD")" "0"
t "off: daemon args unchanged" "$(yy "$MC | .args | join(\" \")" "$RD")" "node apps/daemon/bin/od.mjs --host 127.0.0.1 --port 7457 --no-open"
t "off: grace period = values (45, no kit floor needed)" "$(yy "$DEP | .spec.terminationGracePeriodSeconds" "$RD")" "45"
t "off: pod = daemon + authproxy" "$(yy "$DEP | [.spec.containers[].name] | join(\",\")" "$RD")" "open-design,authproxy"
render_default "$RD" --set config.allowedOrigins=https://od.example.com --set mcp.enabled=true || { cat "$RD.err"; exit 1; }
t "off + mcp: pod = daemon + mcp + authproxy" "$(yy "$DEP | [.spec.containers[].name] | join(\",\")" "$RD")" "open-design,mcp,authproxy"
t "off + mcp: no OG_* env anywhere" "$(cnt "$DEP | .spec.containers[].env[]? | select(.name | test(\"^OG_\")) | .name" "$RD")" "0"
t "off + mcp: no Omnigent ConfigMaps" "$(cnt 'select(.kind == "ConfigMap" and (.metadata.name | test("omnigent"))) | .metadata.name' "$RD")" "0"

echo "== kit ON (omnigentHost.enabled=true): in-container contract"
R=$TMP/default.yaml
render "$R" --set config.allowedOrigins=https://od.example.com || { cat "$R.err"; exit 1; }
kit_assert_in_container "$R" open-design image || rc=1
t "pod = daemon + authproxy only (no sidecar, as before the Omnigent work)" "$(yy "$DEP | [.spec.containers[].name] | join(\",\")" "$R")" "open-design,authproxy"
# 0.5.0: the platform turns on the built-in MCP sidecar. The Omnigent host stays IN the daemon
# container (still no Omnigent sidecar); the only other container is the MCP server `mcp`.
RM=$TMP/mcp.yaml
render "$RM" --set config.allowedOrigins=https://od.example.com --set mcp.enabled=true || { cat "$RM.err"; exit 1; }
kit_assert_in_container "$RM" open-design image || rc=1
t "mcp.enabled: pod = daemon + mcp + authproxy" "$(yy "$DEP | [.spec.containers[].name] | join(\",\")" "$RM")" "open-design,mcp,authproxy"
t "mcp.enabled: no Omnigent env in the mcp container" "$(cnt "$DEP | .spec.containers[] | select(.name == \"mcp\") | .env[] | select(.name | test(\"^(OG_|OMNIGENT)\")) | .name" "$RM")" "0"
# 0.3.0 (#1360): the htpasswd is a Secret volume, so the chart-managed default has
# only seed-home (authproxy-init remains for auth.existingSecret — test-home-seed.sh).
# 0.4.0 (#1437 / #1438): agent-defaults (default agent + OpenCode model) after seed-home.
t "init containers (seed-home, agent-defaults, prune-runs)" "$(yy "$DEP | [.spec.initContainers[].name] | join(\",\")" "$R")" "seed-home,agent-defaults,prune-runs"
t "daemon: no command override (image ENTRYPOINT tini → omnigent-host-entry stays)" "$(yy "$MC | has(\"command\")" "$R")" false
t "daemon: args still start the daemon" "$(yy "$MC | .args | join(\" \")" "$R")" "node apps/daemon/bin/od.mjs --host 127.0.0.1 --port 7457 --no-open"
t "daemon resources = the full plan values (no split)" "$(yy "$MC | .resources | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory] | join(\",\")" "$R")" "1,2Gi,4,8Gi"
t "terminationGracePeriodSeconds >= 45 (host stop + daemon stop)" "$(yy "$DEP | .spec.terminationGracePeriodSeconds" "$R")" 45
t "fsGroupChangePolicy OnRootMismatch (0600 token file survives mounts)" "$(yy "$DEP | .spec.securityContext.fsGroupChangePolicy" "$R")" OnRootMismatch

echo "== OpenDesign parameters"
t "OG_CONFIG_HOME on od-home" "$(env_of OG_CONFIG_HOME "$R")" /home/opendesign/.omnigent
t "OMNIGENT_CONFIG_HOME = the image's (console login lands there)" "$(env_of OMNIGENT_CONFIG_HOME "$R")" /home/opendesign/.omnigent
t "OG_DATA_DIR = config home" "$(env_of OG_DATA_DIR "$R")" /home/opendesign/.omnigent
t "no OG_HOME (HOME stays /home/opendesign)" "$(cnt "$MC | .env[] | select(.name == \"OG_HOME\") | .name" "$R")" 0
t "OG_WORKSPACE ~/studio" "$(env_of OG_WORKSPACE "$R")" /home/opendesign/studio
t "OG_HOST_NAME default" "$(env_of OG_HOST_NAME "$R")" "open-design · t"
t "OG_WATCH_SECONDS default 120" "$(env_of OG_WATCH_SECONDS "$R")" 120
t "OG_PROVIDERS claude-subscription" "$(env_of OG_PROVIDERS "$R")" claude-subscription
t "OG_WORKSPACE_SEED_DIR" "$(env_of OG_WORKSPACE_SEED_DIR "$R")" /etc/omnigent-host-seed
t "OG_WORKSPACE_SEED_UPDATE = CLAUDE.md only" "$(env_of OG_WORKSPACE_SEED_UPDATE "$R")" CLAUDE.md
# #1440: by default only OpenDesign's internal token is kept from the host; the platform's
# LLM keys reach it (OpenCode via OpenRouter / Claude Code via an Anthropic key).
t "OG_UNSET_ENV = OD_API_TOKEN only (platform LLM keys usable on the host)" "$(env_of OG_UNSET_ENV "$R")" OD_API_TOKEN
R7=$TMP/strip.yaml
render "$R7" --set omnigentHost.stripApiKeys=true || { cat "$R7.err"; rc=1; }
for k in ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN OD_API_TOKEN; do
  case ",$(env_of OG_UNSET_ENV "$R7")," in
    *",$k,"*) ok "stripApiKeys=true: OG_UNSET_ENV strips $k from the host" ;;
    *) bad "stripApiKeys=true: OG_UNSET_ENV misses $k: $(env_of OG_UNSET_ENV "$R7")" ;;
  esac
done
for k in NODE_PATH NODE_OPTIONS PUPPETEER_EXECUTABLE_PATH; do
  case ",$(env_of OG_PASSTHROUGH "$R")," in
    *",$k,"*) ok "OG_PASSTHROUGH carries $k" ;;
    *) bad "OG_PASSTHROUGH misses $k" ;;
  esac
done
t "daemon keeps the chart Secret env (OpenDesign's own runs)" "$(cnt "$MC | .env[] | select(.name == \"OD_API_TOKEN\") | .name" "$R")" 1
t "seed mounted read-only" "$(yy "$MC | .volumeMounts[] | select(.mountPath == \"/etc/omnigent-host-seed\") | .readOnly" "$R")" true
t "seed volume selects the three seed keys" "$(yy "$DEP | .spec.volumes[] | select(.name == \"omnigent-seed\") | [.configMap.items[].path] | join(\",\")" "$R")" "CLAUDE.md,.mcp.json,.claude__settings.json"
t "/console/ bash hook = the kit profile (/etc/bash/*.sh)" "$(yy "$MC | .volumeMounts[] | select(.mountPath == \"/etc/bash/omnigent-host.sh\") | .subPath" "$R")" omnigent-host-profile.sh
t "/console/ bash hook comes from the kit ConfigMap" "$(yy "$MC | .volumeMounts[] | select(.mountPath == \"/etc/bash/omnigent-host.sh\") | .name" "$R")" omnigent-host-kit
t "status printer on the default PATH too" "$(yy "$MC | .volumeMounts[] | select(.mountPath == \"/usr/local/bin/omnigent-host-status\") | .subPath" "$R")" omnigent-host-status
for k in runAsNonRoot:true runAsUser:1001 allowPrivilegeEscalation:false privileged:false; do
  t "daemon securityContext ${k%%:*}" "$(yy "$MC | .securityContext.${k%%:*}" "$R")" "${k#*:}"
done
t "daemon drops ALL capabilities" "$(yy "$MC | .securityContext.capabilities.drop | join(\",\")" "$R")" ALL
t "daemon seccomp RuntimeDefault" "$(yy "$MC | .securityContext.seccompProfile.type" "$R")" RuntimeDefault
t "default container annotation = daemon" "$(yy "$DEP | .metadata.annotations.\"kubectl.kubernetes.io/default-container\"" "$R")" open-design

echo "== ConfigMaps"
KITCM='select(.kind == "ConfigMap" and .metadata.name == "t-open-design-omnigent-host")'
for f in supervisor.sh og_helper.py omnigent-host-status omnigent-host-launch omnigent-host-profile.sh omnigent-shim; do
  if python3 - "$R" "$f" "$CHART_DIR/files/omnigent-host/$f" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "t-open-design-omnigent-host"]
sys.exit(0 if len(docs) == 1 and docs[0]["data"][sys.argv[2]] == open(sys.argv[3]).read() else 1)
PY
  then ok "kit ConfigMap $f == vendored file (byte-identical)"; else bad "kit ConfigMap $f differs from files/omnigent-host/$f"; fi
done
t "runtime ConfigMap exists (server-url)" "$(cnt 'select(.kind == "ConfigMap" and .metadata.name == "t-open-design-omnigent-host-runtime") | .metadata.name' "$R")" 1
t "kit ConfigMap holds no server URL" "$(cnt "$KITCM | .data | keys | .[] | select(. == \"server-url\")" "$R")" 0
ODCM='select(.kind == "ConfigMap" and .metadata.name == "t-open-design-omnigent-od") | .data'
yq "$ODCM | .\".mcp.json\"" "$R" | grep -v '^---$' >"$TMP/mcp.json"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["mcpServers"]["open-design"]; assert d["args"][-1]=="http://127.0.0.1:7457" and d["env"]["OD_DATA_DIR"]=="/app/.od" and d["command"]=="/usr/local/bin/node"' "$TMP/mcp.json"; then ok ".mcp.json: OpenDesign MCP over loopback"; else bad ".mcp.json content"; fi
yq "$ODCM | .\".claude__settings.json\"" "$R" | grep -v '^---$' >"$TMP/settings.json"
if python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; assert "mcp__open-design__delete_project" in p["deny"] and "mcp__open-design" in p["allow"]' "$TMP/settings.json"; then ok ".claude/settings.json: allow OD tools, deny delete"; else bad ".claude/settings.json content"; fi
if yq "$ODCM | .\"CLAUDE.md\"" "$R" | grep -q 'https://od.example.com'; then ok "CLAUDE.md carries the OpenDesign URL"; else bad "CLAUDE.md has no OpenDesign URL"; fi
R1=$TMP/seedchange.yaml
render "$R1" --set config.allowedOrigins=https://other.example.com || { cat "$R1.err"; rc=1; }
a=$(yy "$DEP | .metadata.annotations.\"checksum/omnigent-od\"" "$R"); b=$(yy "$DEP | .metadata.annotations.\"checksum/omnigent-od\"" "$R1")
if [ -n "$a" ] && [ "$a" != "$b" ]; then ok "a seed change rolls the pod (checksum/omnigent-od)"; else bad "seed checksum does not follow the seed ('$a' / '$b')"; fi

echo "== serverUrl is runtime data"
kit_assert_runtime_server_url "$CHART_DIR" --namespace paas-ws-test --set omnigentHost.enabled=true || rc=1

echo "== NetworkPolicy"
t "egress to Omnigent pods :8000 (name)" "$(yy "$NP | .to[0].podSelector.matchLabels.\"app.kubernetes.io/name\"" "$R")" omnigent
t "egress to Omnigent SERVER pods only (component=server)" "$(yy "$NP | .to[0].podSelector.matchLabels.\"app.kubernetes.io/component\"" "$R")" server
t "no namespaceSelector (same namespace only)" "$(yy "$NP | .to[0] | has(\"namespaceSelector\")" "$R")" false
t "no ipBlock in that rule" "$(cnt "$NP | .to[] | select(has(\"ipBlock\")) | .ipBlock.cidr" "$R")" 0
t "only port 8000 in that rule" "$(cnt "$NP | .ports[] | .port" "$R")" 1
R2=$TMP/inns.yaml
render "$R2" --set omnigentHost.serverUrl=http://svc-5fd48417-omnigent.paas-ws-test.svc.cluster.local:8000/ || { cat "$R2.err"; rc=1; }
t "in-cluster serverUrl pins the Omnigent release" "$(yy "$NP | .to[0].podSelector.matchLabels.\"app.kubernetes.io/instance\"" "$R2")" svc-5fd48417
t "in-cluster serverUrl keeps component=server" "$(yy "$NP | .to[0].podSelector.matchLabels.\"app.kubernetes.io/component\"" "$R2")" server
t "in-cluster serverUrl lands in the runtime ConfigMap" "$(yy 'select(.kind == "ConfigMap" and .metadata.name == "t-open-design-omnigent-host-runtime") | .data."server-url"' "$R2")" http://svc-5fd48417-omnigent.paas-ws-test.svc.cluster.local:8000
render "$R2" --set omnigentHost.serverUrl=http://svc-5fd48417-omnigent.other-ns.svc.cluster.local:8000 || { cat "$R2.err"; rc=1; }
t "other-namespace URL: no instance pin (the rule is same-namespace anyway)" "$(yy "$NP | .to[0].podSelector.matchLabels | has(\"app.kubernetes.io/instance\")" "$R2")" false
render "$R2" --set omnigentHost.serverUrl=https://omnigent.example.com || { cat "$R2.err"; rc=1; }
t "public serverUrl: no instance pin" "$(yy "$NP | .to[0].podSelector.matchLabels | has(\"app.kubernetes.io/instance\")" "$R2")" false
render "$R2" --set networkPolicy.omnigentEgress.enabled=false || { cat "$R2.err"; rc=1; }
t "omnigentEgress.enabled=false: no :8000 rule" "$(cnt "$NP | .ports[0].port" "$R2")" 0

echo "== docs match the in-container design"
# The rendered NetworkPolicy must not describe the host as a sidecar (round-3 review:
# the comment ships verbatim in the production manifest).
t "NetworkPolicy text never calls the host a sidecar" "$("$HELM" template t "$CHART_DIR" --namespace paas-ws-test --show-only templates/network-policy.yaml 2>/dev/null | grep -ci 'omnigent-host sidecar\|host sidecar\|sidecar + the /console')" 0
# NOTES state the accepted risk (OD's own agent runs can read the Omnigent refresh grant).
N=$TMP/notes.txt
"$HELM" install t "$CHART_DIR" --dry-run=client --namespace paas-ws-test --set omnigentHost.enabled=true --set config.allowedOrigins=https://od.example.com >"$N" 2>&1
t "NOTES: accepted-risk paragraph about the stored refresh grant" "$(grep -c 'ACCEPTED RISK: the login.s refresh grant' "$N")" 1
t "NOTES: OpenDesign's own agent runs named as readers" "$(grep -c "OpenDesign's own agent runs run as the same user" "$N")" 1
t "README: accepted-risk section" "$(grep -c '已接受的風險：od-home 裡的 admin 登入憑證，OD 自己的 agent run 也讀得到' "$CHART_DIR/README.md")" 1

echo "== --reuse-values from 0.2.1 (no omnigentHost / omnigentEgress keys, old securityContext / grace)"
cat >"$TMP/reuse.yaml" <<'EOF'
omnigentHost: null
networkPolicy:
  omnigentEgress: null
securityContext: {}
podSecurityContext:
  fsGroup: 1001
terminationGracePeriodSeconds: 30
EOF
R4=$TMP/reuse.out.yaml
# A real --reuse-values release has no omnigentHost key: the kit helper treats a missing key as
# enabled (shared kit contract), so the platform passes omnigentHost.enabled=false explicitly (0.5.0).
render_default "$R4" -f "$TMP/reuse.yaml" || { cat "$R4.err"; rc=1; }
kit_assert_in_container "$R4" open-design image >"$TMP/reuse-kit.log" || { cat "$TMP/reuse-kit.log"; bad "reuse-values: in-container contract"; }
t "reuse-values: resources = values (1/2Gi–4/8Gi)" "$(yy "$MC | .resources | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory] | join(\",\")" "$R4")" "1,2Gi,4,8Gi"
t "reuse-values: grace raised to 45" "$(yy "$DEP | .spec.terminationGracePeriodSeconds" "$R4")" 45
t "reuse-values: fsGroupChangePolicy added" "$(yy "$DEP | .spec.securityContext.fsGroupChangePolicy" "$R4")" OnRootMismatch
t "reuse-values: daemon still hardened" "$(yy "$MC | .securityContext.allowPrivilegeEscalation" "$R4")" false
t "reuse-values: Omnigent egress rule present" "$(yy "$NP | .to[0].podSelector.matchLabels.\"app.kubernetes.io/component\"" "$R4")" server
t "reuse-values: platform LLM keys reach the host (#1440)" "$(env_of OG_UNSET_ENV "$R4")" OD_API_TOKEN

echo "== toggles"
R6=$TMP/off.yaml
render "$R6" --set omnigentHost.enabled=false || { cat "$R6.err"; rc=1; }
kit_assert_disabled "$R6" open-design || rc=1
t "enabled=false: telemetry env stays (a CLI run by hand)" "$(env_of DO_NOT_TRACK "$R6")" 1
t "enabled=false: no omnigent ConfigMaps" "$(yq 'select(.kind == "ConfigMap") | .metadata.name' "$R6" | grep -c omnigent)" 0
t "enabled=false: no :8000 egress" "$(cnt "$NP | .ports[0].port" "$R6")" 0
t "enabled=false: daemon has no OG_* / OMNIGENT_*_HOME env" "$(cnt "$MC | .env[] | select(.name | test(\"^(OG_|OMNIGENT_CONFIG|OMNIGENT_DATA)\")) | .name" "$R6")" 0
t "enabled=false: daemon has no omnigent mounts" "$(cnt "$MC | .volumeMounts[] | select(.name | test(\"omnigent\")) | .name" "$R6")" 0
t "enabled=false: no omnigent annotations" "$(cnt "$DEP | .metadata.annotations | keys | .[] | select(test(\"omnigent\"))" "$R6")" 0
t "enabled=false: resources unchanged" "$(yy "$MC | .resources.limits.memory" "$R6")" 8Gi
t "enabled=false: grace = values" "$(yy "$DEP | .spec.terminationGracePeriodSeconds" "$R6")" 45
render "$R6" --set omnigentHost.seedWorkspace=false --set omnigentHost.stripApiKeys=false || { cat "$R6.err"; rc=1; }
t "seedWorkspace=false: no seed dir" "$(env_of OG_WORKSPACE_SEED_DIR "$R6")" ""
t "seedWorkspace=false: no seed volume" "$(cnt "$DEP | .spec.volumes[] | select(.name == \"omnigent-seed\") | .name" "$R6")" 0
t "seedWorkspace=false: no seed mount" "$(cnt "$MC | .volumeMounts[] | select(.name == \"omnigent-seed\") | .name" "$R6")" 0
t "stripApiKeys=false: OG_UNSET_ENV = OD_API_TOKEN" "$(env_of OG_UNSET_ENV "$R6")" OD_API_TOKEN

echo "== render-time validation"
must_fail() { local what=$1; shift; if render "$TMP/f.yaml" "$@"; then bad "$what should fail the render"; elif grep -q "$what" "$TMP/f.yaml.err"; then ok "rejects: $what"; else bad "$what: unexpected error $(head -c 300 "$TMP/f.yaml.err")"; fi; }
must_fail "watchSeconds" --set omnigentHost.watchSeconds=10
must_fail "seedWorkspace must be true or false" --set-string omnigentHost.seedWorkspace=yes
must_fail "stripApiKeys must be true or false" --set-string omnigentHost.stripApiKeys=1
must_fail "must be inside persistence.home.mountPath" --set omnigentHost.workspace=/tmp/studio
must_fail "hostName" --set-string 'omnigentHost.hostName=a"b'
must_fail "serverUrl" --set omnigentHost.serverUrl='http://x/?a=b'

echo "== runtime: vendored og_helper.py seeds the rendered workspace files"
SEED=$TMP/seed WS=$TMP/home/studio ST=$TMP/state
mkdir -p "$SEED" "$WS"
for k in CLAUDE.md .mcp.json .claude__settings.json; do yq "$ODCM | .\"$k\"" "$R" | grep -v '^---$' >"$SEED/$k"; done
seedrun() { OG_STATE_DIR=$ST OG_WORKSPACE=$WS OG_WORKSPACE_SEED_DIR=$SEED OG_WORKSPACE_SEED_UPDATE=CLAUDE.md python3 "$CHART_DIR/files/omnigent-host/og_helper.py" workspace >>"$TMP/seed.log" 2>&1; }
seedrun
t "CLAUDE.md seeded" "$(test -f "$WS/CLAUDE.md" && echo y)" y
t ".mcp.json seeded (valid JSON)" "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("y")' "$WS/.mcp.json" 2>/dev/null)" y
t ".claude/settings.json seeded" "$(test -f "$WS/.claude/settings.json" && echo y)" y
rm -f "$WS/.mcp.json"
printf '\n## v2 addition\n' >>"$SEED/CLAUDE.md"
seedrun
t "tenant-deleted .mcp.json not re-created (opt-out)" "$(test -e "$WS/.mcp.json" && echo back || echo gone)" gone
t "unedited CLAUDE.md updated to the new chart version" "$(grep -c 'v2 addition' "$WS/CLAUDE.md")" 1
printf 'my own rules\n' >>"$WS/CLAUDE.md"
printf '\n## v3 addition\n' >>"$SEED/CLAUDE.md"
seedrun
t "edited CLAUDE.md left alone" "$(grep -c 'v3 addition' "$WS/CLAUDE.md")" 0
t "newer CLAUDE.md offered beside it" "$(grep -c 'v3 addition' "$WS/.omnigent-seed-updates/CLAUDE.md" 2>/dev/null)" 1
t "manifest records the deletion" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"][".mcp.json"]["state"])' "$ST/workspace-seed.json")" deleted

if [ "$rc" -eq 0 ]; then echo "PASS (omnigent-host-kit): kit vendored, host in the daemon container (image launch), full plan resources, serverUrl runtime-only, NetworkPolicy scoped to the server, seed manifest rules."; else echo "FAIL (omnigent-host-kit)"; fi
exit $rc
