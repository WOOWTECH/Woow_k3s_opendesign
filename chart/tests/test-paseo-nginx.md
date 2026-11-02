# Paseo Nginx startup regression

Run from the repository root with Python 3.9+, PyYAML, Helm and Nginx with the HTTP
JavaScript module (njs):

```sh
python3 charts/open-design/tests/test-paseo-nginx.py
```

For the chart's Alpine image extracted locally, set `NGINX_ROOTFS` to that
directory. The harness invokes its musl loader directly; Docker, root and chroot
are unnecessary. Alternatively use `NGINX_BINARY` and `NGINX_MODULE_DIR` for a
native installation. `HELM_BINARY` can override Helm. Missing prerequisites fail
the suite. The suite itself never downloads an image or calls Kubernetes.

The fixtures use synthetic origins: short, a PaaS-shaped long hostname, a
253-character DNS hostname, and that hostname with port 65535. Full rendered
`nginx.conf`, `default.conf`, and `authguard.js` are loaded. Only local filesystem
paths, the listener (a temporary Unix socket), and the console service hostname
(loopback) are relocated. Tests retain njs, Basic Auth, console and MCP locations.
Startup requests hit Nginx's local `/healthz` stub. The proxy-boundary test also
starts an owned fake app on an ephemeral loopback port; no real app is contacted.
It checks all four Paseo locations: anonymous requests return 401, writes without
Origin and foreign-origin reads return 403 without reaching the fake app, and
authenticated same-origin requests preserve the path and Origin while stripping
Authorization and replacing a spoofed user identity with the Basic-auth user.

The negative control changes the rendered bucket size to 64 in temporary test
data and must reproduce `could not build map_hash`. The positive cases require
the chart's 512-byte setting, run `nginx -t`, start Nginx, read its health stub,
then stop its own process group. Additional startup cases cover disabled njs,
disabled console/MCP routes, and Paseo disabled with short and long origins.

## Disabled-Paseo regression

With `paseo.enabled=false` and a long `config.allowedOrigins`, the older
`$od_local_route_origin_ok` map also needs the larger bucket. The 512-byte
directive is now unconditional in the authproxy HTTP block. Disabled-Paseo
startup with the PaaS and maximum-DNS-plus-port fixtures is a normal passing
requirement, with no expected failures. The original `test-paseo.py` baseline
check aligns the released chart version, then permits this exact
directive/comment addition and the separately tested Console terminal base-path
fix, including their derived rollout checksums; every other
rendered field must still match the pre-Paseo baseline.

This checks local configuration parsing and startup, not service 10 deployment,
production image digest equality, upstream reachability, or browser pairing.
