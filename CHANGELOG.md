# Changelog

Versions here are chart versions. The chart version and the published image tag
are the same number; `appVersion` is the OpenDesign version.

## Unreleased

Chart-only. **The chart version is deliberately NOT bumped**: `helm.sh/chart` is
one of the pod template labels, so bumping it and upgrading the live
`opendesign` release would roll the pod. Rendering this revision with
`deploy/woow-k3s/opendesign.yaml` produces objects identical to the live ones,
field for field, which is the whole point. The version bump and the `v*` tag
belong to the release that is allowed to restart something.

- **The shipped default values render.** `helm template ./chart` with no `-f` at
  all used to fail with `publicUrl is required`, which meant the chart's own
  defaults could not be linted by chart-testing, could not be validated by
  kubeconform on the default path, and told every reader to guess. `publicUrl`
  now ships as `https://opendesign.example.com`: an example origin that renders
  and validates, and that no browser can ever present — so leaving it in place
  fails CLOSED (OpenDesign rejects every cross-site request) instead of the
  fail-OPEN an empty `OD_ALLOWED_ORIGINS` would have been. `NOTES.txt` prints a
  loud warning while it is still in effect, and an empty or non-`https://` value
  is still a hard render failure.
- **Credentials can be kept out of the ConfigMap.** `opendesign.extraEnv` is
  rendered into `<release>-config` in cleartext, and the live release passes a
  server-side OpenRouter key that way. New, all opt-in and all off by default,
  so the live render does not move:
  - `opendesign.extraEnvSecret.enabled` adds `envFrom.secretRef` to the
    OpenDesign container;
  - `opendesign.extraEnvSecret.create` (default `false`) renders that Secret
    from values with `required()` on every entry, otherwise the chart only
    references a Secret that already exists;
  - `opendesign.rejectSecretShapedExtraEnv` turns a credential-shaped key in
    `extraEnv` into a render failure;
  - `examples/secrets.example.yaml` documents both modes with example values,
    and `docs/MIGRATION.md` has the one-time migration for the live key.
- **`keepOnUninstall` (default `true`)** now owns `helm.sh/resource-policy:
  keep` for both PVCs and for a chart-created Secret, instead of an annotation
  map per PVC that could be edited out one at a time. The chart still renders no
  Namespace. `tests/chart.test.sh` asserts both states of the switch.
- **A read-only `helm test` hook.** One short-lived pod GETs `/api/health` and
  `/api/version` through the Service — the same path NPM takes — mounting
  nothing and reusing the already-pinned image. It deliberately does not carry
  the chart's selector labels: a pod that did would join the Service
  EndpointSlice and black-hole a share of live requests while it ran.
  `networkPolicy.allowHelmTest` (default `false`) adds the single ingress peer
  the hook needs when the policy is on.
- **Instance values for the live release are committed** at
  `deploy/woow-k3s/opendesign.yaml`, without secrets, next to
  `deploy/woow-k3s/verify-live-render.sh` — a read-only script that diffs
  `helm template` against `helm get manifest` and then against the live API
  objects field by field, so "this upgrade rolls nothing" is a command rather
  than a claim.
- **`.gitignore` patterns are anchored.** An unanchored `secrets.yaml` matches at
  any depth: the day someone added `chart/templates/secrets.yaml`, git would
  have ignored it, `git add -A` would have skipped it, and every clone would
  have rendered a different chart. `tests/chart.test.sh` now fails if any file
  under `chart/` is ignored or untracked, and `tests/validate.py` fails if a
  pattern loses its leading `/`.
- **A mistyped values key is now a render failure.** `values.schema.json` sets
  `additionalProperties: false` at the top level (it already did inside
  `service`), so `imagePullSecret` for `imagePullSecrets` is rejected instead of
  silently ignored — the failure mode where a chart runs with a setting its
  author believes is in effect. `tests/validate.py` also asserts that every key
  `values.yaml` ships is declared in the schema.
- Two stale comments in `values.yaml`: the release job prints the published
  digest in its step summary and does **not** write it back, and the live
  release does set `imagePullSecrets` even though the package is public.
- CI/tests: `helm lint` + `helm template` + `kubeconform -strict` over every
  values combination the repo ships (defaults, minimal, full, every opt-in on,
  `keepOnUninstall: false`, and the live instance values), one negative fixture
  per render-time guard asserted by message, a `helm package` completeness check
  so `.helmignore` cannot silently drop a template, and `bash -n` + shellcheck
  over the new script.
- Docs: `docs/MIGRATION.md` and `docs/CI.md` now exist — the READMEs and this
  changelog had been linking to both since 2.0.0. The OCI install examples said
  `--version 2.0.0`, which was never published; they say `2.0.1`, which is.

## 2.0.1

Patch release. Chart and image contents are otherwise identical to 2.0.0.

- **Pages taller than the capture viewport can be exported to PDF again.** They
  could not be, at all: `capturePage` passed Playwright a `clip` without
  `fullPage`, so `clip` was measured against the viewport and every segment
  past the first (y >= 1000) fell outside the captured area. The export died
  with `Clipped area is either empty or outside the resulting image`.
  A short page plans one segment and worked; anything article- or
  report-shaped plans two or more and always failed. Bisected on the live
  deployments: 1000 px exported, 1010 px did not. Verified after the fix at
  1010 / 1200 / 1500 / 2000 / 3000 / 6000 px, each producing
  `ceil(height / 1000)` pages with per-page content confirmed distinct.
- Screenshot options for a page segment now come from an exported
  `planPageScreenshot()` so the contract has a unit test instead of living in
  an `if/else` inside an async capture loop.
- CI: the container smoke lane had never actually executed. It needed
  `tests/.artifacts/*`, which only `tests/run.sh` produces and which runs in a
  different job, and the image it looked for was in docker's store while the
  smoke script requires podman. Both are fixed, so the lane now runs for real.

## 2.0.0

Complete rewrite. The 1.0.0 chart described a hand-run topology that was never
deployed and **could not be installed**: `helm install` was rejected by the API
server because `nodeSelector` carried the literal placeholder
`__K3S_NODE_HOSTNAME__`, the images were `localhost/*` with
`pullPolicy: Never`, and `appVersion` was `latest`. 2.0.0 is aligned with the
`Woow_ha_opendesign_add_on` add-on and with the topology the `pi-agent` fleet
already runs in production.

### Breaking changes

- **The console is gone.** No ttyd, no Flask dashboard, no console Deployment,
  Service, ConfigMaps or RBAC, and the `console/` directory is deleted. It was
  a world-facing single-password root shell whose ServiceAccount held
  `pods/exec` and `secrets: get,patch,update`.
- **`od-mcp` is gone.** Deployment, Service, PVC and NetworkPolicy removed.
- **Committed credentials are purged from the chart and MUST be rotated.** The
  1.x `values.yaml` contained a real 64-hex MCP JWT signing key, an MCP admin
  password and a ttyd password, in a **public** repository. They are still in
  git history. They are burned: rotate them anywhere they were reused. See
  [docs/MIGRATION.md](docs/MIGRATION.md). The values are not reprinted.
- **The chart moved to `chart/`** and is installed into the **existing**
  `pi-agent-woow` namespace. `templates/namespace.yaml` is deleted; the chart
  no longer creates a namespace, and `open-design` is abandoned (it does not
  exist in the cluster).
- **Both `templates/secret.yaml` Secrets are deleted.** Nothing in 2.0.0 needs
  a secret. `OD_API_TOKEN`, `ANTHROPIC_API_KEY`, `TUI_PASSWORD`, `JWT_SECRET`
  and `ADMIN_PASSWORD` are removed from the chart surface entirely.
- **Security inversion reversed.** `OD_BIND_HOST: "0.0.0.0"` plus
  `OD_DISABLE_API_AUTH: "1"` ("Auth handled by Cloudflare Tunnel") are gone.
  The daemon binds `127.0.0.1`; neither variable appears anywhere in the
  repository, and the validator fails the build if either returns.
- **Images move to GHCR.** `localhost/open-design:latest` and
  `localhost/od-mcp:latest` with `pullPolicy: Never` are replaced by
  `ghcr.io/woowtech/woow-k3s-opendesign:<chart version>`, digest-pinnable,
  `pullPolicy: IfNotPresent`.
- **Storage changed class and shape.** One 20Gi `longhorn` PVC (reclaim
  `Retain`, `helm.sh/resource-policy: keep`) at `/data/opendesign` replaces two
  `local-path` PVCs; `HOME` now lives inside the data volume.
- **`service.type` is no longer configurable.** ClusterIP only. NodePort or
  LoadBalancer would route around the auth boundary.
- **No `nodeSelector`.** `__K3S_NODE_HOSTNAME__` and
  `mcp.nodeHostname: "woowtechcluster1-aorus-15p-xd"` are deleted. Longhorn is
  distributed; `strategy: Recreate` handles the RWO single-attach constraint.
- **`Dockerfile.open-design` is deleted.** It cloned a third-party repository's
  HEAD at build time and installed unpinned agent CLIs, producing an image that
  could not be reproduced.
- **`headless-renderer.py` is deleted.** It launched Chromium with
  `--disable-web-security`, and had no output-path confinement, no request
  policy, no WebSocket block, no concurrency limit, no deadline and none of the
  size budgets.
- **There is no `helm upgrade` path from 1.0.0.** The namespace, chart name and
  volume layout all change. Install 2.0.0 as a new release.

### Added

- Helm chart under `chart/` emitting exactly 8 objects (7 with
  `backup.enabled=false`): Deployment, Service, two ConfigMaps, two PVCs,
  NetworkPolicy, backup CronJob. No Namespace, Secret, ServiceAccount, Role or
  RoleBinding; `automountServiceAccountToken: false`.
- `values.schema.json`, enforced by `helm lint`: `publicUrl` must be a
  non-empty `https://` host, `image.tag` may not be `latest`, `image.digest`
  must be empty or `sha256:<64 hex>`, every PVC must name a StorageClass, and
  `service` accepts no `type` key.
- nginx sidecar (`nginx:1.27-alpine`, UID 101, read-only root filesystem, all
  capabilities dropped) on port 7457. It terminates the pod-network connection
  so the daemon can stay on loopback, normalises `Host`, passes `Origin`
  through unchanged, and serves plus injects `od-export-bridge.js`. It performs
  **no** authentication and **no** path rewriting.
- `OD_ALLOWED_ORIGINS` and `OD_PUBLIC_BASE_URL` derived from `publicUrl`, so
  cross-site rejection survives the reverse proxy, and a strict-CSRF guard in
  the sidecar that rejects mutating requests carrying no `Origin`.
- Single NetworkPolicy modelled byte-for-byte on the `pi-agent` fleet: ingress
  from `app=npm` pods and `192.168.0.0/16` on 7457 only; egress to kube-dns
  then everything except the pod, service, LAN and metadata CIDRs.
- Nightly backup CronJob writing a `tar.gz` of the data PVC onto a second
  20Gi `longhorn` PVC, pruned to `backup.retain`, with a **required**
  podAffinity on the OD pod's node (a Longhorn RWO volume attaches to one node;
  without it the Job hangs on attach). Longhorn's own backup target reports
  `available: false` on this cluster and there are no recurring jobs, so this
  is not delegated.
- Export pipeline ported from the HA add-on: the 868-line Playwright
  `headless-renderer.mjs` with all limits intact — 120s absolute deadline,
  `Semaphore(1)`, 64 slides, 48M pixels, 128MiB output, 32MiB HTML, 4 remote
  fetches, 64MiB remote bytes, canonical output-path confinement, WebSockets
  blocked, an IPv4/IPv6 request policy with pinned-address fulfilment, and an
  ephemeral HOME/XDG per Chromium launch — plus `headless-entry.mjs`,
  `playwright-core` 1.55.0 and Noto CJK/emoji fonts.
- `od-export-bridge.js`, served from the nginx ConfigMap, redirecting the UI's
  PDF action from the desktop-only `/export/pdf` route to the binary
  `/export/pdf-image` route. Its HA ingress-prefix install gate is replaced by
  an unconditional install guarded only by an idempotence flag.
- `opencode-ai@1.18.29` exact-pinned for OpenDesign's native `byok-opencode`
  runtime. Provider keys stay in the browser; the release gate proves the key
  reaches neither container logs nor `/data`.
- Six-job CI (`validate`, `smoke`, `build-nonrelease`, `release-preflight`,
  `release-architecture-gate`, `publish-release`) with every action pinned to a
  40-hex commit SHA, `contents: read` by default, `packages: write` in exactly
  one job, and a fail-closed GHCR preflight that refuses to publish over an
  existing image **or** chart version.
- Checksum-verified helm / kubeconform / yq installation in CI.
- The packaged chart is published as an OCI artifact to
  `oci://ghcr.io/woowtech/charts`, so `helm install` needs no git checkout.
- `.github/scripts/chart-version.sh`: one version source for the workflow and
  the preflight, rejecting `latest` and non-`MAJOR.MINOR.PATCH` values.
- Repo guard extended to block the removed components by path.
- `.gitignore` covering values overrides, kubeconfigs, `.env` files, key
  material and packaged chart `*.tgz` archives.
- Rewritten `README.md`, `README_zh-TW.md`, `DOCS.md`, plus `docs/CI.md` and
  `docs/MIGRATION.md`.

### Deliberately not included

- **Pi** (`@earendil-works/pi-coding-agent`) is absent and fenced by four
  layers: the validator's path-existence loop, the validator's forbidden-package
  regex, the container smoke script, and CI.
- Any in-pod authentication. NPM's Access List is the auth boundary.
- The HA ingress-prefix machinery (`ha-ingress.js`, the ~12 URL `sub_filter`
  rewrites, `X-Ingress-Path`, `proxy_set_header Origin ""`). Behind NPM the app
  is mounted at `/` on its own vhost; injecting an empty prefix over every
  network call would be pure regression surface.
- An arm64 build. All four `woow-k3s` nodes report `amd64`, so the arm64 matrix
  leg and the QEMU step are removed. The pinned base image ships an aarch64
  variant, so this is reversible.

## 1.0.0 — withdrawn

Historical entry, retained so the version number is not silently reused.
Migrated the repository from Kustomize to a Helm chart (commit `6f742b3`,
2026-08-05). Shipped `open-design`, `od-console` (Flask + ttyd) and `od-mcp`
components. Never successfully installed on a cluster; committed live
credentials to `values.yaml`. Superseded entirely by 2.0.0.
