#!/usr/bin/env bash
# Chart rendering lane.
#
# The whole reason this repo is being rewritten is that its chart was never
# actually installed: `helm install` was rejected by the API server because the
# nodeSelector carried a literal `__K3S_NODE_HOSTNAME__`. This lane makes that
# class of defect impossible to merge:
#
#   1. `helm lint` with the DEFAULT values and with the values a real install
#      uses. The defaults must render: a chart whose own values.yaml cannot be
#      templated cannot be linted by chart-testing, cannot be kubeconformed on
#      the default path, and tells every reader to guess.
#   2. `helm template` must SUCCEED for every values combination this repo ships
#      and FAIL for every negative fixture — one per render-time guard, so a
#      guard that silently stops firing fails the build
#   3. schema validation of every rendered object (kubeconform, when present)
#   4. retention assertions: keepOnUninstall on/off decides
#      helm.sh/resource-policy on both PVCs and on the chart-created Secret
#   5. server-side dry-run against woow-k3s (read-only, when a kubeconfig exists)
#   6. tests/chart-manifest.test.py — the property assertions
#   7. packaging: every chart file is tracked by git and lands in the tarball
#      (an unanchored .gitignore pattern once dropped a template silently)
#
# Step 4 never mutates the cluster: `kubectl apply --dry-run=server` only asks
# the API server to admit-and-discard. There is no `apply` in this file.
set -Eeuo pipefail

# shellcheck source=lib/layout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/layout.sh"
cd "$REPO_ROOT"

require_command helm "chart lane"
require_paths "chart lane" \
  "$CHART_DIR/Chart.yaml" \
  "$CHART_DIR/values.yaml" \
  "$CHART_DIR/templates" \
  "$REPO_ROOT/tests/values/full.yaml" \
  "$REPO_ROOT/tests/values/minimal.yaml" \
  "$REPO_ROOT/tests/values/extras.yaml" \
  "$REPO_ROOT/tests/values/no-keep.yaml" \
  "$REPO_ROOT/tests/values/no-public-url.yaml" \
  "$REPO_ROOT/deploy/woow-k3s/opendesign.yaml"

mkdir -p "$ARTIFACTS"
namespace=${OD_TEST_NAMESPACE:-pi-agent-woow}
release=${OD_TEST_RELEASE:-od}

# ---------------------------------------------------------------------- lint
echo "== helm lint (shipped defaults, no -f at all) =="
# The defaults MUST be renderable. publicUrl ships as an example origin for
# exactly this reason; an empty one is still a hard failure (see below).
helm lint "$CHART_DIR"
echo "== helm lint (full values) =="
helm lint "$CHART_DIR" --values tests/values/full.yaml
echo "== helm lint (minimal values, backup disabled) =="
helm lint "$CHART_DIR" --values tests/values/minimal.yaml
echo "== helm lint (every opt-in on) =="
helm lint "$CHART_DIR" --values tests/values/extras.yaml
echo "== helm lint (live instance values) =="
helm lint "$CHART_DIR" --values deploy/woow-k3s/opendesign.yaml

# ------------------------------------------------------------------- renders
# Every values combination the repository ships must render. `helm lint` alone
# is not enough: it reports a template failure as [INFO] and still exits 0.
render_ok() {
  local label=$1 out=$2
  shift 2
  if ! helm template "$release" "$CHART_DIR" --namespace "$namespace" "$@" \
       >"$ARTIFACTS/$out" 2>"$ARTIFACTS/$out.err"; then
    echo "FAIL: $label did not render:" >&2
    sed 's/^/      /' "$ARTIFACTS/$out.err" >&2
    exit 1
  fi
  echo "rendered: $label -> $(grep -c '^kind:' "$ARTIFACTS/$out") object(s)"
}

# Each of these is a guard whose whole value is that it FAILS. A guard that
# stops firing is invisible until something is already broken in the cluster,
# so every one of them is asserted here, by message.
render_must_fail() {
  local label=$1 expect=$2
  shift 2
  local err="$ARTIFACTS/must-fail.err"
  if helm template "$release" "$CHART_DIR" --namespace "$namespace" "$@" \
       >/dev/null 2>"$err"; then
    echo "FAIL: $label rendered, but this input must be rejected at render time." >&2
    exit 1
  fi
  if ! grep -Fq -- "$expect" "$err"; then
    echo "FAIL: $label was rejected, but not by the expected guard." >&2
    echo "      expected to find: $expect" >&2
    sed 's/^/      got: /' "$err" >&2
    exit 1
  fi
  echo "rejected: $label"
}

echo "== helm template: every shipped values combination =="
render_ok "shipped defaults"     rendered-default.yaml
render_ok "full values"          rendered-full.yaml   --values tests/values/full.yaml
render_ok "minimal values"       rendered-min.yaml    --values tests/values/minimal.yaml
render_ok "every opt-in on"      rendered-extras.yaml --values tests/values/extras.yaml
render_ok "keepOnUninstall off"  rendered-nokeep.yaml --values tests/values/no-keep.yaml
render_ok "live instance values" rendered-live.yaml   --values deploy/woow-k3s/opendesign.yaml

# chart/ci/*-values.yaml is the chart-testing convention: one file per
# configuration `ct lint` should install. They are excluded from the packaged
# tarball by .helmignore, which also means nothing would ever notice them
# rotting, so they are rendered here too.
echo "== helm template: the chart-testing fixtures in $CHART_DIR/ci =="
shopt -s nullglob
ci_fixtures=("$CHART_DIR"/ci/*-values.yaml)
shopt -u nullglob
if (( ${#ci_fixtures[@]} == 0 )); then
  echo 'FAIL: no chart/ci/*-values.yaml fixtures found; chart-testing would have nothing to install.' >&2
  exit 1
fi
for fixture in "${ci_fixtures[@]}"; do
  helm lint "$CHART_DIR" --values "$fixture" >/dev/null
  render_ok "ci/$(basename "$fixture")" "rendered-ci-$(basename "$fixture")" --values "$fixture"
done

echo "== helm template: every render-time guard must fire =="
render_must_fail "an empty publicUrl" \
  "publicUrl is required" --values tests/values/no-public-url.yaml
# Two layers guard publicUrl and the schema is the outer one, so this is the
# message that actually comes back. The template's own regex (`publicUrl must be
# an https:// origin`) is the floor under it, for the paths helm evaluates
# before/without the schema.
render_must_fail "a non-https publicUrl" \
  "does not match pattern" --values tests/values/bad-public-url.yaml
render_must_fail "a chart-owned env key in extraEnv" \
  "it is chart-owned" --values tests/values/reserved-extra-env.yaml
render_must_fail "a credential-shaped key in the cleartext extraEnv" \
  "looks like a credential" --values tests/values/secret-shaped-extra-env.yaml
render_must_fail "create: true with no data" \
  "requires opendesign.extraEnvSecret.data" --values tests/values/extra-env-secret-empty.yaml
render_must_fail "create: true with an empty value" \
  "is empty" --values tests/values/extra-env-secret-blank-value.yaml
render_must_fail "the same key in extraEnv and in the Secret" \
  "set in BOTH" --values tests/values/extra-env-secret-conflict.yaml
render_must_fail "a Secret nothing would read" \
  "has no effect while" --values tests/values/extra-env-secret-orphan.yaml
# Same layering: the schema rejects a moving tag and a malformed digest before
# the template's own `fail` is reached.
render_must_fail "an image pinned to a moving tag" \
  "at '/image/tag'" --set image.tag=latest --values tests/values/minimal.yaml
render_must_fail "a malformed image digest" \
  "at '/image/digest'" --set image.digest=sha256:nothex --values tests/values/minimal.yaml
# A mistyped key used to be silently ignored, which is how a chart ends up
# running with a setting its author believes is in effect.
render_must_fail "a mistyped top-level key" \
  "additional properties 'imagePullSecret' not allowed" \
  --set imagePullSecret=oops --values tests/values/minimal.yaml
render_must_fail "a mistyped key inside extraEnvSecret" \
  "additional properties 'enable' not allowed" \
  --set opendesign.extraEnvSecret.enable=true --values tests/values/minimal.yaml

# -------------------------------------------------------------- data retention
# `helm uninstall` must never be able to take the data with it. This is the
# assertion that keeps keepOnUninstall from decaying into a no-op value nothing
# reads.
echo "== uninstall keeps data: resource policies =="
python3 - "$ARTIFACTS/rendered-extras.yaml" "$ARTIFACTS/rendered-nokeep.yaml" <<'PYKEEP'
import sys
import yaml

keep_path, nokeep_path = sys.argv[1], sys.argv[2]
errors = []


def load(path):
    return [doc for doc in yaml.safe_load_all(open(path, encoding="utf-8")) if doc]


stateful = {"PersistentVolumeClaim", "Secret"}
kept = [d for d in load(keep_path) if d["kind"] in stateful]
if len(kept) != 3:
    errors.append(f"expected 2 PVCs + 1 Secret with every opt-in on, got {[d['kind'] for d in kept]}")
for doc in kept:
    policy = (doc["metadata"].get("annotations") or {}).get("helm.sh/resource-policy")
    if policy != "keep":
        errors.append(f"keepOnUninstall: true left {doc['kind']}/{doc['metadata']['name']} "
                      f"with helm.sh/resource-policy={policy!r}; `helm uninstall` would delete it")
for doc in [d for d in load(nokeep_path) if d["kind"] in stateful]:
    policy = (doc["metadata"].get("annotations") or {}).get("helm.sh/resource-policy")
    if policy is not None:
        errors.append(f"keepOnUninstall: false still annotated {doc['kind']}/{doc['metadata']['name']}; "
                      "the switch does nothing")
# A Namespace is never rendered: pi-agent-woow is Rancher-managed and shared,
# and a chart that owns the namespace can delete every neighbour in it.
for path in (keep_path, nokeep_path):
    for doc in load(path):
        if doc["kind"] == "Namespace":
            errors.append(f"{path} renders a Namespace; this chart must never own one")
for message in errors:
    print(f"ERROR: {message}", file=sys.stderr)
raise SystemExit(1 if errors else 0)
PYKEEP
echo "resource policies: OK (keepOnUninstall governs both PVCs and the created Secret)"

# ------------------------------------------------------------- secret handling
echo "== the extra-env Secret: opt-in, and never in the ConfigMap =="
python3 - "$ARTIFACTS/rendered-default.yaml" "$ARTIFACTS/rendered-full.yaml" "$ARTIFACTS/rendered-extras.yaml" <<'PYSECRET'
import sys
import yaml

default_path, full_path, extras_path = sys.argv[1:4]
errors = []


def load(path):
    return [doc for doc in yaml.safe_load_all(open(path, encoding="utf-8")) if doc]


for path in (default_path, full_path):
    for doc in load(path):
        if doc["kind"] == "Secret":
            errors.append(f"{path} rendered a Secret; secrets must be strictly opt-in")

extras = load(extras_path)
secrets = [d for d in extras if d["kind"] == "Secret"]
if len(secrets) != 1:
    errors.append(f"expected exactly one Secret with create: true, got {len(secrets)}")
deployment = next(d for d in extras if d["kind"] == "Deployment")
container = next(c for c in deployment["spec"]["template"]["spec"]["containers"]
                 if c["name"] == "opendesign")
refs = [list(item.values())[0]["name"] for item in container.get("envFrom", [])]
if secrets and secrets[0]["metadata"]["name"] not in refs:
    errors.append("the created Secret is not referenced by the OpenDesign container's envFrom")
if secrets:
    keys = set(secrets[0].get("stringData") or {})
    config = next(d for d in extras
                  if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-config"))
    overlap = keys & set(config.get("data") or {})
    if overlap:
        errors.append(f"{sorted(overlap)} is in BOTH the Secret and the cleartext ConfigMap")
    for key, value in (secrets[0].get("stringData") or {}).items():
        if not str(value).strip():
            errors.append(f"Secret key {key} rendered empty")
# The point of the whole feature: a value routed through the Secret must not
# also be sitting in a ConfigMap, where anything with `get configmaps` reads it.
for doc in extras:
    if doc["kind"] == "ConfigMap":
        for key in (doc.get("data") or {}):
            if key.endswith(("_API_KEY", "_TOKEN", "_SECRET", "_PASSWORD")):
                errors.append(f"credential-shaped key {key} in cleartext ConfigMap "
                              f"{doc['metadata']['name']}")
for message in errors:
    print(f"ERROR: {message}", file=sys.stderr)
raise SystemExit(1 if errors else 0)
PYSECRET
echo "secret handling: OK"

rendered="$ARTIFACTS/rendered.yaml"
require_paths "chart lane (run tests/lib/extract-chart-assets.py first)" "$rendered"

echo "== kubeconform (every values combination) =="
if command -v kubeconform >/dev/null 2>&1; then
  for manifest in "$rendered" \
    "$ARTIFACTS/rendered-default.yaml" \
    "$ARTIFACTS/rendered-full.yaml" \
    "$ARTIFACTS/rendered-min.yaml" \
    "$ARTIFACTS/rendered-extras.yaml" \
    "$ARTIFACTS/rendered-nokeep.yaml" \
    "$ARTIFACTS/rendered-live.yaml"
  do
    echo "-- $(basename "$manifest")"
    kubeconform -strict -summary \
      -kubernetes-version "${OD_TEST_KUBE_VERSION:-1.34.5}" \
      "$manifest"
  done
else
  echo "kubeconform: SKIP (not installed) — schema validation NOT performed"
fi

echo "== server-side dry-run (read-only) =="
# `apply --dry-run=server` asks the API server to admit-and-discard. It never
# persists anything, and it is the only check that catches a manifest the
# server refuses. An unreachable cluster is a SKIP; a reachable cluster that
# refuses an object is a FAILURE. Never confuse the two.
context_args=()
[[ -n "${OD_TEST_KUBE_CONTEXT:-}" ]] && context_args=(--context "$OD_TEST_KUBE_CONTEXT")
if ! command -v kubectl >/dev/null 2>&1; then
  echo "server dry-run: SKIP (kubectl not installed) — API-server admission NOT verified"
elif ! kubectl "${context_args[@]}" get --raw /version >/dev/null 2>"$ARTIFACTS/kube-probe.err"; then
  echo "server dry-run: SKIP (no reachable cluster) — API-server admission NOT verified"
  echo "  reason: $(head -1 "$ARTIFACTS/kube-probe.err" 2>/dev/null)"
  echo "  to run it: KUBECONFIG=<file> OD_TEST_KUBE_CONTEXT=woow-k3s bash tests/chart.test.sh"
elif kubectl "${context_args[@]}" -n "$namespace" apply --dry-run=server -f "$rendered"; then
  echo "server dry-run: the API server admits every object"
else
  echo 'FAIL: the API server rejected a rendered object. This is exactly the' >&2
  echo '      failure mode that shipped at HEAD 6f742b3 (a literal' >&2
  echo '      __K3S_NODE_HOSTNAME__ nodeSelector).' >&2
  exit 1
fi

echo "== rendered manifest assertions =="
python3 tests/chart-manifest.test.py

# ------------------------------------------------------------------ packaging
# A chart file that git ignores renders fine for its author and is MISSING from
# every clone. That is not hypothetical: the unanchored `secrets.yaml` pattern
# this repo used to carry would have swallowed `chart/templates/secrets.yaml`
# whole. Both halves are checked: nothing under chart/ is ignored, and nothing
# under chart/ is untracked.
echo "== chart files are all tracked by git =="
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ignored=$(cd "$REPO_ROOT" && git ls-files --others --ignored --exclude-standard -- chart/ || true)
  if [[ -n $ignored ]]; then
    echo 'FAIL: .gitignore matches file(s) under chart/. A clone of this repo would' >&2
    echo '      be missing them and the chart would render differently or not at all:' >&2
    echo "$ignored" | sed 's/^/        /' >&2
    exit 1
  fi
  untracked=$(cd "$REPO_ROOT" && git ls-files --others --exclude-standard -- chart/ || true)
  if [[ -n $untracked ]]; then
    echo 'FAIL: untracked file(s) under chart/ — commit them or delete them:' >&2
    echo "$untracked" | sed 's/^/        /' >&2
    exit 1
  fi
  echo "git: every file under chart/ is tracked and none is ignored"
else
  echo "git: SKIP (not a git checkout) — the .gitignore trap was NOT checked"
fi

echo "== helm package ships every template =="
package_dir="$ARTIFACTS/package"
rm -rf "$package_dir"
mkdir -p "$package_dir"
helm package "$CHART_DIR" --destination "$package_dir" >/dev/null
tarball=$(ls "$package_dir"/*.tgz)
tar -tzf "$tarball" | sed 's#^[^/]*/##' | sort >"$ARTIFACTS/package-contents.txt"
missing=0
while read -r relative; do
  if ! grep -Fxq "$relative" "$ARTIFACTS/package-contents.txt"; then
    echo "FAIL: $relative is in the chart but NOT in the packaged tarball." >&2
    echo "      Check chart/.helmignore — it excludes tests/, ci/, docs/ and *.md," >&2
    echo "      so a template in a directory called tests/ would vanish on publish." >&2
    missing=1
  fi
done < <(cd "$CHART_DIR" && find templates files -type f | sort)
[[ $missing -eq 0 ]] || exit 1
echo "helm package: $(wc -l <"$ARTIFACTS/package-contents.txt") file(s), every template and files/ asset present"

echo "chart lane: passed"
