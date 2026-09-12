#!/usr/bin/env bash
# Prove that this chart, rendered with the recorded instance values, produces
# EXACTLY the objects the live release already has -- i.e. that adopting this
# revision of the chart would roll nothing.
#
# Read-only. It runs `helm template`, `helm get manifest` and `kubectl get`;
# there is no apply, no upgrade and no write of any kind.
#
# The live release carries one value that is deliberately not in the committed
# instance values (see deploy/woow-k3s/opendesign.yaml). This script reads it
# out of the cluster into a temporary file with mode 600, passes it to
# `helm template`, and deletes it on exit. It never prints it.
#
#   usage: deploy/woow-k3s/verify-live-render.sh [context] [namespace] [release]
set -Eeuo pipefail

context=${1:-woow-k3s}
namespace=${2:-pi-agent-woow}
release=${3:-opendesign}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
values="$root/deploy/woow-k3s/$release.yaml"

for tool in helm kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done
[[ -f $values ]] || { echo "no instance values at $values" >&2; exit 2; }

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# The one live value that is not committed, straight from the ConfigMap into a
# values file that never leaves this directory.
key=$(kubectl --context "$context" -n "$namespace" get configmap "$release-config" \
  -o go-template='{{ if index .data "OPENROUTER_API_KEY" }}1{{ end }}')
if [[ $key == 1 ]]; then
  umask 077
  {
    printf 'opendesign:\n  extraEnv:\n    OPENROUTER_API_KEY: '
    kubectl --context "$context" -n "$namespace" get configmap "$release-config" \
      -o go-template='{{ index .data "OPENROUTER_API_KEY" }}' | sed -e 's/^/"/' -e 's/$/"/'
    printf '\n'
  } >"$work/live-extra-env.yaml"
  extra=(-f "$work/live-extra-env.yaml")
  echo "note: the live cleartext OPENROUTER_API_KEY was read from ConfigMap $release-config (never printed)"
else
  extra=()
fi

helm --kube-context "$context" -n "$namespace" get manifest "$release" >"$work/live.yaml"
helm template "$release" "$root/chart" -n "$namespace" -f "$values" "${extra[@]}" --no-hooks >"$work/rendered.yaml"

python3 - "$work/live.yaml" "$work/rendered.yaml" <<'PY'
import re, sys
def norm(path):
    text = open(path, encoding="utf-8").read()
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    return re.sub(r"\n{2,}", "\n", text).strip() + "\n"
live, rendered = norm(sys.argv[1]), norm(sys.argv[2])
if live == rendered:
    print("helm get manifest == helm template (whitespace-normalised): the chart would roll nothing")
    raise SystemExit(0)
import difflib
sys.stdout.writelines(difflib.unified_diff(
    live.splitlines(keepends=True), rendered.splitlines(keepends=True),
    fromfile="live (helm get manifest)", tofile="rendered (helm template)"))
print("\nRENDER DIFFERS FROM LIVE", file=sys.stderr)
raise SystemExit(1)
PY

echo "field-by-field against the live API objects:"
python3 - "$context" "$namespace" "$work/rendered.yaml" <<'PY'
import json, re, subprocess, sys
import yaml
context, namespace, rendered_path = sys.argv[1:4]
KIND_ARG = {
    "Deployment": "deployment", "Service": "service", "ConfigMap": "configmap",
    "PersistentVolumeClaim": "pvc", "CronJob": "cronjob", "NetworkPolicy": "netpol",
    "Secret": "secret",
}
SECRETISH = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD)$", re.I)
diffs = []
def walk(path, rendered, live):
    if isinstance(rendered, dict):
        if not isinstance(live, dict):
            diffs.append((path, "type mismatch")); return
        for key, value in rendered.items():
            if key not in live:
                diffs.append((f"{path}/{key}", "missing in live")); continue
            walk(f"{path}/{key}", value, live[key])
    elif isinstance(rendered, list):
        if not isinstance(live, list) or len(rendered) != len(live):
            diffs.append((path, "list length differs")); return
        for index, (a, b) in enumerate(zip(rendered, live)):
            walk(f"{path}[{index}]", a, b)
    elif rendered != live:
        leaf = path.rsplit("/", 1)[-1]
        diffs.append((path, "value differs (redacted)" if SECRETISH.search(leaf) else f"{rendered!r} != {live!r}"))
count = 0
for doc in yaml.safe_load_all(open(rendered_path, encoding="utf-8")):
    if not doc:
        continue
    kind, name = doc["kind"], doc["metadata"]["name"]
    out = subprocess.run(
        ["kubectl", "--context", context, "-n", namespace, "get", f"{KIND_ARG[kind]}/{name}", "-o", "json"],
        capture_output=True, text=True)
    if out.returncode != 0:
        diffs.append((f"{kind}/{name}", "no such live object")); continue
    walk(f"{kind}/{name}", doc, json.loads(out.stdout))
    count += 1
for path, message in diffs:
    print("DIFF", path, "|", message)
print(f"{count} live object(s) compared, {len(diffs)} difference(s)")
raise SystemExit(1 if diffs else 0)
PY
