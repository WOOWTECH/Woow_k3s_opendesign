#!/usr/bin/env bash
#
# Container hardening + update footprint (0.5.1, AI-OD-007-4 / AI-OD-005-1).
#   - console (baked image): non-root uid 10002, drop ALL, no privilege escalation, RuntimeDefault,
#     read-only root fs with emptyDir /app and /tmp, HOME=/tmp; console.runtimeInstall (apt/pip at
#     start) keeps its old, root spec; console.securityContext / runAsUser override
#   - auth proxy sidecar + htpasswd init container: nginx-unprivileged uid 101, non-root, drop ALL,
#     no privilege escalation, RuntimeDefault; authProxy.securityContext overrides
#   - pod level: seccomp RuntimeDefault by default (covers seed-home too), also when the
#     podSecurityContext of an older values set lacks it; an explicit value wins; fsGroup kept
#   - every container of both pods is non-root and has no capabilities and no privilege escalation
#   - update footprint: the daemon StatefulSet is RollingUpdate with ONE replica (delete-then-create,
#     no surge) and the console Deployment is Recreate, so an update never needs more ResourceQuota
#     than the running pods already hold; no helm hook Job/Pod; the limits sums are printed
#
# Usage:    bash charts/open-design/tests/test-hardening.sh
# Requires: helm + yq (mikefarah).
set -uo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (hardening): yq (mikefarah) required"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
t() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', expected '$3'"; fi; }
cl() { sed -e '/^---$/d' -e '/^$/d'; }   # yq prints an empty document for every non-matching resource
R="$TMP/r.yaml"
render() { $HELM template t "$CHART_DIR" "$@" > "$R" 2>"$R.err" || { cat "$R.err"; exit 1; }; }
CON='select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "console") | .spec.template.spec'
STS='select(.kind == "StatefulSet") | .spec.template.spec'
q() { yq "$1" "$R" | cl; }
SEC='[.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.runAsGroup, .securityContext.allowPrivilegeEscalation, .securityContext.privileged, .securityContext.readOnlyRootFilesystem, .securityContext.capabilities.drop[0], .securityContext.seccompProfile.type] | join(",")'

echo "== console"
render
t "console container hardened" "$(q "$CON | .containers[0] | $SEC")" "true,10002,10002,false,false,true,ALL,RuntimeDefault"
t "console: writable emptyDirs /app and /tmp, HOME=/tmp" "$(q "$CON | [(.containers[0].volumeMounts[] | select(.name == \"app\" or .name == \"tmp\") | .name + \":\" + .mountPath), (.containers[0].env[] | select(.name == \"HOME\") | \"HOME=\" + .value)] | join(\",\")")" "app:/app,tmp:/tmp,HOME=/tmp"
t "console: the emptyDirs are size-limited" "$(q "$CON | [.volumes[] | select(.name == \"app\" or .name == \"tmp\") | .emptyDir.sizeLimit] | join(\",\")")" "16Mi,64Mi"
t "console: service account token still mounted (kubectl exec needs it)" "$(q "$CON | .automountServiceAccountToken // \"default\"")" "default"
render --set console.runtimeInstall=true
t "runtimeInstall keeps the old root spec (apt/pip at start)" "$(q "$CON | .containers[0] | has(\"securityContext\")")" "false"
t "runtimeInstall: no read-only mounts either" "$(q "$CON | [.containers[0].volumeMounts[].name] | join(\",\")")" "scripts,html"
render --set console.runAsUser=20000
t "console.runAsUser" "$(q "$CON | .containers[0] | [.securityContext.runAsUser, .securityContext.runAsGroup] | join(\",\")")" "20000,20000"
render --set console.securityContext.readOnlyRootFilesystem=false
t "console.securityContext wins over the defaults" "$(q "$CON | .containers[0] | [.securityContext.readOnlyRootFilesystem, .securityContext.runAsNonRoot] | join(\",\")")" "false,true"
render --set console.enabled=false
t "console.enabled=false: no console Deployment" "$(q "$CON | .containers[0].name" | grep -c console)" "0"

echo "== auth proxy"
render
t "authproxy sidecar hardened" "$(q "$STS | .containers[] | select(.name == \"authproxy\") | [.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.runAsGroup, .securityContext.allowPrivilegeEscalation, .securityContext.capabilities.drop[0], .securityContext.seccompProfile.type] | join(\",\")")" "true,101,101,false,ALL,RuntimeDefault"
t "authproxy keeps a writable root fs (nginx temp dirs)" "$(q "$STS | .containers[] | select(.name == \"authproxy\") | .securityContext.readOnlyRootFilesystem // \"unset\"")" "unset"
render --set auth.existingSecret=ext
t "authproxy-init hardened" "$(q "$STS | .initContainers[] | select(.name == \"authproxy-init\") | [.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.allowPrivilegeEscalation, .securityContext.capabilities.drop[0], .securityContext.seccompProfile.type] | join(\",\")")" "true,101,false,ALL,RuntimeDefault"
render --set authProxy.securityContext.runAsUser=102
t "authProxy.securityContext wins over the defaults" "$(q "$STS | .containers[] | select(.name == \"authproxy\") | [.securityContext.runAsUser, .securityContext.runAsNonRoot] | join(\",\")")" "102,true"

echo "== daemon (and its agent-defaults / prune-runs init containers) — AI-FIX-OD-1-1"
DSEC='[.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.runAsGroup, .securityContext.allowPrivilegeEscalation, .securityContext.privileged, .securityContext.capabilities.drop[0], .securityContext.seccompProfile.type] | join(",")'
DAEMONS="$STS | [.initContainers[], .containers[]] | map(select(.name == \"open-design\" or .name == \"agent-defaults\" or .name == \"prune-runs\"))"
render
t "daemon container hardened" "$(q "$STS | .containers[] | select(.name == \"open-design\") | $DSEC")" "true,1001,1001,false,false,ALL,RuntimeDefault"
t "the three daemon-image containers share one spec" "$(q "$DAEMONS | map($DSEC) | unique | join(\";\")")" "true,1001,1001,false,false,ALL,RuntimeDefault"
render --set securityContext=null
t "a values set without securityContext still gets the defaults (reuse-values)" "$(q "$STS | .containers[] | select(.name == \"open-design\") | $DSEC")" "true,1001,1001,false,false,ALL,RuntimeDefault"
render --set-json 'securityContext={}'
t "securityContext: {} (0.2.x reuse-values) still gets the defaults" "$(q "$STS | .containers[] | select(.name == \"open-design\") | $DSEC")" "true,1001,1001,false,false,ALL,RuntimeDefault"
render --set securityContext.allowPrivilegeEscalation=true
t "an explicit true wins over a default false" "$(q "$STS | .containers[] | select(.name == \"open-design\") | .securityContext.allowPrivilegeEscalation")" "true"
# sprig's merge treats false as empty, so before 0.5.5 these rendered the default (true / RuntimeDefault).
render --set securityContext.runAsNonRoot=false --set securityContext.runAsUser=0
t "an explicit false wins over a default true (runAsNonRoot=false)" "$(q "$STS | .containers[] | select(.name == \"open-design\") | [.securityContext.runAsNonRoot, .securityContext.runAsUser] | join(\",\")")" "false,0"
t "the false override reaches all three daemon-image containers" "$(q "$DAEMONS | map(.securityContext.runAsNonRoot) | unique | join(\",\")")" "false"
render --set securityContext.readOnlyRootFilesystem=false --set securityContext.privileged=false
t "keys not in the defaults pass through, false included" "$(q "$STS | .containers[] | select(.name == \"open-design\") | [.securityContext.readOnlyRootFilesystem, .securityContext.privileged] | join(\",\")")" "false,false"
render --set securityContext.seccompProfile.type=Unconfined
t "a nested override replaces that key" "$(q "$STS | .containers[] | select(.name == \"open-design\") | .securityContext.seccompProfile.type")" "Unconfined"

echo "== pod level"
render
t "pod seccomp RuntimeDefault + fsGroup kept" "$(q "$STS | [.securityContext.seccompProfile.type, .securityContext.fsGroup, .securityContext.fsGroupChangePolicy] | join(\",\")")" "RuntimeDefault,1001,OnRootMismatch"
render --set podSecurityContext=null
t "a values set without podSecurityContext still gets seccomp (reuse-values)" "$(q "$STS | .securityContext.seccompProfile.type")" "RuntimeDefault"
render --set podSecurityContext.seccompProfile.type=Unconfined
t "an explicit pod seccomp wins" "$(q "$STS | .securityContext.seccompProfile.type")" "Unconfined"

echo "== every container of both pods"
render
t "daemon pod: all containers non-root, no caps, no escalation" "$(q "$STS | [.initContainers[], .containers[]] | map(select(.securityContext.runAsNonRoot == true and .securityContext.allowPrivilegeEscalation == false and .securityContext.capabilities.drop[0] == \"ALL\")) | length")" "$(q "$STS | [.initContainers[], .containers[]] | length")"
t "console pod: all containers non-root, no caps, no escalation" "$(q "$CON | .containers | map(select(.securityContext.runAsNonRoot == true and .securityContext.allowPrivilegeEscalation == false and .securityContext.capabilities.drop[0] == \"ALL\")) | length")" "1"
# PSA "restricted" would also accept the pods: runAsNonRoot + seccomp are set on every container or the pod.
t "no container asks for privileged" "$(yq '.. | select(has("privileged")) | .privileged' "$R" | cl | grep -c true)" "0"

echo "== update footprint (AI-OD-005-1): an update never needs more quota than the running pods hold"
render
t "daemon: RollingUpdate, 1 replica, no surge (delete-then-create)" "$(q "select(.kind == \"StatefulSet\") | [.spec.updateStrategy.type, .spec.replicas, (.spec.updateStrategy.rollingUpdate.maxSurge // \"none\")] | join(\",\")")" "RollingUpdate,1,none"
t "console: Recreate (old pod gone before the new one starts)" "$(q "select(.kind == \"Deployment\" and .metadata.labels.\"app.kubernetes.io/component\" == \"console\") | [.spec.strategy.type, .spec.replicas, (.spec.strategy.rollingUpdate.maxSurge // \"none\")] | join(\",\")")" "Recreate,1,none"
t "no helm hook / extra Job or Pod" "$(yq 'select(.kind == "Job" or .kind == "CronJob" or .kind == "Pod" or (.metadata.annotations."helm.sh/hook" != null)) | .kind' "$R" | cl | wc -l | tr -d ' ')" "0"
# informational: what the pods hold against limits.memory (quota counts max(init, sum(containers)))
SUMS="$(yq 'select(.kind == "StatefulSet" or .kind == "Deployment") | .metadata.name + " " + ([.spec.template.spec.containers[].resources.limits.memory] | join("+"))' "$R" | cl)"
echo "  info limits.memory per pod: $(echo "$SUMS" | tr '\n' ';')"

[ $rc -eq 0 ] && echo "PASS (hardening)" || echo "FAIL (hardening)"
exit $rc
