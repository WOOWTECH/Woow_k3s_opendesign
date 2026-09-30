# Mirror provenance

This repository is a **read-only mirror** of the OpenDesign cloud service that
runs on the WOOW PaaS platform. The source of truth is the internal Gitea
(`git-prod.woowtech.io`). Changes land there first, go through that repo's
review and prod approval gates, and are then synced here with
[`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh).

**Do not edit `image/`, `console/` or `chart/` here** — the next sync
overwrites them. Open the change against the Gitea repository instead.

## Current sync

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `image/` | `woow-paas/paas-odoo-ci` | `open-design/` | `2a1dc8a7a9cad69b83385d5771d0bbe1ccba2617` |
| `console/` | `woow-paas/paas-odoo-ci` | `open-design-console/` | `2a1dc8a7a9cad69b83385d5771d0bbe1ccba2617` |
| `chart/` | `woow-paas/woow-paas-charts` | `charts/open-design/` | `2d41c78f5a009666ea6625678c752c042036ae23` |

Chart `0.2.1` / OpenDesign `0.24.1` — synced 2026-09-30 08:20 UTC.
<!-- END GENERATED -->

## What each directory is

| Directory | What it builds | Where it runs |
|---|---|---|
| `image/` | OpenDesign daemon image: upstream `ghcr.io/nexu-io/od` + Claude Code + OpenCode, with a build-time version contract | `jcr-prod.woowtech.io/woow-paas-docker-local/open-design` (private) |
| `console/` | Console image: Flask dashboard + ttyd web terminal that `kubectl exec`s into the daemon pod | `jcr-prod.woowtech.io/woow-paas-docker-local/open-design-console` (private) |
| `chart/` | Helm chart installed per tenant by the PaaS operator | `oci://jcr-prod.woowtech.io/woow-paas-docker-local/open-design` |

`chart/Dockerfile.console` is a copy kept inside the chart source; the console
image that production actually runs is built from `console/Dockerfile`.

## How the PaaS platform uses it

- The platform (`odoo-addons/woow_paas_platform`, template `open-design`) pins
  the chart version and both images by `tag@sha256`.
- Each tenant instance gets its own namespace, two PVCs (`/app/.od` data,
  `/home/opendesign` home) and a Cloudflare-tunnel subdomain.
- Access is gated by an nginx auth-proxy sidecar in the daemon pod (HTTP
  basic auth). The **same username and password** also protect the console
  (ttyd + dashboard). The tenant sets or rotates both from the service page
  ("Admin Credentials"); saving restarts the daemon and console.

## Resyncing

```bash
scripts/sync-from-gitea.sh              # both repos at main
scripts/sync-from-gitea.sh <ci-ref> <charts-ref>
```

Needs read access to both Gitea repositories.

## History

The previous single-instance k3s chart (OpenDesign 0.21.1 behind Nginx Proxy
Manager in `pi-agent-woow`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
and the `v2.0.1` tag. That deployment (`od-woow-k3s.woowtech.io`) was migrated
into the PaaS platform on 2026-09-29.
