#!/usr/bin/env bash
#
# home dotfiles seed-if-absent contract (platform#407).
#
# WHY: the od-home PVC mounts over /home/opendesign and SHADOWS the image's
# built-in home — /etc/skel is NOT replayed by the kubelet, so a fresh instance
# has no ~/.bashrc at all. The console terminal is `kubectl exec -- /bin/bash`
# (interactive NON-login shell) which sources only /etc/bash.bashrc + ~/.bashrc,
# so ~/.bashrc is THE tenant-facing shell-customisation hook and it must exist.
#
# Part 1 — render assertions (does the initContainer exist, uid/mounts/resources).
# Part 2 — RUNTIME assertions: extract the rendered shell script and EXECUTE it
#   against temp dirs. charts#48's lesson: a text-level assertion ("the script
#   mentions .bashrc") cannot catch a copy that silently no-ops (see the busybox
#   `cp -rn SRC/.` trap in charts/home-assistant). We assert on real files.
#
# Usage:    bash charts/open-design/tests/test-home-seed.sh
# Requires: helm + yq (mikefarah).
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (home-seed): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (home-seed): $1"; exit 1; }

daemon_dep() {
  yq 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/component"=="daemon")'
}

OUT="$($HELM template t "$CHART_DIR" 2>/dev/null)"
DEP="$(printf '%s' "$OUT" | daemon_dep)"
[ -n "$DEP" ] || fail "no daemon Deployment rendered"

SEED="$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home")')"
[ -n "$SEED" ] || fail "no seed-home initContainer rendered (default values)"

# ── Part 1: render contract ──────────────────────────────────────────────────

# Same image as the daemon → no extra image dependency / pull secret / egress.
DAEMON_IMG="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[0].image')"
SEED_IMG="$(printf '%s' "$SEED" | yq '.image')"
[ "$SEED_IMG" = "$DAEMON_IMG" ] \
  || fail "seed-home image='$SEED_IMG', expected the daemon image '$DAEMON_IMG'"

# Runs as uid 1001 (opendesign): /home/opendesign is drwxrwsr-x root:opendesign
# and fsGroup=1001 makes the PVC group-writable, so files land owned by 1001.
UID_="$(printf '%s' "$SEED" | yq '.securityContext.runAsUser')"
[ "$UID_" = "1001" ] || fail "seed-home runAsUser='$UID_', expected 1001 (files must be owned by opendesign)"

# Mounts ONLY the home volume (od-data is none of its business).
HOME_MP="$(printf '%s' "$SEED" | yq '.volumeMounts[] | select(.name=="od-home") | .mountPath')"
[ "$HOME_MP" = "/home/opendesign" ] || fail "seed-home od-home mountPath='$HOME_MP', expected /home/opendesign"
MOUNT_N="$(printf '%s' "$SEED" | yq '.volumeMounts | length')"
[ "$MOUNT_N" = "1" ] || fail "seed-home mounts $MOUNT_N volumes, expected exactly 1 (od-home)"

# paas-ws-* ResourceQuota mandates requests+limits on EVERY container incl. init.
for f in requests.cpu requests.memory limits.cpu limits.memory; do
  V="$(printf '%s' "$SEED" | yq ".resources.$f")"
  { [ -n "$V" ] && [ "$V" != "null" ]; } || fail "seed-home resources.$f missing (paas-ws-* ResourceQuota rejects the pod)"
done

SCRIPT="$(printf '%s' "$SEED" | yq '.command[-1]')"
printf '%s' "$SCRIPT" | grep -q '/etc/skel' || fail "seed script does not read /etc/skel"
for f in .bashrc .profile .bash_logout; do
  printf '%s' "$SCRIPT" | grep -q -- "$f" || fail "seed script does not mention $f"
done
printf '%s' "$SCRIPT" | grep -q 'seed-if-absent' || fail "seed script is missing the seed-if-absent guard marker"
# Never clobber: no force/recursive copy, no rm.
printf '%s' "$SCRIPT" | grep -Eq 'cp +-[a-zA-Z]*[fr]' && fail "seed script uses a forcing/recursive cp — it must never overwrite tenant files"
printf '%s' "$SCRIPT" | grep -Eq '(^|[^a-z])rm ' && fail "seed script contains rm — a seeder must never delete"
# fail-soft: a cosmetic dotfile must not CrashLoop the instance.
printf '%s' "$SCRIPT" | grep -Eq '^[[:space:]]*set -e' && fail "seed script uses 'set -e' — a failed seed would block the whole pod from starting"

# Ordering: seed-home runs before authproxy-init (home first, then the gate).
IC0="$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].name')"
[ "$IC0" = "seed-home" ] || fail "initContainers[0]='$IC0', expected seed-home"
# The pre-existing authproxy-init must survive the refactor.
AP="$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="authproxy-init") | .name')"
[ "$AP" = "authproxy-init" ] || fail "authproxy-init initContainer disappeared"

# ── Toggles ──────────────────────────────────────────────────────────────────

# homeSeed.enabled=false → no seed-home, authproxy-init untouched.
OFF="$($HELM template t "$CHART_DIR" --set homeSeed.enabled=false 2>/dev/null | daemon_dep)"
S_OFF="$(printf '%s' "$OFF" | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home")')"
[ -z "$S_OFF" ] || fail "homeSeed.enabled=false still rendered seed-home"
A_OFF="$(printf '%s' "$OFF" | yq '.spec.template.spec.initContainers[0].name')"
[ "$A_OFF" = "authproxy-init" ] || fail "homeSeed off: initContainers[0]='$A_OFF', expected authproxy-init"

# basicAuth off + homeSeed on → seed-home is the ONLY initContainer.
NOAUTH="$($HELM template t "$CHART_DIR" --set authProxy.basicAuth.enabled=false 2>/dev/null | daemon_dep)"
N="$(printf '%s' "$NOAUTH" | yq '.spec.template.spec.initContainers | length')"
[ "$N" = "1" ] || fail "basicAuth off: expected exactly 1 initContainer (seed-home), got $N"
N0="$(printf '%s' "$NOAUTH" | yq '.spec.template.spec.initContainers[0].name')"
[ "$N0" = "seed-home" ] || fail "basicAuth off: initContainers[0]='$N0', expected seed-home"

# both off → the initContainers key must not be emitted at all.
NONE="$($HELM template t "$CHART_DIR" --set homeSeed.enabled=false --set authProxy.basicAuth.enabled=false 2>/dev/null | daemon_dep)"
IC_NONE="$(printf '%s' "$NONE" | yq '.spec.template.spec | has("initContainers")')"
[ "$IC_NONE" = "false" ] || fail "both seeds off: initContainers key still emitted"

# files list is values-driven.
CUSTOM="$($HELM template t "$CHART_DIR" --set 'homeSeed.files={.bashrc,.inputrc}' 2>/dev/null | daemon_dep \
  | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home") | .command[-1]')"
printf '%s' "$CUSTOM" | grep -q -- '.inputrc' || fail "homeSeed.files override did not reach the seed script"
printf '%s' "$CUSTOM" | grep -q -- '.bash_logout' && fail "homeSeed.files override did not REPLACE the default list"

# mountPath follows persistence.home.mountPath.
ALT="$($HELM template t "$CHART_DIR" --set persistence.home.mountPath=/home/alt 2>/dev/null | daemon_dep \
  | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home") | .volumeMounts[0].mountPath')"
[ "$ALT" = "/home/alt" ] || fail "seed-home mountPath='$ALT' does not follow persistence.home.mountPath"

# ── Part 2: RUNTIME — execute the rendered script against real files ─────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skel" "$TMP/home"
printf 'SKEL BASHRC\n'  > "$TMP/skel/.bashrc"
printf 'SKEL PROFILE\n' > "$TMP/skel/.profile"
printf 'SKEL LOGOUT\n'  > "$TMP/skel/.bash_logout"

render_script() {
  $HELM template t "$CHART_DIR" \
    --set "homeSeed.skelDir=$TMP/skel" \
    --set "persistence.home.mountPath=$TMP/home" 2>/dev/null \
    | daemon_dep | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home") | .command[-1]'
}
RS="$(render_script)"

# 1st run on an EMPTY home → all three dotfiles must actually appear.
sh -c "$RS" >"$TMP/log1" 2>&1 || fail "seed script exited non-zero on a fresh home (see: $(cat "$TMP/log1"))"
for f in .bashrc .profile .bash_logout; do
  [ -f "$TMP/home/$f" ] || fail "runtime: $f was NOT created on a fresh home (script log: $(cat "$TMP/log1"))"
done
[ "$(cat "$TMP/home/.bashrc")" = "SKEL BASHRC" ] || fail "runtime: seeded .bashrc content does not match /etc/skel"

# 2nd run with a tenant-customised file → must NOT be overwritten (the whole point).
printf 'TENANT CUSTOM\n' > "$TMP/home/.profile"
rm -f "$TMP/home/.bashrc"          # simulate a file the tenant deleted → gets re-seeded
sh -c "$RS" >"$TMP/log2" 2>&1 || fail "seed script exited non-zero on a populated home"
[ "$(cat "$TMP/home/.profile")" = "TENANT CUSTOM" ] \
  || fail "runtime: tenant-customised .profile WAS OVERWRITTEN (seed-if-absent violated)"
[ -f "$TMP/home/.bashrc" ] || fail "runtime: missing .bashrc was not re-seeded on the 2nd start (seed must be per-start, not first-install-only)"

# A dotfile absent from skel must not break the run.
rm -f "$TMP/skel/.bash_logout" "$TMP/home/.bash_logout"
sh -c "$RS" >"$TMP/log3" 2>&1 || fail "seed script exited non-zero when a skel source was missing"
[ -f "$TMP/home/.bashrc" ] || fail "runtime: 3rd run lost .bashrc"

# Unwritable home → fail-soft (exit 0), never CrashLoop the instance.
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TMP/ro"
  RO_RS="$($HELM template t "$CHART_DIR" --set "homeSeed.skelDir=$TMP/skel" \
    --set "persistence.home.mountPath=$TMP/ro" 2>/dev/null | daemon_dep \
    | yq '.spec.template.spec.initContainers[] | select(.name=="seed-home") | .command[-1]')"
  chmod 500 "$TMP/ro"
  sh -c "$RO_RS" >"$TMP/log4" 2>&1 \
    || { chmod 700 "$TMP/ro"; fail "seed script exited non-zero on an unwritable home — this would CrashLoop the instance"; }
  chmod 700 "$TMP/ro"
  grep -qi 'warn' "$TMP/log4" || fail "unwritable home produced no warning in the log"
fi

echo "PASS (home-seed): seed-home initContainer (daemon image, uid 1001, od-home only, quota-safe), seed-if-absent verified BY EXECUTION (creates on empty, never overwrites, re-seeds a deleted file, tolerates missing skel + unwritable home), toggles + files/mountPath values-driven."
