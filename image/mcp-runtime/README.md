# mcp-runtime — built-in OpenDesign MCP server of the PaaS open-design image

The OpenDesign MCP server built into the PaaS open-design service (chart `open-design` >= 0.5.0, container `mcp`),
replacing the separate *Open Design MCP* (`mcp-opendesign`) template. It runs **the HA add-on's built-in MCP runtime
unchanged**, so the HA add-on and the PaaS offer the same tools, defaults and protections.

| Path | What it is |
|---|---|
| `ha/` | Pinned copy of `mcp-runtime/` of GitHub `WOOWTECH/Woow_ha_opendesign_add_on` (without its `tests/e2e/`): the vendored Woow MCP gateway and OpenDesign tools (`ha/vendor/`, `ha/VENDOR.json`), the add-on's runtime package `ha_opendesign_mcp/`, hash-pinned wheels (`ha/requirements/`), provenance. **Never edited here.** |
| `HA_SOURCE.json` | Source repository, commit and sha256 of every file in `ha/`. |
| `sync-ha-mcp-runtime.sh` | Re-copy `ha/` from a local clone of the add-on at a full commit sha (`git archive`), rewrite `HA_SOURCE.json`, verify. |
| `paas_opendesign_mcp/` | PaaS placement only: settings from the chart (`__init__.py`), `launch.py` (replaces the add-on's placement constants, seeds the admin page's client endpoint, runs the add-on's `runtime.main()`), `management.py` (the vendored credential guard, as in the add-on). |
| `bin/paas-opendesign-mcp` | Container command (uid/gid 10001, never root): checks `/data/mcp`, prepares `/run/od-mcp`, execs `management.py` with a fixed environment. |
| `install.sh` | Build-time install from `open-design/Dockerfile` (same `/opt/woow` layout and wheels as the add-on; user `mcp` 10001; checks). |
| `tests/verify_ha_copy.py` | `ha/` matches `HA_SOURCE.json`; then the add-on's own `ha/tests/verify_vendor.py`. |
| (build time) | `install.sh` also runs the add-on's overlay unit tests (`ha/tests/unit/run.sh`: rules, bounded handlers, tool surface) with the image's interpreters, as the add-on's own build does. |
| `tests/e2e/` | Container e2e of a built image in a pod-shaped Docker topology (`run-e2e.sh`): MCP auth, 15 tools, admin, protections, policy, token lifecycle, Claude.ai sequence, isolation, backend down, restart. |

## Runtime in the pod (chart open-design 0.5.0, `mcp.enabled=true`)

```
client ──HTTPS──▶ Cloudflare ─▶ Service :7457 ─▶ authproxy (nginx :8080)
   /mcp                  (Bearer, no basic-auth) ──────────────▶ mcp 127.0.0.1:8081 ─┐
   /private_<token>/mcp  (path secret, no basic-auth, no log) ─▶ mcp 127.0.0.1:8081 ─┤ gateway ─unix─▶ child
   /mcp-admin/           (basic-auth; X-Remote-User-Id) ─▶ /run/od-mcp/admin.sock ───┘   (vendored OpenDesign tools)
                                                                                           │
                                                          daemon 127.0.0.1:7457 ◀──────────┘ (pod loopback)
```

* `mcp` container: same image as the daemon, `command: /opt/woow/bin/paas-opendesign-mcp`, uid/gid 10001 (+ the pod's
  fsGroup 1001), read-only root file system, all capabilities dropped. Settings: `WOOW_OD_BACKEND_URL`
  (`http://127.0.0.1:<port>` only), `WOOW_OD_MCP_PORT`, `WOOW_OD_MCP_PUBLIC_ORIGIN` (first entry of
  `config.allowedOrigins`; seeds the client endpoint `<origin>/mcp` while it is unset).
* State: `/data/mcp` = od-data PVC subPath `.woow-mcp` (kubelet-created, root:1001). The runtime keeps the token and
  tool switches in `/data/mcp/state` (0700, uid 10001); the daemon container sees the directory under
  `/app/.od/.woow-mcp` but cannot list or read it.
* `/run/od-mcp` = emptyDir mounted only by the authproxy and mcp containers: `admin.sock` (0666; the mount is the access
  control) and `child/child.sock` (0700 directory of uid 10001).
* The MCP token is managed on `/mcp-admin/` (show / rotate / revoke); a new instance generates one on first start.

## Re-pin to another add-on commit

```sh
open-design/mcp-runtime/sync-ha-mcp-runtime.sh /path/to/Woow_ha_opendesign_add_on <full-sha>
git diff --stat open-design/mcp-runtime/ha open-design/mcp-runtime/HA_SOURCE.json   # review
```

`paas_opendesign_mcp/launch.py` refuses to start when the add-on renames or drops one of its placement constants
(`BACKEND_URL`, `DATA_DIR`, `RUN_DIR`, `ADMIN_SOCKET`, `CHILD_SOCKET`, `MCP_HOST`, `MCP_PORT`) or `pin_backend()`;
`install.sh` fails the build when any add-on path is left after the placement. Run the e2e on the builder VM or let the
PR workflow run it.

## External model usage through MCP

All 15 tools are on by default (owner decision 2026-10-15), including `create_project` / `send_message`, which start
an agent run in OpenDesign. With no AI key configured on the service, an MCP client that picks the `opencode` agent
can still make OpenCode call an external model (OpenCode's own free models; the daemon container has internet egress)
and cause external usage. This is documented, not restricted. The tools' default agent is `claude`, which fails at
once without a login.

## Cloudflare Access

The MCP paths share the service's host name. If a tenant puts that host name behind Cloudflare Access, external MCP
clients — Claude.ai in particular, which cannot complete an Access login — are blocked. Either leave Access off for the
service, or add Access bypass rules for `/mcp` and `/private_*/mcp`. Nothing in the image or chart changes Access.
