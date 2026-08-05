# Woow_k3s_opendesign — Open-Design 的 K3s/Kubernetes Helm chart

[English](README.md)

在 K3s / Kubernetes 上部署 **Woow Open-Design**（Claude Code 風格的 headless
coding agent）的 Helm chart，同時包含：

- `od-console` — Flask + ttyd 網頁儀表板
- `od-mcp` — 對 AI agent 開放 OD API 的 MCP server

> **找其他平台？**
> Ubuntu 主機 + rootless podman → [Woow_podman_opendesign](https://github.com/WOOWTECH/Woow_podman_opendesign)

## 架構

| 元件 | 映像 | Service | 預設 port | 備註 |
|---|---|---|---|---|
| open-design（daemon） | `localhost/open-design:latest` | `open-design-svc:7457` | ClusterIP | 透過 `opendesign.nodeHostname` 綁到特定節點 |
| od-console | `python:3.9-slim`（runtime 安裝工具） | `od-console-svc:18790`（儀表板）+ `:7681`（ttyd） | ClusterIP | Flask UI + 用 `kubectl exec` 進 daemon pod |
| od-mcp | `localhost/od-mcp:latest` | `od-mcp-svc:8080`（admin）+ `:8000`（MCP） | ClusterIP | 綁到 `mcp.nodeHostname` |

- 儲存：`local-path` PVC — `/app/.od` 8Gi、`/home/opendesign` 2Gi、MCP config 100Mi
- 流量鎖定：預設啟用 NetworkPolicies（`networkPolicy.enabled=true`）僅允許叢集內來源
- Console 具備 namespace 內的 Role/RoleBinding，可 `kubectl exec` / 重啟 daemon

`localhost/*` 映像需事先在節點上 build 並匯入（見 repo 根目錄
`Dockerfile.open-design`），故預設 `imagePullPolicy: Never`。

## 快速開始

```bash
# 免 clone，直接從 tarball 安裝
helm install opendesign https://github.com/WOOWTECH/Woow_k3s_opendesign/archive/refs/heads/main.tar.gz \
  --set opendesign.nodeHostname="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"

# 或從 local clone
git clone https://github.com/WOOWTECH/Woow_k3s_opendesign.git
cd Woow_k3s_opendesign
helm install opendesign .
```

> **正式部署前務必修改所有 secret、覆蓋兩個 `__DOMAIN__` 佔位符：**
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

## 主要 values

| Value | 預設 | 說明 |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `open-design` | 目標 namespace |
| `opendesign.nodeHostname` | `__K3S_NODE_HOSTNAME__` | daemon 的 `kubernetes.io/hostname` 綁定 |
| `opendesign.image.repository` / `tag` / `pullPolicy` | `localhost/open-design` / `latest` / `Never` | 本機 build 的 image |
| `opendesign.service.type` / `port` / `nodePort` | `ClusterIP` / `7457` / `""` | 需要對外時設 `type=NodePort` + `nodePort` |
| `opendesign.persistence.{data,home}.size` | `8Gi` / `2Gi` | `local-path` PVC |
| `opendesign.config.OD_ALLOWED_ORIGINS`, `OD_PUBLIC_BASE_URL` | `https://__DOMAIN__` | 部署時的域名 |
| `console.enabled` | `true` | 部署 `od-console`（Flask + ttyd） |
| `console.service.type` / `httpNodePort` / `ttydNodePort` | `ClusterIP` / `""` / `""` | 需要對外時設 `type=NodePort` |
| `mcp.enabled` | `true` | 部署 MCP server |
| `mcp.nodeHostname` | `woowtechcluster1-aorus-15p-xd` | 節點綁定（依你的叢集修改） |
| `mcp.service.type` / `adminNodePort` / `mcpNodePort` | `ClusterIP` / `""` / `""` | 需要對外時設 `type=NodePort` |
| `networkPolicy.enabled` | `true` | 是否 ship 三份 NetworkPolicy |
| `secrets.*` | `changeme…` / `PLACEHOLDER…` | daemon + console + MCP 的 secret |

完整清單見 [`values.yaml`](values.yaml)。

## 驗證

```bash
kubectl get pods -n open-design                         # 全部 Ready
kubectl exec -n open-design deploy/open-design -- \
  curl -s http://localhost:7457/api/health              # {"ok":true,...}
```

## 移除

```bash
helm uninstall opendesign
# Helm 會保留 PVC；連資料一起刪：
kubectl delete pvc -n open-design \
  open-design-data-pvc open-design-home-pvc od-mcp-data
```

## 從舊 Kustomize 部署遷移

本 repo 取代已封存的
[Woow_opendesign_docker_compose_all](https://github.com/WOOWTECH/Woow_opendesign_docker_compose_all)
的 `main` 分支。Chart 預設輸出與原 manifests 資源等價（相同的 name、
namespace、labels、ports、PVC、RBAC、NetworkPolicies），僅三項刻意差異：

1. Console container 的 **`imagePullPolicy: IfNotPresent`** 明寫出來（原本
   為 K8s 對非 `:latest` image 的隱性預設）。
2. `Namespace` 物件多一個 `managed-by: helm` label。
3. **`od-secrets` 加上 `TUI_PASSWORD` 這個 key。** 原 `08-console-deployment.yaml`
   把 `TUI_PASSWORD` 宣告為必要的 `envFrom` secretKeyRef，但
   `01-secrets.yaml` 沒定義該 key — 這是一個 console pod 無法啟動的既有 bug。
   Chart 用 `changeme-…` 預設值把它補上（與其他 Woow secret 同風格）。

原 manifests 仍保留在本 repo 的 git 歷史（`k8s-manifests/`）中。

## License

MIT
