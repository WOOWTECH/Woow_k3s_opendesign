# Migration, takeover and secret rotation

Three separate jobs are described here. Read the one you are actually doing.

1. [1.x → 2.x](#1x--2x-there-is-no-upgrade-path) — there is no upgrade path.
2. [Rotating the credentials 1.x committed](#rotate-the-credentials-1x-committed) —
   they are in this repository's **public** git history.
3. [Adopting a newer chart revision on the live release](#adopt-a-newer-chart-revision-without-restarting-anything) —
   how to prove an upgrade rolls nothing before you run it.

---

## 1.x → 2.x: there is no upgrade path

The 1.0.0 chart could not be installed at all: `helm install` was rejected by
the API server because `nodeSelector` carried a literal `__K3S_NODE_HOSTNAME__`,
it pointed at `localhost/*` images with `pullPolicy: Never`, and it committed
real credentials to `values.yaml`. The object names, the volume layout, the
container topology and the security posture all changed in 2.0.0. The console
(ttyd/Flask) and the `od-mcp` sidecar were deleted rather than ported.

Install 2.x as a **new release**. If a 1.x release somehow exists:

```bash
# What it owns, before you touch anything.
helm -n pi-agent-woow get manifest <old-release> > /tmp/old-manifest.yaml

# Copy any data out FIRST. 1.x used two PVCs (data + home); 2.x folds HOME into
# $OD_DATA_DIR/home on one volume, so this is a copy, not a rename.
kubectl -n pi-agent-woow scale deploy/<old-release> --replicas=0
# ... attach a maintenance pod to the old PVCs and tar the contents out ...

helm -n pi-agent-woow uninstall <old-release>
helm -n pi-agent-woow install opendesign ./chart -f my-values.yaml
```

The 2.x PVCs carry `helm.sh/resource-policy: keep` (see `keepOnUninstall`) and
sit on the `Retain` `longhorn` StorageClass, so from 2.x onward an uninstall is
no longer a data-loss event.

---

## Rotate the credentials 1.x committed

The 1.x `chart/values.yaml` committed a real 64-hex MCP JWT signing key, an MCP
admin password and a ttyd password. **This repository is public.** Deleting the
files did not remove them: the commit that carried them is still reachable
through several unmerged branches and through GitHub's own pull-request refs
(`refs/pull/N/head`), which cannot be deleted by pushing.

Treat all three as disclosed:

| Credential | Where it was | What to do |
|---|---|---|
| MCP JWT signing key | 1.x `values.yaml` | Rotate. Nothing in 2.x consumes it — the MCP sidecar is deleted — so rotation means invalidating it wherever it is still trusted. |
| MCP admin password | 1.x `values.yaml` | Rotate, and check it was not reused elsewhere. It was a short, common default. |
| ttyd / console password | 1.x console ConfigMap and `console/entrypoint.py` default | Rotate. The console is deleted in 2.x. |

2.x ships no credential at all, and `tests/validate.py` fails the build if a
credential-shaped assignment, a 64-hex literal or an unanchored `.gitignore`
pattern reappears.

---

## Adopt a newer chart revision without restarting anything

The live release `opendesign` in `pi-agent-woow` is already Helm-managed by this
chart. Adopting a newer revision of the chart must be provably inert: if the
rendered objects differ from the live ones in the pod template, `helm upgrade`
rolls the pod, and with a Longhorn RWO volume and `strategy: Recreate` that is a
real (if short) outage.

The instance values are committed, without secrets, at
`deploy/woow-k3s/opendesign.yaml`. Prove the render matches before you upgrade:

```bash
./deploy/woow-k3s/verify-live-render.sh            # woow-k3s / pi-agent-woow / opendesign
```

It does three read-only things: diffs `helm template` (with the instance values)
against `helm get manifest`, compares every rendered field against the live API
objects, and prints what differs. It never applies anything.

Two things that WILL change the pod template, and therefore roll the pod once
each — do them deliberately, never as a side effect:

* bumping `chart/Chart.yaml` `version`, because `helm.sh/chart` is a pod
  template label;
* setting `opendesign.extraEnvSecret.enabled: true`, because it adds an
  `envFrom` entry.

### Moving OPENROUTER_API_KEY out of the ConfigMap

The live release passes a server-side OpenRouter key through
`opendesign.extraEnv`, which the chart renders into ConfigMap
`opendesign-config` **in cleartext**. Anything with `get configmaps` in
`pi-agent-woow` can read it, and `helm get values` echoes it back. The key is
therefore not recorded in the committed instance values.

The migration, once, in this order:

```bash
# 1. Copy the live value into a Secret. Read it out of the cluster; never echo
#    it, never put it in a file that git can see.
kubectl --context woow-k3s -n pi-agent-woow create secret generic opendesign-extra-env \
  --from-literal=OPENROUTER_API_KEY="$(
    kubectl --context woow-k3s -n pi-agent-woow get configmap opendesign-config \
      -o go-template='{{ index .data "OPENROUTER_API_KEY" }}')"

# 2. In deploy/woow-k3s/opendesign.yaml: delete nothing (the key was never
#    there), and add
#
#      opendesign:
#        rejectSecretShapedExtraEnv: true
#        extraEnvSecret:
#          enabled: true
#          create: false
#          name: opendesign-extra-env
#
# 3. Upgrade WITHOUT the --set-string that used to carry the key. This rolls the
#    pod once: the ConfigMap loses the key and the pod gains the envFrom.
helm -n pi-agent-woow --kube-context woow-k3s upgrade opendesign ./chart \
  -f deploy/woow-k3s/opendesign.yaml

# 4. Confirm the cleartext copy is gone, then rotate the key: it lived in a
#    ConfigMap, so treat it as disclosed.
kubectl --context woow-k3s -n pi-agent-woow get configmap opendesign-config \
  -o go-template='{{ range $k, $_ := .data }}{{ $k }}{{ "\n" }}{{ end }}'
```

`rejectSecretShapedExtraEnv: true` is what stops the key drifting back: from
then on any `*_API_KEY`, `*_TOKEN`, `*_SECRET` or `*_PASSWORD` in `extraEnv` is
a render failure, not a quiet ConfigMap entry.

`examples/secrets.example.yaml` documents both modes (reference an existing
Secret, which is the default, or let the chart render one).

> **BYOK is unaffected.** Provider keys typed into the OpenDesign UI stay in
> that browser's local storage. They never reach a ConfigMap, a Secret, an env
> var or `/data`, and the release gate proves it.
