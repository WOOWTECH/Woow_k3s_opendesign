# Woow k3s OpenDesign

OpenDesign **0.21.1** on the `woow-k3s` cluster: a container image and a Helm
chart that install into the **existing** `pi-agent-woow` namespace and are
published behind the cluster's Nginx Proxy Manager, exactly like the five
`pi-agent` releases.

[繁體中文](README_zh-TW.md) · [Operations reference](DOCS.md) · [Changelog](CHANGELOG.md) · [1.x migration and secret rotation](docs/MIGRATION.md)

> **2.0.0 is a rewrite, not an upgrade.** The 1.0.0 chart in this repository
> could not be installed at all (`helm install` was rejected by the API server
> because `nodeSelector` carried a literal `__K3S_NODE_HOSTNAME__`
> placeholder), pointed at `localhost/*` images with `pullPolicy: Never`, and
> committed real credentials to `values.yaml`. The console and MCP components
> are gone. Read [docs/MIGRATION.md](docs/MIGRATION.md) before touching an
> existing install — **credentials that were in the 1.x `values.yaml` are in
> public git history and must be rotated.**

## What this deploys

One pod, two containers, in namespace `pi-agent-woow`:

| Object | Name | Purpose |
|---|---|---|
| Deployment | `<release>` | `opendesign` container (OD daemon, loopback) + `nginx` sidecar (pod-network listener) |
| Service | `<release>` | ClusterIP `:7457`. The only thing NPM forwards to. Not configurable to NodePort/LoadBalancer. |
| ConfigMap | `<release>-config` | OD environment. No secret values. |
| ConfigMap | `<release>-nginx` | Sidecar `nginx.conf` + `od-export-bridge.js`. Checksum-annotated so an edit rolls the pod. |
| PersistentVolumeClaim | `<release>-data` | 20Gi `longhorn` (Retain), `helm.sh/resource-policy: keep`. Mounted at `/data/opendesign`. |
| PersistentVolumeClaim | `<release>-backup` | 20Gi `longhorn`, only when `backup.enabled` (default true). |
| NetworkPolicy | `<release>` | Ingress: `app=npm` pods and `192.168.0.0/16`, port 7457 only. Egress: kube-dns, then internet minus pod/service/LAN/metadata CIDRs. |
| CronJob | `<release>-backup` | Nightly `tar czf` of the data PVC onto the backup PVC, pruned to `backup.retain`. |

There is **no** Namespace, **no** Secret, **no** ServiceAccount, **no** Role or
RoleBinding, and no `nodeSelector`.

## Architecture

```text
browser
  └─ Cloudflare  ──► deployment/pi-tunnel-cloudflared  (ns pi-agent-woow)
                       └─ http://npm.pi-agent-woow.svc.cluster.local:80
                            └─ NPM proxy host  ◄── THE AUTH BOUNDARY (Access List / basic auth)
                                 └─ service/<release>:7457
                                      └─ nginx sidecar :7457   (no auth, no path rewriting)
                                           └─ 127.0.0.1:7456   OD daemon
                                                ├─ /data/opendesign        (Longhorn RWO)
                                                └─ system Chromium + playwright-core 1.55.0
```

The OD daemon binds `127.0.0.1` and is **not reachable over the pod network at
all**. That is deliberate: OD refuses to start on a non-loopback bind without
either an API token or `OD_DISABLE_API_AUTH=1`, and the 1.x chart chose the
latter. Keeping the loopback bind means the safety floor is honoured rather
than disabled, and no NetworkPolicy rule can even name port 7456.

The nginx sidecar exists only to terminate the pod-network connection and
normalise `Host` to the loopback form OD accepts. It does **not** authenticate,
does **not** rewrite paths, and does **not** blank `Origin`. Its one content
change is injecting `<script src="/od-export-bridge.js">` into `<head>`, which
redirects the UI's PDF button from the desktop-only `/export/pdf` route to the
binary `/export/pdf-image` route.

## Prerequisites

All verified on `woow-k3s` on 2026-09-09 unless marked otherwise.

| Requirement | Status |
|---|---|
| Kubernetes ≥ 1.24 | Server is `v1.34.5+k3s1` |
| Namespace `pi-agent-woow` exists (Rancher-managed; the chart does not create it) | Present |
| `longhorn` StorageClass, `Retain`, expandable | Present (`driver.longhorn.io`, RECLAIMPOLICY `Retain`, ALLOWVOLUMEEXPANSION `true`) |
| `service/npm` in `pi-agent-woow`, ports 80/81 | Present, ClusterIP `10.43.65.207` |
| `deployment/pi-tunnel-cloudflared` fronting NPM | Present |
| All nodes `amd64` (the image is amd64-only) | 4/4 nodes report `amd64` |
| Helm ≥ 3.8 (OCI support) | Client-side |
| A public hostname + Cloudflare DNS/tunnel route for OpenDesign | **NOT created.** You must pick and create it — see below |
| `ghcr.io/woowtech/woow-k3s-opendesign` published and public | Published as `2.0.1` and anonymously pullable, as `woow-k3s-pi-agent` is. The OCI chart is `oci://ghcr.io/woowtech/charts/opendesign:2.0.1` |

> There are **two** StorageClasses annotated as default (`local-path` and
> `longhorn`). A PVC that omits `storageClassName` gets an ambiguous tiebreak,
> so every PVC in this chart names its class explicitly and `tests/validate.py`
> fails the build if one does not.

## Install

The chart lives in `chart/`. It installs into an existing namespace and holds
no secrets.

```bash
# 1. Your values. publicUrl is REQUIRED: the chart ships an example.com origin
#    so its own defaults render, and that origin matches no real browser, so
#    leaving it in place breaks the UI loudly instead of trusting everything.
cat > od-values.yaml <<'YAML'
publicUrl: "https://od-woow-k3s.woowtech.io"   # the hostname you created in Cloudflare + NPM
image:
  digest: "sha256:..."                          # from the release job summary; recommended
YAML

# 2. From a clone
helm -n pi-agent-woow install od ./chart -f od-values.yaml

# 3. Or straight from GHCR, no checkout needed
helm -n pi-agent-woow install od \
  oci://ghcr.io/woowtech/charts/opendesign --version 2.0.1 -f od-values.yaml

# 4. Or from a GitHub source tarball, for an air-gapped review step
curl -fsSL https://github.com/WOOWTECH/Woow_k3s_opendesign/archive/refs/tags/v2.0.1.tar.gz \
  | tar -xz
helm -n pi-agent-woow install od ./Woow_k3s_opendesign-2.0.1/chart -f od-values.yaml
```

The version in 3 and 4 must be one that exists in GHCR. `image.tag` defaults to
the chart version, so a chart revision that has not been tagged and published
yet has no matching image: pin `image.digest` (or `image.tag`) in that case.

Always render before you install:

```bash
helm -n pi-agent-woow template od ./chart -f od-values.yaml | \
  kubectl --context woow-k3s -n pi-agent-woow apply --dry-run=server -f -
```

`--dry-run=server` is what would have caught the 1.x placeholder failure. Use
it; never `apply` the rendered output directly — the chart is the only writer.

### Verify

```bash
kubectl -n pi-agent-woow rollout status deploy/od
helm -n pi-agent-woow test od          # read-only: two GETs through the Service
```

`helm test` runs one short-lived pod that GETs `/api/health` and `/api/version`
through the Service, which is the same path NPM takes, so a pass proves
Service → sidecar `:7457` → `127.0.0.1:7456` → daemon end to end. It mounts no
volume and writes nothing. The hook pod deliberately does **not** carry the
chart's selector labels: a pod that did would join the Service's EndpointSlice
and black-hole a share of real requests while it ran.

With `networkPolicy.enabled: true` the hook also needs
`networkPolicy.allowHelmTest: true`, which adds exactly one ingress peer (the
hook pod, this release) on port 7457 and changes no pod template.

Each GET is retried (`helmTest.retries`, 15 attempts two seconds apart). That is
not padding: the hook pod is created seconds before it runs and the
NetworkPolicy admitting it is enforced from an ipset keyed on its IP, which the
policy controller has to learn first — connect before it has, and the packet is
rejected and looks exactly like a broken Service. Back-to-back `helm test` runs
failed that way about half the time with a single attempt.

The hook pod is left behind after the run (`helm.sh/hook-delete-policy:
before-hook-creation`), so `kubectl -n pi-agent-woow logs od-test-connection`
still shows what it saw; the next `helm test` replaces it.

**Uninstalling does not delete your data.** With `keepOnUninstall: true` (the
default) both PVCs — and the extra-env Secret, when the chart creates it — carry
`helm.sh/resource-policy: keep`, and they sit on a `Retain` StorageClass.

## Publishing it (operator steps, outside the chart)

The chart deliberately owns nothing outside `pi-agent-woow`. Two steps are
yours:

1. **cloudflared.** Add the OpenDesign hostname to the `pi-tunnel` Helm
   release's ingress list, pointing at
   `http://npm.pi-agent-woow.svc.cluster.local:80`, and
   `helm upgrade pi-tunnel`.
   **Never `kubectl patch` the `pi-tunnel-cloudflared` ConfigMap.** That
   ConfigMap has previously carried hand-appended hostnames that Helm did not
   know about; the next `helm upgrade` would have 404'd them. Its own comments
   record the incident.
2. **NPM** (`https://pi-agent-npm.woowtech.io`, i.e. `npm:81`) → *Hosts →
   Proxy Hosts → Add*:
   - Domain Names: your OpenDesign hostname
   - Scheme `http`, Forward Hostname `<release>.pi-agent-woow.svc.cluster.local`,
     Forward Port `7457`
   - **Websockets Support: ON** (OD streams), Block Common Exploits: ON
   - **Access List: the same basic-auth list the `pi-agent` hosts use** — this
     is the auth boundary
   - SSL: request/attach a certificate as the sibling hosts do

Nothing in the `npm` Deployment, Service or NetworkPolicy changes. The `npm`
policy already allows cloudflared and `192.168.0.0/16` in, and npm has no
egress policy, so it can reach the new Service with no edit.

## Configuring values

Full reference: `chart/values.yaml` (commented) and `chart/values.schema.json`
(enforced by `helm lint`). The keys you will actually touch:

| Key | Default | Notes |
|---|---|---|
| `publicUrl` | `https://opendesign.example.com` | **Set it.** Drives `OD_ALLOWED_ORIGINS` and `OD_PUBLIC_BASE_URL`. The default is an example origin so the shipped values render, lint and kubeconform; it matches no real browser origin, so it fails closed and `NOTES.txt` warns while it is still in effect. An **empty** string, or anything that is not an `https://` origin with no path, is a hard render failure. |
| `keepOnUninstall` | `true` | Adds `helm.sh/resource-policy: keep` to both PVCs and to a chart-created extra-env Secret. `false` only for a throwaway release you want `helm uninstall` to erase. |
| `image.digest` | `""` | `sha256:...`. When set it wins over `image.tag`. Set it in production. |
| `image.tag` | chart version | A moving tag is rejected by the schema and by `tests/validate.py`. |
| `nginx.requireOriginOnMutation` | `true` | Sidecar returns 403 for POST/PUT/PATCH/DELETE with no `Origin`. Correct for browsers; will break a non-browser API client. |
| `persistence.data.size` | `20Gi` | `longhorn` is expandable in place. |
| `backup.enabled` / `.schedule` / `.retain` | `true` / `17 3 * * *` / `7` | |
| `opendesign.extraEnv` | `{}` | Reviewed additions only. Chart-owned vars are rejected here. **Rendered into the `-config` ConfigMap in cleartext — never a credential.** |
| `opendesign.rejectSecretShapedExtraEnv` | `false` | `true` makes any `*_API_KEY` / `*_TOKEN` / `*_SECRET` / `*_PASSWORD` in `extraEnv` a render failure. Ships `false` only because the live release still passes one such key that way; see [docs/MIGRATION.md](docs/MIGRATION.md). |
| `opendesign.extraEnvSecret.enabled` | `false` | `true` adds `envFrom.secretRef` to the OpenDesign container, so a key never touches a ConfigMap. Changes the pod template, therefore rolls the pod once. |
| `opendesign.extraEnvSecret.create` | `false` | `false` = the Secret already exists and this chart only names it (the recommended shape). `true` renders it from `.data`, with `required()` on every value. Shapes and both modes: [examples/secrets.example.yaml](examples/secrets.example.yaml). |
| `networkPolicy.allowHelmTest` | `false` | `true` adds one ingress peer for the `helm test` hook pod. Needed for `helm test` whenever the NetworkPolicy is on. |
| `helmTest.enabled` | `true` | Ships the read-only `helm test` hook. |

There is still no `secrets:` block and no `service.type`. A Secret is only ever
referenced, or created behind an explicit opt-in; see [Security](#security).

Instance values for what is actually running are committed, without secrets, at
[`deploy/woow-k3s/opendesign.yaml`](deploy/woow-k3s/opendesign.yaml).

## Exports

| Format | Support |
|---|---|
| Standalone HTML | Supported by OpenDesign |
| Project ZIP | Supported by OpenDesign |
| PNG / JPEG | Supported |
| Screenshot PDF | Supported; the UI's PDF action is bridged to the binary `/export/pdf-image` route by `od-export-bridge.js` |
| Screenshot PPTX | Supported; one full-slide image per PowerPoint slide |
| Editable PPTX | **Unsupported.** The renderer returns an explicit error. |

The bridge is required, not cosmetic: OD 0.21.1's
`PROJECT_RUN_SCOPED_EXPORT_PATH_RE` does not include `/export/pdf` — that route
is the Electron/desktop path, and this deployment injects
`desktopArtifactExporter: null`. Without the bridge the PDF button downloads
nothing.

Rendering is the Playwright renderer ported unchanged from the Home Assistant
add-on: serialized (`Semaphore(1)`), bounded by a 120s absolute deadline, 64
slides, 48M pixels, 128MiB output, 32MiB HTML, 4 remote fetches / 64MiB
remote bytes, with canonical output-path confinement, WebSockets blocked, and
an IPv4/IPv6 request policy that rejects RFC1918, CGNAT, link-local, loopback
and the metadata address. CJK and emoji fonts are in the image so capture does
not depend on a font CDN.

## Backup and restore

Longhorn on this cluster has **no working backup target**
(`backuptargets/default` reports `available: false`, and there are zero
`recurringjobs`), so the chart ships its own CronJob rather than pretending
Longhorn covers it.

Nightly at 03:17 Asia/Taipei, `<release>-backup` runs the OD image with a
`/bin/sh` override, mounts the data PVC read-only and the backup PVC
read-write, and writes
`/backup/opendesign-<UTC timestamp>.tar.gz`, keeping the newest
`backup.retain` archives. It carries a **required** podAffinity on
`app=opendesign` / `kubernetes.io/hostname`, because a Longhorn RWO volume
attaches to one node and the Job would otherwise hang on attach. Do not
weaken that to `preferred`.

Restore:

```bash
kubectl -n pi-agent-woow scale deploy/od --replicas=0
# attach a maintenance pod with both PVCs, then:
#   tar xzf /backup/opendesign-<stamp>.tar.gz -C /data
kubectl -n pi-agent-woow scale deploy/od --replicas=1
```

This is a copy **inside the same Longhorn cluster**. It survives a bad
`helm uninstall` or an accidental PVC delete. It does **not** survive cluster
loss. Off-site durability needs either a cluster-wide Longhorn backup target
or an upload step added to the CronJob — neither is in this chart.

## Upgrade

```bash
helm -n pi-agent-woow upgrade od ./chart -f od-values.yaml
```

The Deployment uses `strategy: Recreate` because the data volume is Longhorn
RWO and cannot be attached to two pods on different nodes at once. Expect a
short outage on every rollout; that is the correct mechanism, not node pinning.

Pin `image.digest` to the digest the release job printed. Editing the nginx
ConfigMap rolls the pod on its own via the `checksum/nginx` pod annotation.

## Uninstall

```bash
helm -n pi-agent-woow uninstall od
```

The namespace stays (it is Rancher-managed and shared: this chart never renders
a Namespace, so it can never delete one). Both PVCs stay, because
`keepOnUninstall: true` annotates them `helm.sh/resource-policy: keep` — as it
does a chart-created extra-env Secret. To really delete the data:

```bash
kubectl -n pi-agent-woow delete pvc od-data od-backup   # irreversible-ish
```

Even then the PVs are `Retain`, so the volumes survive as `Released` for
manual recovery until someone deletes them in Longhorn.

## Security

**The auth boundary is the NPM Access List, and nothing else.** State that
plainly, because the 1.x chart got it backwards.

- OpenDesign has **no application-level authentication**. It never has. Anyone
  who reaches `service/<release>:7457` reaches the full UI and API.
- Therefore the Service is ClusterIP-only and `service.type` is not a values
  key. There is no NodePort and no LoadBalancer, because either would route
  around NPM.
- The NetworkPolicy admits exactly two ingress peers on port 7457: pods
  labelled `app=npm`, and `192.168.0.0/16` for LAN admin/debug — the same
  shape the five `pi-agent` releases use. Everything else is denied.
- The daemon is loopback-bound, so even a NetworkPolicy mistake does not expose
  port 7456.
- `OD_API_TOKEN` and `OD_DISABLE_API_AUTH` appear **nowhere** in this
  repository, and `tests/validate.py` fails the build if either string
  reappears in a chart file. The 1.x chart set `OD_BIND_HOST: "0.0.0.0"` and
  `OD_DISABLE_API_AUTH: "1"` with the comment "Auth handled by Cloudflare
  Tunnel". That is the inversion this rewrite removes.
- `OD_ALLOWED_ORIGINS` is set to the single public origin. A cross-site request
  carrying a different `Origin` is rejected by OD. A mutating request carrying
  **no** `Origin` is rejected by the sidecar (`nginx.requireOriginOnMutation`).
- The chart creates **no ServiceAccount**, and sets
  `automountServiceAccountToken: false`. It creates no Secret either unless you
  explicitly ask it to with `opendesign.extraEnvSecret.create: true`; the
  default is to reference a Secret that already exists, so no credential passes
  through Helm at all.
- `opendesign.extraEnv` is rendered into the `-config` **ConfigMap in
  cleartext**. That is fine for `OD_ALLOWED_INTERNAL_HOSTS` and wrong for a
  key: anything with `get configmaps` in the namespace can read it, and
  `helm get values` echoes it back. Server-side credentials belong in
  `opendesign.extraEnvSecret`, and `rejectSecretShapedExtraEnv: true` turns that
  from advice into a render failure. The 1.x console had a ServiceAccount
  with `pods/exec` and `secrets: get,patch,update` behind one shared ttyd
  password; it is deleted, not fixed.
- **BYOK:** provider, model and API keys are entered in the browser and stay in
  that browser's local storage. No provider key enters the chart, a ConfigMap,
  a Secret, an env var, or `/data`. The release gate proves the key does not
  reach container logs or `/data`.
- The nginx sidecar runs as UID/GID 101, read-only root filesystem, all
  capabilities dropped, temp paths under an `emptyDir` at `/tmp`. The OD
  container runs PID 1 as root only long enough to chown the root-owned
  Longhorn mount, dropping to UID 1001 via `su-exec`, with capabilities
  narrowed to `CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID`.

Rotation notice: the 1.x `values.yaml` committed a real 64-hex MCP JWT key, an
MCP admin password and a ttyd password. They are in this repository's **public**
git history — the commit is still reachable through unmerged branches and
through GitHub's own `refs/pull/N/head`, so deleting a branch does not remove
it. All three must be treated as disclosed. See
[docs/MIGRATION.md](docs/MIGRATION.md).

## Versioning and releases

The chart version and the image tag are **one number**. `chart/Chart.yaml`
`version: 2.0.1` is the source of truth; `appVersion` is the OpenDesign version
(`0.21.1`). The Git tag is `v<chart version>`.

`helm.sh/chart` is a pod template label, so bumping the chart version and
upgrading a live release rolls the pod once. That is why a change that must not
restart anything — adopting a new revision of this chart on the running
`opendesign` release, for instance — keeps the version where it is and defers
the bump to the release that is allowed to restart it.

`latest` is forbidden in `Chart.yaml`, `values.yaml`, the `Dockerfile`, the
workflows and the docs, and `tests/validate.py` enforces it.

A `v*` tag runs, in order: validate → smoke → release preflight → release
architecture gate → publish. The preflight fails closed unless **both**
`ghcr.io/woowtech/woow-k3s-opendesign:<version>` and
`ghcr.io/woowtech/charts/opendesign:<version>` are provably absent from GHCR.
Published versions are immutable: recovering a partial release means bumping
`chart/Chart.yaml` and cutting a new tag, never overwriting. Details in
[docs/CI.md](docs/CI.md).

## Development and validation

```bash
./tests/run.sh
```

That is the gate. It runs the metadata/secret validator, the workflow policy
check, `helm lint` + `helm template` + `kubeconform` over the rendered chart,
the Node unit tests, and shell/nginx syntax checks. It needs Node, Python 3
with PyYAML, `helm`, `kubeconform` and `yq`; it does not need Docker or a
cluster. When a kubeconfig is present it additionally runs
`kubectl apply --dry-run=server` over the render — read-only, and the check
that would have caught the 1.x install failure.

`tests/container-smoke.sh` needs a container runtime and builds a real
two-container pod (OD + nginx sidecar) to exercise health, the loopback bind,
per-pixel PNG assertions, `pdfinfo` page counts, PPTX slide counts, the export
bridge, and the Origin allow/deny paths.

## Upstream and license

The runtime derives from `ghcr.io/nexu-io/od:0.21.1`, pinned by digest in
`Dockerfile:1` and re-asserted by `tests/validate.py`. OpenDesign has its own
upstream licensing and notices. The packaging, chart and integration code in
this repository is MIT licensed; see [LICENSE](LICENSE).
