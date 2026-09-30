# Woow OpenDesign (PaaS mirror)

[繁體中文](README_zh-TW.md) · [Provenance and sync](MIRROR.md)

A **read-only mirror** of the OpenDesign cloud service on the WOOW PaaS
platform. The source of truth is the internal Gitea (`git-prod.woowtech.io`);
changes are reviewed and approved there, then synced here with
[`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh).

> Do not edit `image/`, `console/` or `chart/` in this repository — the next
> sync overwrites them.

| Directory | Contents |
|---|---|
| [`image/`](image/) | OpenDesign daemon image — upstream `ghcr.io/nexu-io/od` **0.24.1** + Claude Code **2.1.284** + OpenCode **1.18.33**, with a build-time version contract |
| [`console/`](console/) | Console image — ttyd web terminal + Flask dashboard |
| [`chart/`](chart/) | Per-tenant Helm chart **0.2.1** installed by the PaaS operator |

Source commits for each directory are recorded in [MIRROR.md](MIRROR.md).

## Access

The daemon binds to loopback and is reached only through an nginx auth-proxy
sidecar (HTTP basic auth). The **same credentials** protect the ttyd console
and dashboard. Tenants set or rotate the username and password from the
service page ("Admin Credentials"); saving restarts the daemon and console.

## CI

[`ci.yml`](.github/workflows/ci.yml) validates only: `helm lint`, the chart's
own tests, and a no-push build of both images. Production artifacts are built
and published from Gitea behind a manual approval gate.

## History

The previous single-instance k3s chart (OpenDesign 0.21.1 behind Nginx Proxy
Manager) lives on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch
and the `v2.0.1` tag. That deployment moved into the PaaS platform on
2026-09-29.

## License

[MIT](LICENSE)
