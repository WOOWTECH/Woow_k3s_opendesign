# Woow_k3s_opendesign — Open-Design Helm Chart for K3s/Kubernetes

[繁體中文](README_zh-TW.md)

Helm chart deploying **Woow Open-Design** (a Claude Code-style headless coding
agent) on K3s/Kubernetes, together with:

- `od-console` — a Flask + ttyd web dashboard for the daemon
- `od-mcp` — an MCP server that exposes the OD API to AI agents

> **Looking for another platform?**
> Ubuntu host + rootless podman → [Woow_podman_opendesign](https://github.com/WOOWTECH/Woow_podman_opendesign)

## Architecture

| Component | Image | Service | Default port | Notes |
|---|---|---|---|---|
| open-design (daemon) | `localhost/open-design:latest` | `open-design-svc:7457` | ClusterIP | Pinned to a specific node via `opendesign.nodeHostname` |
| od-console | `python:3.9-slim` (runtime tool install) | `od-console-svc:18790` (dashboard) + `:7681` (ttyd) | ClusterIP | Flask UI + `kubectl exec` shell into the daemon pod |
| od-mcp | `localhost/od-mcp:latest` | `od-mcp-svc:8080` (admin) + `:8000` (MCP) | ClusterIP | Pinned to `mcp.nodeHostname` |

- Storage: `local-path` PVCs — 8Gi for `/app/.od`, 2Gi for `/home/opendesign`, 100Mi for MCP config
- Traffic lockdown: opt-in NetworkPolicies (`networkPolicy.enabled=true`, default) restrict ingress to in-cluster sources
- Console has an in-namespace Role/RoleBinding so it can `kubectl exec` / restart the daemon

The `localhost/*` images are built and loaded onto the node beforehand
(see `Dockerfile.open-design` at repo root); hence the default
`imagePullPolicy: Never`.

## Quick start

```bash
# Install straight from the repo tarball (no clone needed)
helm install opendesign https://github.com/WOOWTECH/Woow_k3s_opendesign/archive/refs/heads/main.tar.gz \
  --set opendesign.nodeHostname="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"

# Or from a local clone
git clone https://github.com/WOOWTECH/Woow_k3s_opendesign.git
cd Woow_k3s_opendesign
helm install opendesign .
```

> **Change every secret and both `__DOMAIN__` placeholders before a real
> deployment:**
>
> ```bash
> helm install opendesign . \
>   --set secrets.odApiToken="$(openssl rand -hex 32)" \
>   --set secrets.anthropicApiKey="sk-ant-…" \
>   --set secrets.tuiPassword="$(openssl rand -base64 24)" \
>   --set secrets.mcpJwtSecret="$(openssl rand -hex 32)" \
>   --set secrets.mcpAdminPassword="$(openssl rand -base64 18)" \
>   --set opendesign.config.OD_ALLOWED_ORIGINS="https://od.example.com" \
>   --set opendesign.config.OD_PUBLIC_BASE_URL="https://od.example.com" \
>   --set opendesign.nodeHostname=my-k3s-node \
>   --set mcp.nodeHostname=my-k3s-node
> ```

## Key values

| Value | Default | Description |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `open-design` | Target namespace |
| `opendesign.nodeHostname` | `__K3S_NODE_HOSTNAME__` | `kubernetes.io/hostname` pin for the daemon |
| `opendesign.image.repository` / `tag` / `pullPolicy` | `localhost/open-design` / `latest` / `Never` | Locally built image |
| `opendesign.service.type` / `port` / `nodePort` | `ClusterIP` / `7457` / `""` | Set `type=NodePort` + `nodePort` to expose the daemon |
| `opendesign.persistence.{data,home}.size` | `8Gi` / `2Gi` | `local-path` PVCs |
| `opendesign.config.OD_ALLOWED_ORIGINS`, `OD_PUBLIC_BASE_URL` | `https://__DOMAIN__` | Deploy-time domain |
| `console.enabled` | `true` | Deploy `od-console` (Flask + ttyd) |
| `console.service.type` / `httpNodePort` / `ttydNodePort` | `ClusterIP` / `""` / `""` | Set `type=NodePort` + node ports to expose |
| `mcp.enabled` | `true` | Deploy the MCP server |
| `mcp.nodeHostname` | `woowtechcluster1-aorus-15p-xd` | Node pin (override for your cluster) |
| `mcp.service.type` / `adminNodePort` / `mcpNodePort` | `ClusterIP` / `""` / `""` | Set `type=NodePort` + node ports to expose |
| `networkPolicy.enabled` | `true` | Ship the three NetworkPolicies |
| `secrets.*` | `changeme…` / `PLACEHOLDER…` | Daemon + console + MCP secrets |

Full list: [`values.yaml`](values.yaml).

## Verify

```bash
kubectl get pods -n open-design                         # all Ready
kubectl exec -n open-design deploy/open-design -- \
  curl -s http://localhost:7457/api/health              # {"ok":true,...}
```

## Uninstall

```bash
helm uninstall opendesign
# PVCs are kept by Helm; remove them (and your data!) with:
kubectl delete pvc -n open-design \
  open-design-data-pvc open-design-home-pvc od-mcp-data
```

## Migrating from the old Kustomize deployment

This repository replaces the `main` branch of the archived
[Woow_opendesign_docker_compose_all](https://github.com/WOOWTECH/Woow_opendesign_docker_compose_all)
repo. The chart's default rendering is resource-equivalent to those manifests
(same names, namespace, labels, ports, PVCs, RBAC, NetworkPolicies), with three
deliberate differences:

1. **`imagePullPolicy: IfNotPresent`** is written explicitly on the console
   container (was implicit / K8s default for non-`:latest` images).
2. The `Namespace` object carries an extra `managed-by: helm` label.
3. **The `od-secrets` secret now carries `TUI_PASSWORD`.** The original
   `08-console-deployment.yaml` declares `TUI_PASSWORD` as a required
   `envFrom` secret key, but `01-secrets.yaml` did not define it — a latent
   bug that prevented the console pod from starting. The chart adds it
   with a `changeme-…` default (same style as other Woow secrets).

The original manifests remain in this repo's git history under `k8s-manifests/`.

## License

MIT
