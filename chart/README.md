# open-design

OpenDesign cloud service chart（daemon + console）。per-instance、ClusterIP、雙 RWO PVC、OCI 發布，
由 paas-operator 部署到 `paas-ws-*` 租戶 namespace。

> **安全模型 / 運作原理 / 威脅分析請看 platform 側的 canonical 文件**（本 README 只講 chart 實作，不重述）：
> [`woow_paas_platform` → `docs/reference/features/opendesign-console.md`](https://git-prod.woowtech.io/odoo-addons/woow_paas_platform/src/branch/develop/docs/reference/features/opendesign-console.md)
> —— 涵蓋端到端 `/console` 路由、ServiceAccount token（認證）vs Role（授權）、namespace-scoped blast radius、
> 「daemon 無憑證 / console 無互動入口 / NP 隔離」三道防線，以及三個 platform 側 Known gaps。

## Overview

一個部署由**兩個 Deployment / 三個容器**組成：

| 元件 | 容器所在 | Port | 角色 | 模板 |
| --- | --- | --- | --- | --- |
| **daemon** | `<release>-open-design` pod | 7457（綁 loopback）| OpenDesign 本體，跑 AI agent CLI | `templates/deployment.yaml` |
| **authproxy**（sidecar）| 同 daemon pod | 8080 | nginx basic-auth 閘 + 反向代理，對外唯一入口 | `templates/deployment.yaml` + `auth-proxy-configmap.yaml` |
| **console** | `<release>-open-design-console` pod | 7681（ttyd）/ 18790（Flask）| 網頁終端 + 管理儀表板 | `templates/console-deployment.yaml` + `console-configmap.yaml` |

- **PVC**：daemon 掛兩顆獨立 RWO PVC —— `od-data`（`/app/.od`, 8Gi）與 `od-home`（`/home/opendesign`, 2Gi，
  存 claude.ai 登入 session / agent CLI 設定）。見 `templates/pvc.yaml`。
- **Recreate**：daemon Deployment 用 `strategy=Recreate`（RWO PVC 不能同時掛兩個 pod）。
- **對外**：預設 ClusterIP，平台走 Cloudflare tunnel 導流；`ingress.enabled` 可選啟用 in-chart Ingress。

## 流量走向（精簡）

```
瀏覽器 ──HTTPS──▶ authproxy（daemon pod sidecar :8080）
                    ├── location /          → 127.0.0.1:7457（daemon 本體，同 pod）
                    └── location /console/  → console Service:7681（ttyd）
                                                └── ttyd 跑 connect.sh → kubectl exec 進 daemon 容器
```

完整端到端圖與訊號判讀（301 / 401 realm / 502 / `Waiting...` 各代表什麼）見上方 platform doc。

## 值得記錄的 templates

### `network-policy.yaml` — default-deny + 逐條 egress 洞

egress **絕不用** bare `- {}` allow-all（np-audit #42）。結構＝一條 default-deny（podSelector = release
`instance`）+ 逐 pod 開明確洞：

- **daemon egress**：DNS → kube-dns pod；daemon ↔ console:7681（給 `/console` 反代）；internet 443/80
  走**安全 ipBlock**（`0.0.0.0/0` 但 `except` 掉 cluster Pod/Service CIDR + RFC1918 + metadata + CGNAT +
  loopback）—— daemon 跑 agent CLI 需對外，但不得碰 in-cluster control-plane ClusterIP / SSRF metadata。
- **console egress**：DNS → kube-dns；kube-apiserver via `networkPolicy.apiServerCidrs`（443/6443）。
- **ingress**：預設無 allow 規則（`ingressNamespaces: []`），CS-ns ingress 由 operator baseline NP 治理（#279/#280）。

### `console-rbac.yaml` — namespace `Role`（非 ClusterRole）

console 的 ServiceAccount（`serviceaccount.yaml`）綁一條 per-release 的 **`Role` + `RoleBinding`**：

| 資源 | verbs | resourceNames | 範圍 |
| --- | --- | --- | --- |
| `pods` | get, list | *(無)* | namespace-wide |
| `pods/exec` | create, get | *(無)* | namespace-wide |
| `pods/log` | get | *(無)* | namespace-wide |
| `deployments` (apps) | get, patch | `<release>-open-design` | 只有自己那個 |
| `secrets` | get, patch, update | `<release>-open-design-secrets` | 只有自己那個 |

`pods/exec` 無 `resourceNames`（RBAC 的 resourceNames 對 `list` 無效、pod 名帶 hash 無法預綁）→
**blast radius 是整個 workspace namespace**；但綁定是 `Role`（非 `ClusterRole`）→ 天花板就是這個 namespace。
威脅分析（為何實際可觸及風險 ≪ 名目風險）見 platform doc。

### `auth-proxy-configmap.yaml` — nginx 反代 + basic-auth 閘

- `location /`（預設）：basic-auth（`admin` + `admin_password`）→ `proxy_pass 127.0.0.1:7457`。
- `/api/health`、`/api/ready`、`/api/version`：`auth_basic off`（給 probe / CF health）。
- `location /console/`：`auth_basic off` + WebSocket upgrade header → `proxy_pass console:7681`（ttyd 自己還有一層 auth）。
- `location = /console`：`absolute_redirect off` + `return 301 /console/`（否則 301 會洩漏內部 `http://host:8080`）。
- 主 `nginx.conf` **釘死 `worker_processes`**（nginx `auto` 非 cgroup-aware，高核心 node 會 fork 過多 worker → OOMKilled）。

### `console-configmap.yaml` — connect.sh + entrypoint.py + Flask app.py

- **`connect.sh`**：無限迴圈 `kubectl get pod -l <label>` 找 daemon → `kubectl exec -it <pod> -c open-design -- /bin/bash`；
  終端 `exit` 會 `Reconnecting in 2s...` 重連，**不會**掉出 console 本地 shell。
- **`entrypoint.py`**：容器 PID 1，同時起 ttyd + Flask 兩 process。**0.1.3 修正**：原本 `os.waitpid(-1, 0)` 等
  「任何」子程序，會收割 ttyd session 結束後被 re-parent 到 PID 1 的孤兒孫程序、誤判服務掛掉 → 整容器重啟；
  改成只監看 `{ttyd_pid, flask_pid}`，孤兒只 reap 不退出。
- **`app.py`**：Flask 管理儀表板（`/api/status`、`/api/logs`、`/api/restart`）。**目前無對外入口**
  （authproxy 沒有指向 :18790 的 location、daemon→console:18790 被 NP 擋）—— 見 platform doc Gap 3。

### `deployment.yaml` — `seed-home` initContainer（缺才補 dotfiles）

`od-home` PVC 掛在 `/home/opendesign` 會**蓋掉 image 內建的 home**，而 kubelet **不會**把 `/etc/skel`
重播進新磁碟 → 全新 instance 連 `~/.bashrc` 都沒有。而 console 網頁終端是
`kubectl exec -- /bin/bash`（**interactive non-login shell**，只讀 `/etc/bash.bashrc` + `~/.bashrc`），
所以 `~/.bashrc` 是租戶 shell 客製的唯一有效落點，必須存在。

`seed-home` initContainer（0.1.4 起）用 **daemon image 自己**（不引入額外 image / pull secret / egress）
以 **uid 1001** 掛同一顆 `od-home`，把 `homeSeed.files` 逐檔從 `/etc/skel` 複製進 home：

- **只在目標不存在時複製**（`[ -e "$dst" ]` 守衛）—— 租戶改過的 `.profile` 等**永不覆蓋**；
- **每次 pod 啟動都檢查**（不是首裝限定）—— 租戶誤刪的檔案下次重啟會補回來；
- **fail-soft**：腳本刻意不用 `set -e` 且結尾 `exit 0`；磁碟不可寫只印 `WARN`。少一個 dotfile 是外觀問題，
  但 initContainer 失敗會讓整個 instance CrashLoop。

驗證見 `tests/test-home-seed.sh` —— 除了 render 斷言，還會**把 render 出來的腳本抓出來實際執行**
（空 home 會建檔、既有檔不被蓋、刪掉的檔會補回、skel 缺檔與唯讀磁碟都不炸），因為文字級斷言抓不到
「複製 0 檔卻 exit 0」這類 runtime 缺陷（見 `charts/home-assistant` 的 busybox `cp -rn` 前案）。

## 關鍵 values（`values.yaml`）

| key | 說明 |
| --- | --- |
| `networkPolicy.apiServerCidrs` / `apiServerPorts` | console kubectl → apiserver 的 egress 白名單。**⚠ PLATFORM**：預設只有 ClusterIP `10.43.0.1/32`，但若叢集 CNI 在 **DNAT 之後**比對 egress（如 woow-k3s），需另加 control-plane node endpoint `<nodeIP>/32`，否則 console kubectl 全被擋、ttyd 內無限印 `Waiting for open-design pod to be ready...`。這是 cluster-specific 值、應由平台注入 —— 詳見 platform doc **Gap 1**（`#gap-1-console-連不到-apiserverpost-dnat`）。 |
| `console.enabled` | 是否部署 console（預設 true）。false → 只有 daemon。 |
| `console.externalPath` | ttyd 的對外子路徑（`/console`）。驅動 ttyd `-b` 與 nginx `/console` location。**升級既有 release 時有 `reuse_values` 陷阱**（新預設吃不到）—— 見 platform doc **Gap 2**。 |
| `config.allowedOrigins` | daemon 的瀏覽器 Origin 白名單。chart 不寫死，由平台部署時算租戶 URL 注入（daemon 對公開 Origin 只認 verbatim 白名單）。 |
| `authProxy.basicAuth` / `config.sensitive.admin_password` | C 案認證：authproxy 與 ttyd 共用租戶 `admin_password`（`#357` `has_admin_gui` 注入）；daemon 自身 API token 由 chart 自產、內部化。 |
| `persistence.*` / `resources.*` / `service.port` | 雙 PVC 尺寸、resource limits、daemon service port（7457）。 |
| `homeSeed.*` | 缺才補的 home dotfiles seed（`enabled` / `files` / `skelDir` / `runAsUser` / `image` / `resources`）。預設補 `.bashrc`、`.profile`、`.bash_logout`；`files` 覆寫是**整份取代**。`image: ""` → 沿用 daemon image。 |

## 版本史

| 版本 | 內容 | Ref |
| --- | --- | --- |
| 0.1.0 | 初版（daemon + console；C 案 auth：nginx auth-proxy sidecar + basic-auth 閘）| — |
| 0.1.1 | 修 daemon `OD_ALLOWED_ORIGINS=*` → `new URL('*')` 啟動崩潰；authproxy `worker_processes auto` 高核心 OOM | issue #47 / PR #48 |
| 0.1.2 | console 網頁終端對外入口 `/console`（auth-proxy 子路徑反代 ttyd）| issue #49 / PR #50（test 修 #51）|
| 0.1.3 | console entrypoint `os.waitpid(-1)` 孤兒誤殺修復（關終端不再重啟容器）| issue #52 / PR #53 |
| 0.1.4 | `seed-home` initContainer：把 `/etc/skel` 的 `.bashrc` / `.profile` / `.bash_logout` **缺才補**進 od-home PVC（空 home 沒有 `~/.bashrc`，租戶 shell 客製無處落地）| platform issue #407 |
| 0.2.0 | OpenDesign **0.24.1** image（上游預建 `ghcr.io/nexu-io/od` 為 base + Claude Code／OpenCode）；`authProxy.basicAuth.username` 開放租戶自改並於 render 時驗證（`open-design.basicAuthUsername`：1–64 字元 `A-Z a-z 0-9 . _ @ -`，含 `:`／空白／空值直接 fail render）；新增選填 `auth.openrouterApiKey` → Secret `OPENROUTER_API_KEY`（daemon env optional）。daemon 啟動參數不變（上游仍附 `apps/daemon/bin/od.mjs`）| paas-odoo-ci #151 |
| 0.2.1 | 帳號改放 chart Secret（`admin_username`），htpasswd init 與 console 都以 `secretKeyRef` 讀取。之前帳號以字面值寫在 pod 設定裡，改帳號＝改 pod 設定，operator 的 reset（`helm --atomic --timeout 15s`）要等新 pod（30–70 秒）必定逾時回退，且回退過程斷線約 1 分鐘；現在改帳號只動 Secret | — |

## 相關

- **platform 側安全模型 / 運作 / Known gaps**：[`opendesign-console.md`](https://git-prod.woowtech.io/odoo-addons/woow_paas_platform/src/branch/develop/docs/reference/features/opendesign-console.md)
- OpenDesign 上架全案（定價、C 案 auth、quota/origin/chart 修復鏈）：`woow_paas_platform` issue #380
- 發布方式（OCI + 傳統 Helm Repo）：見 repo 根 [`README.md`](../../README.md)
