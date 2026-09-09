# Woow k3s OpenDesign — operations reference

Companion to [README.md](README.md). This file covers day-2: environment,
storage, probes, the sidecar contract, and troubleshooting.

## Environment

Everything OD reads comes from `ConfigMap <release>-config` via `envFrom`.
**No Secret is involved and none is needed.**

| Variable | Value | Source |
|---|---|---|
| `OD_DATA_DIR` | `/data/opendesign` | `opendesign.dataDir` |
| `OD_BIND_HOST` | `127.0.0.1` | chart-owned, not overridable |
| `OD_PORT` | `7456` | `opendesign.port` |
| `OD_ALLOWED_ORIGINS` | `.Values.publicUrl` | required |
| `OD_PUBLIC_BASE_URL` | `.Values.publicUrl` | required |
| `NODE_ENV` | `production` | chart-owned |
| `TZ` | `Asia/Taipei` | `opendesign.timezone` |

Baked into the image and deliberately not settable from values, so a typo
cannot break the renderer:
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`,
`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser`,
`HOME=/data/opendesign/home`,
`PATH=/opt/woow-opendesign/opencode/node_modules/.bin:$PATH`.

Deliberately **not** set: `OD_API_TOKEN`, `OD_DISABLE_API_AUTH`,
`OD_ALLOWED_INTERNAL_HOSTS`, `OD_SANDBOX_MODE`,
`OD_SANDBOX_IMPORT_ALLOWED_ROOTS`, `OD_REQUIRE_DESKTOP_AUTH`,
`OD_LEGACY_DATA_DIR`, `NODE_OPTIONS`. Turning any of them on is an explicit
act through `opendesign.extraEnv`, which is reviewable in a diff.

### Why `OD_BIND_HOST` is not a knob

OD 0.21.1's `server.js` refuses to start on a non-loopback bind unless
`OD_API_TOKEN` is set or `OD_DISABLE_API_AUTH=1`. Loopback is the only bind
that needs neither. It also makes the daemon socket unreachable over the pod
network, so the NetworkPolicy is a second line of defence rather than the only
one.

### Why `OD_ALLOWED_ORIGINS` is a single origin

OD's origin validator has an explicit reverse-proxy escape hatch: an `Origin`
in the allow-list is trusted regardless of the `Host` the proxy set. Because
the sidecar rewrites `Host` to `127.0.0.1:7456`, that allow-list is what keeps
real cross-site rejection working. A malformed value (non-http/https scheme) is
a hard startup failure, not a silent widening. Never set it to `*`.

The residual case is a request with **no** `Origin` at all. OD then falls back
to host validation, which the loopback `Host` passes. That is fine for GETs and
wrong for mutations, so the sidecar returns 403 for any
non-GET/HEAD/OPTIONS with an empty `Origin`
(`nginx.requireOriginOnMutation`, default `true`).

## The nginx sidecar contract

What it does:

- terminates the pod-network connection on `:7457` so OD can stay on loopback
- `proxy_set_header Host 127.0.0.1:7456;`
- **passes `Origin` through unchanged** (this is the one deliberate divergence
  from the HA add-on, which blanks it — behind NPM the origin is a fixed vhost,
  so we can do better than throwing the check away)
- streaming hygiene: `proxy_buffering off`, `proxy_request_buffering off`,
  3600s read/send timeouts, `client_max_body_size 256M`, and the
  `map $http_upgrade $connection_upgrade` + `Upgrade`/`Connection` pair
- serves `/od-export-bridge.js` and injects it with exactly **one**
  `sub_filter` on `<head>`
- returns 403 for mutating requests with no `Origin`

What it must never do — these are written as literal comments in the ConfigMap
so nobody re-adds them:

- **no `auth_basic`**, no htpasswd, no token check. Auth is NPM's job.
- **no path-prefix rewriting.** No `X-Ingress-Path`, no `$safe_ingress_path`,
  none of the HA add-on's ~12 URL `sub_filter`s, no `ha-ingress.js`. Behind NPM
  the app is mounted at `/` on its own vhost; injecting an empty prefix over
  every network call in the SPA is pure regression surface.
- **no `proxy_set_header Origin "";`**

`tests/validate.py` asserts all three absences and that exactly one
`sub_filter` directive exists.

## Storage

One PVC, `<release>-data`, 20Gi, `longhorn` (RECLAIMPOLICY `Retain`,
expandable), mounted at `/data/opendesign`.

Because `HOME=/data/opendesign/home`, the 1.x chart's second PVC
(`open-design-home-pvc` at `/home/opendesign`) is folded in: one volume, one
restore unit, no way for the two to drift. The launcher creates `home/`,
`export-render/` and `export-pdf/` under it at `0750` owned by UID 1001,
refusing to follow symlinks while doing so.

The class is `longhorn`, never `longhorn-delete` and never `local-path`. The
deployment being replaced put ~204 MiB of tenant data on `longhorn-delete`
(reclaim `Delete`), one `helm uninstall` away from gone. `local-path` pins data
to one node's disk, reclaims `Delete`, and cannot expand.

Expanding later:

```bash
kubectl -n pi-agent-woow patch pvc od-data \
  -p '{"spec":{"resources":{"requests":{"storage":"40Gi"}}}}'
```

## Probes

All three probes live on the **nginx sidecar**, against
`http://:7457/api/health`. OD's origin middleware exempts health and version
for monitoring probes. The OD container carries no probes because it is
loopback-only and the sidecar's probes already cover the pod.

| Probe | Period | Failures | Why |
|---|---|---|---|
| startup | 10s | 60 | Chromium + OD cold start on a freshly attached Longhorn volume is slow. 10 minutes of headroom. |
| readiness | 10s | 3 | |
| liveness | 30s | 5 (timeout 10s) | |

Kubelet probes are exempt from NetworkPolicy, so no rule is needed for them.

## Resources

| Container | Requests | Limits |
|---|---|---|
| `opendesign` | 500m / 2Gi | 4 / 8Gi |
| `nginx` | 20m / 32Mi | 200m / 128Mi |

`NODE_OPTIONS` is not set; the 8Gi limit does the work. The `pi-agent` fleet
sets `--max-old-space-size=12288`, which would be wrong here.

## Troubleshooting

**Pod stuck in `ContainerCreating`, events mention volume attach.**
A Longhorn RWO volume attaches to one node. If a backup Job and the Deployment
landed on different nodes, the Job hangs. Check the CronJob still has its
**required** podAffinity on `app=opendesign`.

**`helm upgrade` hangs and the old pod will not go away.**
`strategy: Recreate` is intentional; the old pod must release the RWO volume
before the new one attaches. If it persists, look for a stuck Longhorn volume
attachment, not for a chart bug.

**403 "Untrusted API request" or a CORS failure in the browser.**
`publicUrl` does not match the hostname you are actually browsing. It must be
the exact NPM proxy-host origin, `https://` included, no trailing path.

**A script or MCP client gets 403 on POST but the browser works.**
That is `nginx.requireOriginOnMutation` doing its job: the client sends no
`Origin`. Either give the client an `Origin` header, or set the value to
`false` and record why — the NPM Access List is then the only guard on that
path.

**The PDF button downloads nothing.**
`od-export-bridge.js` is not being injected. Check that
`GET /od-export-bridge.js` returns JavaScript, and that the served HTML
contains `<script src="/od-export-bridge.js">`. The `sub_filter` needs
`proxy_set_header Accept-Encoding "";` to see the body at all.

**Editable PPTX fails.** Expected. Choose the screenshot/image PPTX mode.

**Image/PDF export says the renderer failed.**
Check the OD container log for Chromium errors and reduce page
dimensions/length. The renderer enforces hard budgets (64 slides, 48M pixels,
128MiB output, 120s deadline) and fails with a bounded-size error rather than
exhausting the pod's memory.

**Nothing reaches the pod from NPM.**
Confirm the NetworkPolicy ingress peer matches NPM's actual pod labels
(`app=npm`) and that you are hitting Service port 7457, not 7456. Port 7456 is
loopback-only and will never answer over the pod network — that is by design,
not a misconfiguration.

**"No models" / BYOK not working.**
Keys live in the browser's local storage. They are not shared between
browsers, not backed up, and not in `/data`. Re-enter them in Settings.
`opencode-ai@1.18.29` is on `PATH` inside the container for OD's native
`byok-opencode` runtime; the release gate verifies its exact version and path.
