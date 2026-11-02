# Source promotion candidate — chart 0.5.9, 2026-10-26

The native Paseo feature is rebased onto chart main a8ff59d. Version 0.5.8 is
already published and immutable; this source promotion uses a new 0.5.9 version
because the packaged release documentation has changed. Runtime templates,
supervisor, default-off feature flag and image defaults match feature 115adec.
The Python runtime and Nginx regression suites now join the shell CI runner.

The shared PaaS product may enable Paseo only with the matching reviewed PaaS
image tag and digest. That digest is **AWAITING_COORDINATOR_DIGEST**. The chart
alone does not promote a product default or change service 10/244 pins.
No merge, publication or rollout is part of this source-preparation change.

The following 2026-10-25 receipt is historical evidence for the existing optional
release; its image and rollout notes are not the new product promotion receipt.

---

# Optional Paseo deployment — chart 0.5.8, 2026-10-25

Chart **0.5.8** adds the optional native Paseo app and fixes long-origin Nginx
startup for both enabled and disabled Paseo. It builds on **0.5.7 / 33d476a**.
The parent owns publication and live deployment; this worktree contains local
source, documentation and focused test results for review.

## Stable release and image pins

The parent supplied this release receipt on 2026-10-25:

- Chart version: **0.5.8**.
- Published chart OCI digest: `sha256:424f8b319e184da55c1946cab2f1f0b979fcd729f8c47dd36e3f2eecdd719520`.
- Fixed optional image: `jcr-prod.woowtech.io/woow-paas-docker-local/open-design:paseo-0.2.0-20261025-5cecb3797ad9@sha256:d866cb29de10dc8bd3502b01fcc92fb2f0ce2ccbea94228e302005a58fd4db66`.
- Deployment target: **service10, revision28**, reported as deploying. This is
  parent-reported rollout state, not a completed live acceptance result from this worker.

The chart digest identifies the parent's published artifact; it is not a digest
calculated from a new package of this documentation checkout. Keep the optional
image pin in the service override; the chart's default image selection and
default-off `paseo.enabled` remain separate from this feature deployment.

### Platform prerelease parsing limitation

The parent observed `helm_chart_version` recorded as **`paseo.2`** for a
**`0.5.8-paseo.2`** chart while service10 was `running` at revision27. A rollout
guard comparing that field with the full chart SemVer therefore failed despite
the reported running state. The platform's recorded version must not be treated
as an intact prerelease version in this affected path.

Use stable chart versions such as **0.5.8**, without a prerelease suffix, until
the platform version parser and its rollout metadata guard are fixed and
verified. The image's feature tag remains pinned independently by digest.

The parent chose `crane append` to create a
separate feature image over the production digest, adding the reviewed compiled
native MCP modules, bridge package/dependencies and launcher manifest. Preserve
the base ENTRYPOINT/bootstrap and record source/compiler/file hashes. This
supersedes the full rebuild route below for the current delivery. The parent owns
the controlled registry configuration and live build/deploy; this worker does
not inspect it. The live target is **service10 only**; service244 scope is pending.

## Inspected source and build path

The locally inspected image checkout is
`/data/pi-agent/home/work/paas-odoo-ci-od-launchers`, commit **a9a5ca1**.

| Component | Repository-relative source | Observed behavior |
| --- | --- | --- |
| Native fork pins | `open-design/od-source.env` | w2.4 / b8a1371924d3aedb74dff563a5ff35a783919dee; upstream 0.24.1 |
| Native daemon/web | fork `deploy/Dockerfile` | Workflow checks tag/SHA and upstream ancestry before building |
| Core | `open-design/Dockerfile.core` | Fixed Claude 2.1.296, Codex 0.162.1, Pi 1.1.0, OpenCode 1.18.33; Omnigent off |
| PaaS wrapper | `open-design/Dockerfile` | Adds shared MCP runtime; published `paas` stage ENTRYPOINT is `/sbin/tini --` |
| Paused host wrapper | `open-design/omnigent-host-entry` | Used only by the optional `with-omnigent` stage; do not repurpose it for Paseo |
| Build orchestration | `.gitea/workflows/build-open-design-image.yml` | Fork base → core → PaaS → verification → candidate tags → human approval |
| Provenance check | `scripts/check-open-design-core-legal.sh`, `open-design/core-legal/doc/woow-open-design/NOTICE.md` | NOTICE must match the new native fork commit set |
| Chart baseline | `/data/pi-agent/home/work/woow-paas-charts-od-launchers/charts/open-design` | Inspected 0.5.7; this worktree now records stable 0.5.8 |

The existing workflow uses runner-side **Docker**, not the local terminal's
Docker. Its only dispatch inputs are `tag` (YYYYMMDD.HHMM) and `approval_issue`.
It has no feature-repository or skip-promotion input. Phase one builds, verifies,
pushes `*-pending-approval`, and opens an approval issue; `/approve` promotes the
already-built artifacts. Core promotion leaves `latest` alone, but PaaS promotion
sets **PUSH_LATEST=true**. Do not use that final promotion for a separate optional
product. Runner availability has not been checked in this research.

Alternative full rebuild route retained for future image maintenance; the
current pinned delivery uses the `crane append` overlay described above:

1. Finish the native fork's atomic per-entry MCP API and bundled launcher. Pin its
   reviewed tag plus full SHA in a feature checkout; update the matching NOTICE.
   Do not replace the main CLI-only pins or publish a fake w2.4 identity.
2. Reuse the workflow's strict fork/core/PaaS build stages on that checkout. Keep
   all four CLI versions fixed. The unmodified w2.4 image cannot provide a new
   native API merely by adding `/opt/opendesign-paseo`.
3. Add a separate `open-design/Dockerfile.paseo` / candidate workflow owned by the
   package integrator. Base it on the newly built PaaS image **by digest**, copy
   the reviewed `.2` bridge bundle (including locked production dependencies) to
   root-owned `/opt/opendesign-paseo`, and retain its ENTRYPOINT/bootstrap and CMD.
   The bundle's SDK 1.32.2 audit is reported by the main agent, not rechecked here.
4. Give optional core/PaaS artifacts separate immutable names or a candidate-only
   workflow without the existing main-repository `latest` promotion. Do not run
   npm installation or fetch mutable source on container startup.
5. After main-agent authorization, deploy the new image digest and a released
   chart containing this patch to **service10 only** through the platform's native
   reconfiguration flow. Services244/148 and the default template remain outside
   this deployment scope.

Historical scripts at
`work/opendesign-alignment-20261014/team/core-publish/proof/` also require Docker.
They are evidence of past VM builds, not a currently authorized Kaniko/BuildKit
pipeline. A namespace with no builder pods and a local `crane` binary do not
provide a Dockerfile build executor. No new sandbox builder is created here.

## Minimal chart/runtime contract

```yaml
image:
  repository: jcr-prod.woowtech.io/woow-paas-docker-local/open-design
  tag: "paseo-0.2.0-20261025-5cecb3797ad9@sha256:d866cb29de10dc8bd3502b01fcc92fb2f0ce2ccbea94228e302005a58fd4db66"
paseo:
  enabled: true
  origin: https://your-opendesign.example
```

Use this only alongside the new compatible optional image digest. An empty
`paseo.origin` uses the first concrete `config.allowedOrigins` value. HTTPS,
Basic Auth, loopback OD binding, explicit chart daemon argv, and both existing
PVCs are required. Without `paseo.enabled`, including old values with no `paseo`
map, no Paseo supervisor or routes are added. Compared with 0.5.7, the disabled
render changes only chart-version metadata, the required Nginx hash setting and
their derived rollout checksums.

| Interface | Value |
| --- | --- |
| Launcher URL | `/paseo/setup` |
| Listener | `127.0.0.1:7460` (fixed in the supplied app contract) |
| Runtime entry | `/opt/opendesign-paseo/bin/serve.mjs` |
| Chart supervisor | `/etc/opendesign-paseo/launch.py` |
| HOME | `persistence.home.mountPath` (normally `/home/opendesign`) |
| OPENDESIGN_PASEO_DATA_DIR | `persistence.data.mountPath`, the **OD data root** (normally `/app/.od`) |
| OPENDESIGN_PASEO_ORIGIN | Resolved concrete HTTPS origin |
| OPENDESIGN_PASEO_NATIVE_PORT | `service.targetPort` (normally 7457) |
| OPENDESIGN_PASEO_BUNDLED_PLUGIN | `/app/plugins/_official/woow/woow-paseo` |
| OPENDESIGN_PASEO_AUTO_ENABLE | `1` |

The app must bind loopback, use the new atomic MCP entry API, preserve user-owned
MCP entries, and refuse incompatible native capabilities. There is no whole-config
PUT fallback in the deployment contract. AUTO_ENABLE must respect a persisted
manual-stop decision; restarts must not overwrite that decision.

## Routing and persistence

Existing `/console/` goes to ttyd in a separate console Pod; ttyd performs its own
Basic Auth and forwards terminal commands into the OD container. Existing
`/mcp-admin/` uses nginx Basic Auth and a Unix socket shared only with the MCP
container; `/mcp` uses the MCP runtime's own credential. Those routes are unchanged.

New exact routes `/paseo/setup`, `/paseo/setup/`, `/api/paseo-bridge` and the prefix
`/paseo/assets/` share nginx Basic Auth and its existing lockout guard. nginx keeps
their original URI and Origin, strips the Basic Authorization header, replaces
the asserted user header, and supports unbuffered streams/WebSocket upgrade.
Cross-origin requests and mutations without Origin are rejected before proxying.
Paseo request access/error logging is disabled so upstream failures do not record
login or pairing query values. Backend diagnostics must also remain sanitized.
The app's `/healthz` is called only on loopback; public `/healthz` remains the
existing nginx-local health stub.

The authproxy HTTP block always sets `map_hash_bucket_size 512`. Both the new
method-plus-origin map and the existing local-route origin map must accommodate
long public hostnames. Making the setting conditional on Paseo would break
Nginx startup when Paseo is disabled but a long `config.allowedOrigins` remains.

No Service port, NetworkPolicy, RBAC, PVC, MCP sidecar, or console change is needed.
There is no sharedProcessNamespace setting, host preload, fingerprint exception,
mount migration, recursive chmod, state deletion, or credentials copy. The native
stdio MCP sees Paseo PIDs through the same container `/proc`.

## Supervisor semantics and limits

The chart inserts `python3 /etc/opendesign-paseo/launch.py --` before the original
OD argv using **args only**. The image ENTRYPOINT and any future pinned bootstrap
still run first. OD receives its original environment; the Paseo app receives an
explicit allowlist plus its OPENDESIGN_PASEO settings. Existing provider env may
be inherited, but OD_API_TOKEN, Basic credentials, unknown env, and NODE_OPTIONS
preloads are excluded. Nothing prints env values.

The supervisor starts OD and Paseo as separate process groups in the **same PID
namespace**. Paseo failure retries after five seconds. After a 30-second startup
grace, three failed `/healthz` samples (five-second intervals) restart only the
app. Missing bundle files leave OD running and emit a fixed diagnostic. OD exit
stops Paseo and preserves the OD exit status so Kubernetes can restart the
container normally. TERM/INT signal both owned groups, wait up to ten seconds,
then kill remaining group members. Exited direct children are held with WNOWAIT
until group cleanup so a recycled PID cannot be killed.

The package must close its detached runtime/supervisor on graceful app shutdown
and reconcile an existing owned runtime after an app crash. Detached processes
are outside the chart wrapper's process groups: existing manager ownership guards
must handle them. This is still an integration acceptance item.

OD and Paseo share CPU/memory limits. Process supervision does **not** isolate
container OOM or provider-session load. The existing daemon probes remain intact;
Paseo health is not added to Pod readiness. User-visible degraded app behavior,
resource sizing, and a genuine workload test remain to be verified.

## Review and acceptance

Local focused verification commands:

```sh
helm lint charts/open-design
helm lint charts/open-design --set paseo.enabled=true --set paseo.origin=https://fixture.invalid --set mcp.enabled=true --set console.enabled=true
PYTHONDONTWRITEBYTECODE=1 python3 charts/open-design/tests/test-paseo.py
PYTHONDONTWRITEBYTECODE=1 python3 charts/open-design/tests/test-paseo-nginx.py
```

For an extracted Alpine Nginx image, set `NGINX_ROOTFS` as described in
[`tests/test-paseo-nginx.md`](tests/test-paseo-nginx.md). The suites render
synthetic Helm values, start temporary local processes and only request the
Nginx-local health stub over a temporary Unix socket. They do not call
Kubernetes, registries, providers or external URLs.

The 2026-10-25 local checks passed **12 chart/supervisor tests** and **6 real
Nginx 1.27.5 tests**, with no expected failures. Nginx coverage includes long
PaaS origins, a 253-character DNS hostname with port, enabled/disabled Paseo,
and a 64-byte negative control that reproduces the original hash failure.
The actual bridge package, native atomic MCP concurrency, CLI chats, full pod
restart/recovery, persisted manual stop, detached runtime reconciliation and
provider load remain separate integration acceptance items.

The service10 acceptance must confirm original data and peer MCP entries,
single registration, same-namespace /proc identity, unauthenticated denial,
same-origin mutations, provider two-turn chats when authorized, stop persistence,
Paseo-only failure recovery, graceful Pod shutdown, and OD/MCP/ttyd health.
Rollback is the prior immutable image/chart configuration through the native
platform flow with both PVCs retained. Turning `paseo.enabled` off removes the
chart supervisor and routes; it does not remove runtime files or tenant state.
The runtime/native integrator must define reversible plugin/MCP registration
cleanup before rollback acceptance.

The referenced `work/od-mcp-merge-20261015/ops/*.py` files were inspected only for
flow names. They perform historical multi-service writes/redeploys and must not
be executed for this feature. The supplied conversation ID was located only as
runner log filenames; no usable conversation transcript was recovered from them.
