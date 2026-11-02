# open-design

OpenDesign cloud service chart（daemon + console）。per-instance、ClusterIP、雙 RWO PVC、OCI 發布，
由 paas-operator 部署到 `paas-ws-*` 租戶 namespace。

## 0.5.8：選用 Paseo 原生 launcher

- `paseo.enabled` 預設關閉；啟用後在 daemon 容器內監督 Paseo app，與 stdio MCP 共用程序命名空間及既有 PVC。
- 同源 `/paseo/setup/` 經現有 Basic Auth；需要相容的固定 optional image。
- authproxy 一律使用 `map_hash_bucket_size 512`，使長 origin 在 Paseo 開啟或關閉時皆可啟動。
- 固定 image／chart digest、平台 prerelease 解析限制及驗收範圍見 [部署說明](PASEO-DEPLOYMENT.md)。平台修正前使用穩定版 chart SemVer。

> **安全模型 / 運作原理 / 威脅分析請看 platform 側的 canonical 文件**（本 README 只講 chart 實作，不重述）：
> [`woow_paas_platform` → `docs/reference/features/opendesign-console.md`](https://git-prod.woowtech.io/odoo-addons/woow_paas_platform/src/branch/develop/docs/reference/features/opendesign-console.md)
> —— 涵蓋端到端 `/console` 路由、ServiceAccount token（認證）vs Role（授權）、namespace-scoped blast radius、
> 「daemon 無憑證 / console 無互動入口 / NP 隔離」三道防線，以及三個 platform 側 Known gaps。

## Overview

一個部署由**一個 StatefulSet（daemon）＋一個 Deployment（console）/ 三個容器**組成：

| 元件 | 容器所在 | Port | 角色 | 模板 |
| --- | --- | --- | --- | --- |
| **daemon** | `<release>-open-design-0` pod | 7457（綁 loopback）| OpenDesign 本體，跑 AI agent CLI | `templates/statefulset.yaml` |
| **authproxy**（sidecar）| 同 daemon pod | 8080 | nginx basic-auth 閘 + 反向代理，對外唯一入口 | `templates/statefulset.yaml` + `auth-proxy-configmap.yaml` |
| **mcp**（sidecar，0.5.0，`mcp.enabled`）| 同 daemon pod | 8081（綁 loopback）| 內建 OpenDesign MCP server（HA add-on 同一套 runtime），uid 10001 | `templates/statefulset.yaml` |
| **console** | `<release>-open-design-console` pod | 7681（ttyd）/ 18790（Flask）| 網頁終端 + 管理儀表板 | `templates/console-deployment.yaml` + `console-configmap.yaml` |

- **PVC**：daemon 掛兩顆獨立 RWO PVC —— `od-data`（`/app/.od`, 8Gi）與 `od-home`（`/home/opendesign`, 2Gi，
  存 claude.ai 登入 session / agent CLI 設定）。見 `templates/pvc.yaml`。
- **StatefulSet（0.3.0，#1360）**：daemon 固定 1 個 replica、pod 名固定 `<fullname>-0`，console 的 RBAC 才能用
  resourceNames 只綁這一個 pod。`updateStrategy=RollingUpdate`（單 replica＝先刪舊 pod 再建新的，等同原本
  Recreate，RWO PVC 不會同時掛兩個 pod）、`podManagementPolicy=Parallel`（壞掉的 pod 不會卡住修正版升級）。
  PVC 仍是 `pvc.yaml` 的兩顆（不用 volumeClaimTemplates），名稱不變、資料保留。
- **從 0.2.x 升級**：helm 先建 StatefulSet 再刪舊 Deployment；daemon 的必要 podAntiAffinity 讓新 pod 不會排在
  舊 Deployment pod（帶 `pod-template-hash`）所在的 node，RWO PVC 要等舊 pod 結束才掛得上 ⇒ 兩個 daemon 不會
  同時寫 `/app/.od`。實際服務中斷約 1–2 分鐘（舊 pod 結束＋PVC 重新掛載），只在管理員 Redeploy 時發生一次。
- **對外**：預設 ClusterIP，平台走 Cloudflare tunnel 導流；`ingress.enabled` 可選啟用 in-chart Ingress。

## 流量走向（精簡）

```
瀏覽器 ──HTTPS──▶ authproxy（daemon pod sidecar :8080）
                    ├── location /          → 127.0.0.1:7457（daemon 本體，同 pod）
                    ├── location /console/  → console Service:7681（ttyd）
                    │                           └── ttyd 跑 connect.sh → kubectl exec 進 daemon 容器
                    │   （0.5.0，mcp.enabled）
                    ├── location = /mcp                 → 127.0.0.1:8081（mcp sidecar；Bearer，不經 basic-auth）
                    ├── location ~ /private_<token>/mcp → 127.0.0.1:8081（Claude.ai；不經 basic-auth、不記 log）
                    └── location /mcp-admin/            → unix:/run/od-mcp/admin.sock（basic-auth）
MCP 用戶端 ──HTTPS──┘                                       mcp sidecar ──loopback──▶ daemon 127.0.0.1:7457
```

完整端到端圖與訊號判讀（301 / 401 realm / 502 / `Waiting...` 各代表什麼）見上方 platform doc。

## 值得記錄的 templates

### `network-policy.yaml` — default-deny + 逐條 egress 洞

egress **絕不用** bare `- {}` allow-all（np-audit #42）。結構＝一條 default-deny（podSelector = release
`instance`）+ 逐 pod 開明確洞：

- **daemon egress**：DNS → kube-dns pod；daemon ↔ console:7681（給 `/console` 反代）；internet 443/80
  走**安全 ipBlock**（`0.0.0.0/0` 但 `except` 掉 cluster Pod/Service CIDR + RFC1918 + metadata + CGNAT +
  loopback）—— daemon 跑 agent CLI 需對外，但不得碰 in-cluster control-plane ClusterIP / SSRF metadata。
- **daemon pod → Omnigent**（0.2.2，`networkPolicy.omnigentEgress`）：同 namespace 的 **Omnigent server pod**
  （`app.kubernetes.io/name: omnigent`＋`app.kubernetes.io/component: server`，即 `charts/omnigent` 在 server pod
  上的標籤），只開 TCP 8000——daemon 容器裡的 Omnigent host 與 `/console/` 的 `omnigent login` 才能走叢集內網址。
  `omnigentHost.serverUrl` 是叢集內網址（`http://<release>-omnigent[.<本 ns>[.svc[.cluster.local]]]:<port>`）
  時再加 `app.kubernetes.io/instance: <release>`，只通那一個 Omnigent server。沒有 namespaceSelector、沒有
  ipBlock，不會打開整個 namespace 或 Service CIDR。只在 omnigentHost 開啟時出現；`--reuse-values` 從 0.2.1
  升級少了這段 values 也會用預設值產生。
- **console egress**：DNS → kube-dns；kube-apiserver via `networkPolicy.apiServerCidrs`（443/6443）。
- **ingress**：預設無 allow 規則（`ingressNamespaces: []`），CS-ns ingress 由 operator baseline NP 治理（#279/#280）。

### `console-rbac.yaml` — namespace `Role`（非 ClusterRole）

console 的 ServiceAccount（`serviceaccount.yaml`）綁一條 per-release 的 **`Role` + `RoleBinding`**：

| 資源 | verbs | resourceNames | 範圍 |
| --- | --- | --- | --- |
| `pods` | get | `<release>-open-design-0` | 只有 daemon pod |
| `pods/exec` | create, get | `<release>-open-design-0` | 只有 daemon pod |
| `pods/log` | get | `<release>-open-design-0` | 只有 daemon pod |
| `statefulsets` (apps) | get, patch | `<release>-open-design` | 只有自己那個 |

0.3.0 以前 daemon 是 Deployment（pod 名帶 hash 無法預綁），`pods/exec` 沒有 `resourceNames`，console SA 可以
exec 進同工作區**所有**服務的 pod（Odoo、PostgreSQL、n8n、其他服務的 token）—— platform #1360。0.3.0 起每一條
規則都綁名稱，沒有任何 list／watch；`tests/test-console-toggle.sh` 會擋任何沒有 resourceNames 的規則。

### `auth-proxy-configmap.yaml` — nginx 反代 + basic-auth 閘

- `location /`（預設）：basic-auth（`admin` + `admin_password`）→ `proxy_pass 127.0.0.1:7457`。
- `/api/health`、`/api/ready`、`/api/version`：`auth_basic off`（給 probe / CF health）。
- `location /console/`：`auth_basic off` + WebSocket upgrade header → `proxy_pass console:7681`（console pod 的 Basic 前端驗 `admin_password`；ttyd 本身只聽 pod 內 loopback，0.5.3 起）。
- 轉發給 daemon 與 ttyd 的 `Host` 是客戶端原樣的 `$http_host`（含 port；0.4.2，#1517），沒有 Host header 時才退回 `$host`。
  daemon 用 Host 比對 `config.allowedOrigins`，用 `$host` 會丟掉 port → 帶 port 的網址 `/api/app-config` 403、預設代理被清掉。
- `location = /console`：`absolute_redirect off` + `return 301 /console/`（否則 301 會洩漏內部 `http://host:8080`）。
- 主 `nginx.conf` **釘死 `worker_processes`**（nginx `auto` 非 cgroup-aware，高核心 node 會 fork 過多 worker → OOMKilled）。
- **`add_header Cache-Control "no-transform" always`**（server 層，0.2.2，PLAT-01）：請 Cloudflare 不要改寫回應。
  沒有這個 header 時，Cloudflare 的 Email Obfuscation／JS 偵測會改寫 HTML（email 變成 `[email protected]`
  並插入解碼 script），改壞的內容會進到匯出的獨立 HTML／ZIP，離線打開就壞掉。所有 location 都繼承這個
  header（location 不得自己寫 `add_header`，否則會蓋掉；`tests/test-auth-proxy.sh` 會擋）。

### `console-configmap.yaml` — connect.sh + entrypoint.py + Flask app.py

- **`connect.sh`**：無限迴圈等 `$DAEMON_POD`（固定名 `<fullname>-0`）Running → `kubectl exec -it <pod> -c open-design -- /bin/bash`；
  終端 `exit` 會 `Reconnecting in 2s...` 重連，**不會**掉出 console 本地 shell。
- **`entrypoint.py`**：容器 PID 1，同時起 ttyd + Flask 兩 process。**0.1.3 修正**：原本 `os.waitpid(-1, 0)` 等
  「任何」子程序，會收割 ttyd session 結束後被 re-parent 到 PID 1 的孤兒孫程序、誤判服務掛掉 → 整容器重啟；
  改成只監看 `{ttyd_pid, flask_pid}`，孤兒只 reap 不退出。
- **`app.py`**：Flask 管理儀表板（`/api/status`、`/api/logs`、`/api/restart`）。**目前無對外入口**
  （authproxy 沒有指向 :18790 的 location、daemon→console:18790 被 NP 擋）—— 見 platform doc Gap 3。

### `statefulset.yaml` — `seed-home` initContainer（缺才補 dotfiles）

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

### 原生 Omnigent 插件與舊版 host 套件

使用內含 `woow-omnigent` 的原生整合映像時，維持 **`omnigentHost.enabled: false`**。這個開關控制的是
舊版 chart supervisor；原生插件由 daemon 自行管理 host、私有持久化設定及啟停，不需要掛載舊版套件。
使用者從「外掛插件 → Omnigent → 設定」輸入 server 網址與帳密，選擇容器裡已存在的引擎並驗證對話。
新安裝不預填 server 或沿用其他 CLI 的登入，缺少的引擎不由插件自動安裝。

映像版本必須包含原生插件與已驗證 SDK；單獨升級 chart 不會替舊映像補裝它們。升級時明確傳入
`omnigentHost.enabled: false`，避免舊 release 的 `--reuse-values` 再啟用另一個 host manager。
原生插件關閉、重啟及重新連線由 daemon 管理，資料隨現有持久化 volume 保存。跨 namespace 的內部
server 仍須個別核准網路規則；插件安裝不會擴大 chart 的網路權限。

以下保留舊版 `omnigent-host-configmap.yaml` 套件的操作說明，僅供仍使用舊 supervisor 的映像。

讓 Omnigent 能在這台 OpenDesign 上開工作階段（Claude Code 用**租戶自己的登入**，透過 OpenDesign MCP 做簡報
／品牌素材，成品直接出現在 OD 介面）。launcher／supervisor／guard／helper／狀態訊息來自 repo 的**共用套件**
`shared/omnigent-host`（`scripts/sync-omnigent-host-kit.sh` 逐 byte 複製到 `files/omnigent-host/` 與
`templates/_omnigent-host.tpl`，`tests/test-omnigent-host-kit.sh` 以 sha256 比對）；行為細節見套件 README。

- **跟一般機器一樣，host 跑在產品容器裡**：沒有 sidecar、沒有多的容器。image 的 ENTRYPOINT 是
  `/sbin/tini -- /usr/local/bin/omnigent-host-entry`：tini 仍是 PID 1（收殭屍），stub 在 chart 掛了套件時以
  `omnigent-host-launch` 啟動 daemon，launcher 同時在背景（`setsid`）啟動 supervisor；沒掛套件
  （`omnigentHost.enabled=false`）或 image 沒有 omnigent CLI 時直接 `exec` daemon，和以前完全一樣。chart
  **不覆寫 `command`**，只覆寫 `args`（`enforceBindHost`）。supervisor 永遠不會擋住或弄掛 daemon。
- **停機順序**：SIGTERM → launcher 先停 supervisor（host 優雅結束，15 秒後對整個 process group SIGKILL），
  最多等 20 秒，再把 SIGTERM 傳給 daemon。`terminationGracePeriodSeconds` 預設 45（開啟時 render 不低於 45）。
- **資源**：daemon 維持**完整方案**（requests 1 vCPU／2Gi、limits 4 vCPU／8Gi，和平台釘的值一樣），host 與
  session 共用這個 cgroup，不另切預算。**OOM**：host 這棵行程樹 `oom_score_adj` 1000（session 繼承），比 daemon
  先被核心挑中；cgroup v2 下容器撞到上限時 kubelet 設的 `memory.oom.group=1` 會把整個容器一起殺，所以套件的
  memory guard 每 2 秒看一次容器 cgroup，工作集到上限 90% 就 SIGKILL host 樹裡 RSS 最大的 session 行程
  （絕不碰 daemon、host 本身、`/console/` 終端）。注意：session 透過 MCP `start_run` 叫 OD 自己跑的 agent
  run 是 **daemon 的子行程**，不在 host 樹裡，不受 guard 保護。
- **平台不碰 token**：只**等**租戶在 `/console/` 執行 `omnigent login <url>`（console 是 `kubectl exec` 進
  daemon 容器，`OMNIGENT_CONFIG_HOME`／`OMNIGENT_DATA_DIR`＝`/home/opendesign/.omnigent`，在 od-home PVC）。
  沒登入時 supervisor 只睡覺（檔案檢查、不起 python、不打網路）。**WOOW 預設用 Omnigent `admin` 帳號登入**
  （三台 host 的擁有者）；session 與 OD 自己的 agent run 都是同一個 uid，讀得到 token（見套件 README Accounts）。
- **已接受的風險：od-home 裡的 admin 登入憑證，OD 自己的 agent run 也讀得到。** 租戶在 `/console/` 用 admin
  登入後，`~/.omnigent/auth_tokens.json`（od-home PVC）存著 Omnigent **admin** 的 refresh grant，最長有效
  `grantMaxLifetimeDays`（charts/omnigent 目前預設 365 天）。Omnigent session 與 OpenDesign **自己的** agent run
  （聊天、`start_run`）都以同一個 uid 1001 執行，PATH 與 `OMNIGENT_*` env 也相同，所以都讀得到這個檔案，也能直接
  拿它呼叫 Omnigent。換句話說：任何能操作這台 OpenDesign 的人（包括被注入惡意指令的設計素材或網頁內容），都可能間接
  **以 Omnigent admin 的身分**操作 Omnigent（看所有 host、開 session、改設定）。這是使用者的決定（三台 host 都用 admin
  登入），**已列為接受的商業風險**，chart 不擋。降低風險的作法：改用專用帳號登入；把 charts/omnigent 的
  `grantMaxLifetimeDays` 縮短到 30–90 天（追蹤中）；要真正撤銷，請在 Omnigent 停用該帳號（`rm auth_tokens.json`
  只是本機登出，server 上的 grant 仍有效）。
- **身分**：已有 `host:` → 保留 host_id、只把名稱改成 `omnigentHost.hostName`（預設 `open-design · <release>`）；
  沒有 → 只寫名稱，host_id 由 omnigent 第一次啟動產生。pod 重啟後同一個 host_id 自動回來。
- **登入失效判定（套件）**：只有 server 明確的 401（token 未過期卻被拒、或 refresh 被拒）**連續兩次**才判定
  失效並停 host；5xx、連不上、逾時一律視為暫時故障，host 照跑。換帳號登入造成 409（exit 78）→ 指數退避，
  狀態顯示 `omnigent host reset-id --yes`。log 有大小上限與輪替；一個 volume 一個 host（flock）。
- **終端機**：`/console/` 的 bash 經 `/etc/bash/omnigent-host.sh`（＝套件的 `omnigent-host-profile.sh`；Alpine 的
  `/etc/bash/bashrc` 會 source `/etc/bash/*.sh`）把套件的 `bin` 放到 PATH 最前面，並執行
  `omnigent-host-status --motd`：只有需要租戶動手（尚未登入、登入失效、要 reset-id、host 異常…）時才印出繁中
  說明與確切指令。手動再跑一個 `omnigent host` 會被套件的 guard 擋下（「already running, managed
  automatically — see omnigent-host-status」）；`omnigent host status`、`login`、`reset-id` 照常可用。
- **serverUrl 是執行期資料**：`omnigentHost.serverUrl` 只 render 進 `<fullname>-omnigent-host-runtime`
  ConfigMap（以目錄掛載、不在 pod 的 checksum 裡），平台注入或改網址**不會重啟 pod**；supervisor 與
  `omnigent-host-status` 每次都重讀檔案。
- **遙測關閉**：daemon 容器帶 `OMNIGENT_ANALYTICS=0`、`DO_NOT_TRACK=1`、`DISABLE_TELEMETRY=1`（關掉 host 時也帶），
  config.yaml 另寫 `telemetry: false`。
- **工作目錄 seed**（`seedWorkspace`，`omnigentHost.workspace` 預設 `~/studio`）：`CLAUDE.md`（繁中美編守則、
  OD MCP 流程、chromium／python-pptx／pptxgenjs 匯出、OD 網址取 `config.allowedOrigins` 第一個）、`.mcp.json`
  （`node /app/apps/daemon/dist/cli.js mcp --daemon-url http://127.0.0.1:7457`，project 範圍，OD 自己的 run
  看不到）、`.claude/settings.json`（允許 `mcp__open-design`、封鎖 `delete_project`／`delete_file`——
  **盡力而為，不是安全邊界**：session 仍可用 shell 或直接打 loopback API）。以 manifest
  （`~/.omnigent/omnigent-host/workspace-seed.json`）記錄：租戶**刪掉的檔永不再放回**（opt-out）、改過的檔永不
  覆蓋；只有 `CLAUDE.md` 在租戶**沒改過**時會隨 chart 新版自動更新，改過就把新版放在
  `.omnigent-seed-updates/CLAUDE.md` 供參考。
- **安全設定**：daemon 是 uid 1001、`runAsNonRoot`、`allowPrivilegeEscalation: false`、
  `capabilities.drop: [ALL]`、`seccompProfile: RuntimeDefault`（預設值以 merge 方式套用，`--reuse-values` 帶著
  舊的 `securityContext: {}` 也一樣生效）；pod 加 `fsGroupChangePolicy: OnRootMismatch`；host 與 session 一律
  拿不到 `OD_API_TOKEN`。平台填的 LLM key（`auth.openrouterApiKey`／`auth.anthropicApiKey`）0.4.0 起**會**帶給
  host（#1440：只填 OpenRouter 時 OpenCode 可在這台機器上用、模型同 `agentDefaults.opencodeModel`；填了
  Anthropic key 時 Claude Code 也可用；租戶自己 `claude login` 照常）。`stripApiKeys: true` 回到 0.3.0 以前：
  連 LLM key 一起拿掉，只剩 `/console/` 的 `claude login` 可用。
- 驗證：`tests/test-omnigent-host-kit.sh`（套件 sha256、in-container 契約、pod 只有 daemon＋authproxy、完整方案
  資源、serverUrl 不改 pod、NetworkPolicy、`--reuse-values`、開關與 render 驗證、以 vendored `og_helper.py`
  實跑 seed manifest 規則）；套件本身的行為測試在 `shared/omnigent-host/tests/`。

## 同工作區 LiteLLM（0.4.1）

同一個工作區有執行中的 LiteLLM 服務時，平台把它的叢集內網址注入 `llmGateway.baseUrl`
（`http://<release>-litellm.<ns>.svc.cluster.local:4000/v1`）；**只帶網址、不帶金鑰**，租戶自己填的非空值優先。

- daemon 容器（`/console/` 終端機、Omnigent session 也繼承）拿到 env **`LITELLM_BASE_URL`**＝OpenAI 相容 base URL。不設定 `OPENAI_BASE_URL`／`ANTHROPIC_BASE_URL`，
  原本的 provider 設定不受影響。
- **金鑰租戶自己貼**：在 LiteLLM 後台（Virtual Keys）建虛擬金鑰（建議設預算、限定模型），貼到要用的工具自己的
  設定。平台不跨服務傳金鑰。實測：帶虛擬金鑰 `curl "$LITELLM_BASE_URL/models"` 回 200，不帶或錯誤金鑰回 401。
- **Claude Code**（已實測：LiteLLM chart 0.1.1／LiteLLM 1.103.3 的 Anthropic 相容 `/v1/messages`，含串流；
  Claude Code 2.1.284 在本 chart 的 daemon 容器內（＝`/console/` 終端機所在）走叢集內網址跑完 `claude -p`）：在 `/console/` 終端機
  ```sh
  ANTHROPIC_BASE_URL="${LITELLM_BASE_URL%/v1}" ANTHROPIC_AUTH_TOKEN=<虛擬金鑰> ANTHROPIC_API_KEY= \
  ANTHROPIC_MODEL=<LiteLLM 模型名> ANTHROPIC_DEFAULT_HAIKU_MODEL=<LiteLLM 模型名> claude
  ```
  `ANTHROPIC_BASE_URL` 要去掉 `/v1`（Claude Code 自己會接 `/v1/messages`）；模型名是 LiteLLM 裡的 model
  name，虛擬金鑰要允許該模型；`ANTHROPIC_API_KEY=` 清空，免得送出原本的 Anthropic 金鑰。
- **OpenDesign 自己的 agent**：`$LITELLM_BASE_URL` 是 OpenAI 相容 base URL，可填進支援 OpenAI 相容 provider 的設定
  （搭配虛擬金鑰；未另行實測各 agent 的設定畫面）。
- 網路：網址非空時 `networkPolicy.litellmEgress` 才開 daemon pod → 同 namespace LiteLLM proxy pod（`app.kubernetes.io/name: litellm`＋`component: app`）TCP 4000（比照 `omnigentEgress`；網際網路規則排除 10.0.0.0/8）；網址空時仍擋（沙盒實測）。
- 生效時機：網址放在不入 checksum 的 runtime ConfigMap `<fullname>-llm-gateway`（`envFrom`，optional），
  設定／變更／清空網址 pod template 都不變、不重啟 pod（平台密碼重設的 `helm upgrade --atomic --timeout 15s`
  不受影響）；env 在容器啟動時讀，執行中的容器要等下次重啟（重設密碼、重新部署）才看到新值。
- 不是 http(s) 的值會被略過（沒有 env、不開洞），不會讓 render 失敗。
- **SSRF 白名單（0.4.4，platform #1538）**：daemon 對租戶自填的 provider 網址有 SSRF 防護，解析到私網位址
  （叢集 ClusterIP 10.43.x.x）就回「Internal IPs blocked」——設定頁「測試連線」、模型清單、BYOK 對話三條全擋。
  網址有值時同一份 runtime ConfigMap 另帶 **`OD_ALLOWED_INTERNAL_HOSTS`＝該網址的主機名稱**（只放這一個 FQDN，
  不放 CIDR；租戶在 `config.extraConfig.OD_ALLOWED_INTERNAL_HOSTS` 自填的值會併在後面）。在 OpenDesign 設定頁
  「API 供應商」填的 base URL 要用 **`LITELLM_BASE_URL` 原樣**（同一個 FQDN；短名稱不在白名單）。
  `llmGateway.allowInternalHost=false` 可關（那就只能填 LiteLLM 的公開網址）。生效時機同上：LiteLLM 比 OpenDesign
  晚開通時，OpenDesign 要重新啟動一次才看得到。
- 測試：`tests/test-llm-gateway.sh`（只改網址時所有 workload byte-identical、envFrom、壞值、NetworkPolicy、
  `OD_ALLOWED_INTERNAL_HOSTS`）。

## 只允許本機的 daemon 路由（0.4.4，platform #1538）

上游 daemon 是桌面程式的設計：約 30 條路由掛 `requireLocalDaemonRequest`，要求連線端、`Host`、`Origin`（有帶時）
都是 loopback。auth-proxy 從 127.0.0.1 連 daemon（連線端會過），但轉送公開網址的 `Host`，所以在 PaaS 上
這些路由全部 403：Remix／建立副本（前端失敗時靜默退回只有提示詞的空專案）、即時產物預覽與重新整理、
設定 → 連接器（Composio 金鑰儲存、授權、取消、中斷）、匯出診斷日誌、實驗室 → Design Harness、素材庫
（配對、同步、刪除／套用素材）、記憶 → 連接器建議與擷取、代理元件安裝。

`authProxy.localRoutes.enabled`（預設 true）：

- 只有上面這些有網頁入口的路由走專屬 location：送 `Host: 127.0.0.1:<port>`、清掉 `Origin`，basic auth 照舊。
  用 `127.0.0.1` 不用 `localhost`：loopback 綁定時 daemon 把 `localhost:<port>` 當成 powered preview 的來源，
  一般 API 路由會被擋。
- 清掉 `Origin` 等於拿掉 daemon 自己的跨站檢查，所以 nginx 先檢查：沒有 `Origin`（同站 GET、CLI）或 `Origin`
  在 `config.allowedOrigins` 裡才放行，其他（別的網站、`null`）一律 403——跟 daemon 對其他 `/api` 路由的判斷相同。
- `/api/daemon/shutdown`、`/api/daemon/db/vacuum`（只有桌面版／CLI 用、有破壞性）在 nginx 直接 403，
  就算呼叫端自己偽造 loopback `Host` 也到不了 daemon。其他沒有網頁入口的路由（db verify、plugins events purge、
  applied-plugins export／prune、amr-terminal-reports）維持原狀（daemon 回 403）。
- 已知限制：Composio 的 OAuth 回呼網址由上游用 loopback `Host` 組成（`http://127.0.0.1:7457/api/connectors/oauth/callback`），
  使用者的瀏覽器回呼不到，OAuth 型連接器要等上游支援公開回呼網址；API key 型可用。
- 關掉（false）＝回到 0.4.3 的行為（這些路由 403）。
- 測試：`tests/test-auth-proxy.sh`（路由清單、Host／Origin 改寫、Origin 白名單、shutdown／vacuum 拒絕、開關）。

## 內建 OpenDesign MCP server（0.5.0，`mcp.*`）

取代另外訂閱的「Open Design MCP」（`mcp-opendesign` 範本）：MCP server 直接跑在 daemon pod 裡。
**runtime 就是 HA add-on 的那一套**（Woow MCP gateway＋vendored `opendesign_mcp_server`；image 由 paas-odoo-ci
`open-design/mcp-runtime` 以 commit 釘住 HA add-on 的 `mcp-runtime/`），兩邊工具數、預設與保護一致。

- **sidecar `mcp`**：與 daemon 同一個 image，`/opt/woow/bin/paas-opendesign-mcp`，uid／gid 10001（不是 daemon 的
  1001）、唯讀根檔案系統、drop ALL、沒有 secret、沒有 probe（pod 的 readiness 仍由 authproxy 決定，MCP 重啟不會讓
  OpenDesign 網頁下線）。只收三個設定：`WOOW_OD_BACKEND_URL`（daemon loopback）、`WOOW_OD_MCP_PORT`、
  `WOOW_OD_MCP_PUBLIC_ORIGIN`（`config.allowedOrigins` 的第一個 origin，用來預填管理頁的用戶端端點 `<origin>/mcp`）。
- **狀態**：od-data PVC 的 subPath `mcp.dataSubPath`（`.woow-mcp`）掛在 `/data/mcp`；runtime 把 token 與工具開關放在
  `/data/mcp/state`（0700、uid 10001）。daemon 容器看得到 `/app/.od/.woow-mcp` 這個目錄，但列不出、讀不到內容。
- **socket**：emptyDir `od-mcp-run`（Memory）只掛在 mcp 與 authproxy；`admin.sock` 的存取控制就是這個掛載。
- **對外網址**（同一個服務網址）：
  - `https://<服務網址>/mcp`＋`Authorization: Bearer <MCP 金鑰>`：Claude Code、Claude Desktop、其他代理。
  - `https://<服務網址>/private_<MCP 金鑰>/mcp`：Claude.ai 自訂連接器（不能帶 header）。路徑就是憑證：nginx 不記 log，
    錯誤或撤銷的金鑰一律 404。
  - `https://<服務網址>/mcp-admin/`：同一組帳號密碼登入；顯示／輪替／撤銷 MCP 金鑰、停用個別工具。
- **金鑰**：runtime 第一次啟動自己產生（方案 A），平台不經手、不顯示；Redeploy／升級保留（在 PVC 上）。
- **工具**：15 支預設全部開放（與 HA add-on 0.2.1 同一套，含會啟動 AI 代理的 `create_project`／`send_message`），
  可在 `/mcp-admin/` 停用個別工具。⚠ 沒有設定任何 AI 金鑰時，經 MCP 指定 `opencode` 代理的
  `create_project`／`send_message` 仍可能呼叫外部模型、產生外部用量（OpenCode 沒有憑證時用自己的免費模型；
  daemon 容器有網際網路 egress）。使用者 2026-10-15 決定照現狀全開，不另外限制。
- **⚠ Cloudflare Access**：MCP 與 OpenDesign 是同一個主機名稱。租戶若對這個主機名稱開 Cloudflare Access，外部 MCP
  用戶端（尤其 Claude.ai，無法完成 Access 登入）會被擋。請不要對這個服務開 Access，或自行為 `/mcp` 與
  `/private_*/mcp` 兩個路徑設 Access 例外（Bypass）。chart 與平台都不會改 Access 設定。
- **預設關**（`mcp.enabled: false`）：沒有 `/opt/woow` 的舊 image 會讓 sidecar CrashLoop，所以平台在**同一次**範本變更裡
  同時改釘含 runtime 的 image 與 `mcp.enabled: true`。`--reuse-values` 從 0.4.x 升級（values 裡沒有 `mcp`）視為關閉。
- **quota**：平台方案的 memory limits 合計 8Gi（daemon）＋128Mi（authproxy）＋320Mi（mcp）＋512Mi（console）＝9,152Mi，
  平台範本 `min_ram_gb` 3.5 ⇒ 單台 Open Design 的工作區 quota 是 10Gi（int(3.5×3)），留 1Gi 餘裕；`tests/test-mcp.sh`
  用更嚴的 9Gi 守住。

## 關鍵 values（`values.yaml`）

| key | 說明 |
| --- | --- |
| `networkPolicy.apiServerCidrs` / `apiServerPorts` | console kubectl → apiserver 的 egress 白名單。**⚠ PLATFORM**：預設只有 ClusterIP `10.43.0.1/32`，但若叢集 CNI 在 **DNAT 之後**比對 egress（如 woow-k3s），需另加 control-plane node endpoint `<nodeIP>/32`，否則 console kubectl 全被擋、ttyd 內無限印 `Waiting for open-design pod to be ready...`。這是 cluster-specific 值、應由平台注入 —— 詳見 platform doc **Gap 1**（`#gap-1-console-連不到-apiserverpost-dnat`）。 |
| `console.enabled` | 是否部署 console（預設 true）。false → 只有 daemon。 |
| `console.externalPath` | ttyd 的對外子路徑（`/console`）。驅動 ttyd `-b` 與 nginx `/console` location。**升級既有 release 時有 `reuse_values` 陷阱**（新預設吃不到）—— 見 platform doc **Gap 2**。 |
| `config.allowedOrigins` | daemon 的瀏覽器 Origin 白名單。chart 不寫死，由平台部署時算租戶 URL 注入（daemon 對公開 Origin 只認 verbatim 白名單）。 |
| `authProxy.basicAuth` / `config.sensitive.admin_password` | C 案認證：authproxy 與 ttyd 共用租戶 `admin_password`（`#357` `has_admin_gui` 注入）；daemon 自身 API token 由 chart 自產、內部化。 |
| `persistence.*` / `resources.*` / `service.port` | 雙 PVC 尺寸、daemon resources（完整方案，Omnigent host 共用）、daemon service port（7457）。 |
| `omnigentHost.*` | 舊版 chart host supervisor，預設關閉。原生 `woow-omnigent` 插件須維持 `enabled: false`，由 daemon 管理 GUI 設定及 host。其餘 `serverUrl`、`hostName`、`workspace`、`watchSeconds`、`seedWorkspace`、`stripApiKeys` 僅用於舊版套件。 |
| `console.runAsUser` / `console.securityContext` | （0.5.1）console 容器預設非 root（uid 10002）、drop ALL、禁提權、RuntimeDefault seccomp、唯讀根檔案系統（`/app`、`/tmp` 為 emptyDir，`HOME=/tmp`）；只套用 baked image，`console.runtimeInstall=true`（啟動時 apt／pip，需要 root）維持舊規格。`console.securityContext` 逐 key 覆寫預設。ttyd 內 `kubectl exec` 進 daemon 後的 shell 仍是 daemon 的 uid 1001。 |
| `authProxy.securityContext` | （0.5.1）nginx sidecar 與 htpasswd init：uid 101、非 root、drop ALL、禁提權、RuntimeDefault（根檔案系統維持可寫：nginx 暫存在 `/tmp`）。pod 層另預設 seccomp `RuntimeDefault`（`podSecurityContext` 缺這個 key 時由 template 補，`--reuse-values` 也吃得到）。 |
| `runsPrune.*` | （0.5.1）`prune-runs` initContainer（預設開，`dryRun` 只記錄不刪）：daemon 不會刪的 run 紀錄（`/app/.od/runs/<id>/state.json`，含使用者提示詞）在專案已不存在時，於下次啟動前清掉。只在「專案不在資料庫（`projects`／`workspace_projects`）**且** `projects/<id>` 目錄不存在」時刪；任何疑問（無資料庫、讀不到表、無 projectId、非一般目錄名、symlink）一律不動；只印數量。專案在 pod 運行中被刪時，紀錄仍可讀到下次啟動——根治要靠上游 daemon（刪專案連帶清 run）。 |
| `securityContext` | daemon 容器（含 agent-defaults／prune-runs init 容器）安全設定；預設加固值（uid 1001、非 root、drop ALL、禁提權、RuntimeDefault）逐 key 被覆寫，明確給值者優先，`false` 也算（0.5.5 起；之前 sprig merge 會忽略 `false`）。 |
| `networkPolicy.omnigentEgress` | daemon pod → 同 namespace Omnigent server pod（`podLabels`、`ports`，預設 `app.kubernetes.io/name: omnigent`＋`component: server`、8000；`serverUrl` 是叢集內網址時再釘 instance）。 |
| `agentDefaults.*` | 開箱可用的預設代理（#1437／#1438）：`defaultAgent`（`auto`＝有 Anthropic key 或 `claude login` → claude，否則有 OpenRouter key → opencode；`keep`＝不動）、`opencodeModel`（OpenCode「Default (CLI config)」釘的模型，預設 `openrouter/openai/gpt-5-mini`，必須支援 tool call；平台可逐服務覆寫）。`agent-defaults` initContainer 每次啟動執行 `files/agent-defaults.py`：只看 key **有沒有設**、不印不存；租戶自己選的代理、自己改過的 `opencode.jsonc` 永不覆蓋；未設定、`amr`（OpenDesign Cloud，本服務沒裝）、沒登入的 `claude`、或仍是 chart 上次設的值才換；全新服務同時略過上游首次引導頁（主按鈕是 OpenDesign Cloud 註冊）。 |
| `whiteLabel.supportUrl` | 白牌（#1439）：auth-proxy 以 302 回應同站路徑 `/_woow/support`（image 的「聯絡我們」與殘留社群連結指到這裡），預設 `https://aiot.woowtech.io/woow`；只接受不含空白／引號／`$`／`;` 的 http(s) 網址。 |
| `resources.*.ephemeral-storage` | 每個容器（含 init、console、authproxy）都有 ephemeral-storage request／limit（#1434）；daemon 1Gi／4Gi。超過時 kubelet 只驅逐這個 pod（PVC 資料保留），不會把節點系統碟寫滿。平台 helm_default_values 只釘 cpu／memory，Helm 會合併 map，這些 key 仍在。 |
| `homeSeed.*` | 缺才補的 home dotfiles seed（`enabled` / `files` / `skelDir` / `runAsUser` / `image` / `resources`）。預設補 `.bashrc`、`.profile`、`.bash_logout`；`files` 覆寫是**整份取代**。`image: ""` → 沿用 daemon image。 |
| `llmGateway.baseUrl` / `networkPolicy.litellmEgress` | 同工作區 LiteLLM 網址（平台注入、只帶網址）→ daemon env `LITELLM_BASE_URL`（runtime ConfigMap，不重啟 pod）；非空時開 daemon → 同 ns LiteLLM proxy pod TCP 4000。見「同工作區 LiteLLM」。 |
| `llmGateway.allowInternalHost` | （0.4.4）預設 true：網址有值時 runtime ConfigMap 另帶 `OD_ALLOWED_INTERNAL_HOSTS`＝網址主機名稱，daemon 的 SSRF 防護放行這一個 FQDN。 |
| `mcp.*` | （0.5.0）內建 MCP server：`enabled`（預設 false，平台與含 runtime 的 image 一起開）、`port`（8081，1024–65535，不可與 daemon／authproxy 同埠）、`dataSubPath`（`.woow-mcp`，單一目錄名）、`runAsUser`／`runAsGroup`（10001）、`resources`（50m／160Mi → 500m／320Mi）。見「內建 OpenDesign MCP server」。 |
| `authProxy.localRoutes.enabled` | （0.4.4）預設 true：只允許本機的 daemon 路由（網頁會用到的那幾條）經 auth-proxy 改送 loopback `Host`、清 `Origin`（nginx 先驗 `Origin`）；shutdown／vacuum 一律 403。見「只允許本機的 daemon 路由」。 |

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
| 0.2.2 | **Omnigent host 跑在 daemon 容器裡**（`omnigentHost.*`，預設開，共用套件 `shared/omnigent-host`；沒有 sidecar）：image ENTRYPOINT tini → `omnigent-host-entry` 以套件 launcher 啟動 daemon＋背景 supervisor；租戶在 `/console/` `omnigent login` 後自動連上 Omnigent、重啟自動回來（同 host id）、只有明確撤銷才停、手動第二個 host 被擋；daemon 維持完整方案資源，host 樹 `oom_score_adj` 1000＋memory guard 先殺 session；`serverUrl` 只進執行期 ConfigMap（不重啟 pod）；`/console/` 顯示需要動手時的狀態與指令；seed `~/studio`（manifest：刪掉不放回、改過不覆蓋、CLAUDE.md 沒改過才更新）；daemon 加固 securityContext、`fsGroupChangePolicy: OnRootMismatch`、遙測 env 關閉；`networkPolicy.omnigentEgress` 開 daemon pod → 同 ns Omnigent server :8000。需含 omnigent CLI＋`omnigent-host-entry` 的 image（舊 image：daemon 照舊、沒有 host）；auth-proxy 加 `Cache-Control: no-transform`（PLAT-01：Cloudflare 不再改寫 HTML／email）| paas-odoo-ci `feat/open-design-omnigent` |
| 0.3.0 | **daemon 改 StatefulSet**（pod 固定 `<fullname>-0`），console Role 的 `pods`／`pods/exec`／`pods/log` 全部以 resourceNames 綁這一個 pod、restart 改 `statefulsets` patch、拿掉所有 list —— console 不能再 exec 進同工作區其他服務；console 直接用 `DAEMON_POD`（拿掉 `POD_LABEL`／`DAEMON_DEPLOYMENT`／`DAEMON_SERVICE`）；auth-proxy htpasswd 改成 chart Secret 的 `htpasswd` key 以 Secret volume 掛載（nginx 每個請求都重讀，平台重設密碼不必重啟 daemon，約 1 分鐘內生效；`auth.existingSecret` 模式維持 initContainer）；升級時用 podAntiAffinity 避免新舊 daemon 同時掛同一組 PVC | platform #1360 |
| 0.4.0 | R8 商用驗收修正：`agent-defaults` initContainer（只填 OpenRouter → 預設 OpenCode＋釘死模型 `openrouter/openai/gpt-5-mini`；有 Anthropic key／`claude login` → Claude；不可用的 `claude`／`amr` 自動換掉、租戶自選保留；全新服務略過上游 Cloud 註冊引導頁）；`checksum/api-keys`：改 OpenRouter／Anthropic key 會滾動重啟 daemon（改密碼不會）；所有容器加 ephemeral-storage；Omnigent host 拿得到平台填的 LLM key（`stripApiKeys` 預設改 false，`OD_API_TOKEN` 照樣拿掉）；auth-proxy `/_woow/support` → `whiteLabel.supportUrl`（搭配 paas-odoo-ci 白牌 patch）。從 0.3.0 升級 daemon 重啟一次，PVC 上的專案與登入保留 | platform #1434 #1435 #1437 #1438 #1439 #1440 |
| 0.4.1 | 同工作區 LiteLLM 串接：`llmGateway.baseUrl` → daemon env `LITELLM_BASE_URL`（不入 checksum 的 runtime ConfigMap，改網址 pod template 不變）；網址非空才開 daemon → 同 ns LiteLLM proxy TCP 4000（`networkPolicy.litellmEgress`）。接在 charts #132 的 0.4.0 之後 | — |
| 0.4.2 | auth-proxy 轉發的 `Host` 由 `$host` 改成客戶端原樣的 `$http_host`（保留 port；沒有 Host header 才退回 `$host`）。修正網址帶 port（`allowedOrigins` 也帶同一個 port）時 `/api/app-config` 403、前端把預設代理 `agentId` 清成 null。平台 https 網址無 port，行為不變；升級時 daemon pod 重啟一次（auth-proxy ConfigMap checksum） | platform #1517 |
| 0.4.3 | 工作區＝區網：同 namespace egress／ingress 全埠全通，網際網路規則排除多播與 240/4 | platform #1441 #1436 |
| 0.5.0 | **內建 OpenDesign MCP server**（`mcp.*`，預設關、平台開）：daemon pod 加 `mcp` sidecar（同 image，uid 10001，唯讀根檔案系統，HA add-on 同一套 runtime）；auth-proxy 新增 `/mcp`（Bearer）、`/private_<token>/mcp`（Claude.ai，不記 log）兩條不經 basic-auth 的路徑與 basic-auth 後的 `/mcp-admin/`（admin.sock，`X-Remote-User-Id`＝`$remote_user`）；狀態在 od-data subPath；`od-mcp-run` emptyDir 只掛 mcp 與 authproxy。取代 `mcp-opendesign` 範本。**`omnigentHost.enabled` 預設改 false**（Omnigent 暫停：不 render 套件 ConfigMap、`OG_*` env、掛載、NetworkPolicy 洞；平台另明確傳 false，因 `--reuse-values` 缺 key 時套件視為開啟）。升級時 daemon pod 重啟一次（PVC 資料保留） | platform od-mcp-merge |
| 0.4.4 | 只允許本機的 daemon 路由（Remix、即時預覽、Composio 金鑰、診斷匯出、Design Harness、素材庫、記憶連接器）經 auth-proxy 改送 `Host: 127.0.0.1:<port>`＋清 `Origin`（nginx 先驗 `Origin`、basic auth 照舊，`authProxy.localRoutes`），shutdown／vacuum 一律 403；`llmGateway.baseUrl` 有值時 runtime ConfigMap 加 `OD_ALLOWED_INTERNAL_HOSTS`＝LiteLLM 主機名稱（`llmGateway.allowInternalHost`）。升級時 daemon pod 重啟一次 | platform #1538 |
| 0.5.3 | console 網頁終端的帳密不再進 argv／log：ttyd 改聽 pod 內 loopback（`-i lo`、`CONSOLE_TTYD_INTERNAL_PORT`，預設 7682）並用每次開機隨機產生的帳密；對外 7681 由 entrypoint 內的 Basic 前端（`entrypoint.py authfront`）驗 `admin_password`（從環境變數讀）再轉給 ttyd。Service／NetworkPolicy／auth-proxy 不變。console Role 拿掉 `secrets` get/patch/update（console 沒有任何程式用到）。升級時 console 重建一次（ConfigMap checksum）；daemon 不受影響 | console-ttyd-exposure（AI-HER-006-4、X-SEC-002-1、X-SEC-005-4） |
| 0.5.4 | auth-proxy 的 access log 不再記查詢字串與 MCP token：`log_format main` 的 `"$request"` 改成 `$request_method $woow_log_path`（原始路徑、去掉 `?` 之後、`/private_<token>` 段遮成 `/private_<redacted>`），Referer 只留 `?` 之前；`/mcp` 與 `/private_<token>/mcp` 的 `error_log /dev/null`（nginx 在 upstream 出錯時會把原始 request 行連 token 一起寫進 error log，mcp 容器自己有錯誤 log）。`tests/test-log-redaction.sh` 用真的 nginx 驗證，含對照組。升級時 daemon pod 重啟一次（auth-proxy ConfigMap checksum） | sensitive-data-in-logs（X-SEC-002） |
| 0.5.5 | daemon 容器（與同一 helper 的 agent-defaults／prune-runs init 容器）的 securityContext 改成逐 key 覆寫預設值，與 0.5.1 起的 console／auth-proxy 相同。原本用 sprig `merge`，`false` 會被當成空值：`securityContext.runAsNonRoot: false` 等「預設為 true 的鍵改成 false」會被忽略、仍渲染預設。預設 values 的渲染結果除了 `helm.sh/chart` label 以外與 0.5.4 相同（升級時 pod 照常因 chart label 重啟一次，資料保留、不改資源） | AI-FIX-OD-1-1 |
| 0.5.1 | 商用驗收 AI-OD 修補：console 容器改非 root（uid 10002、drop ALL、禁提權、RuntimeDefault、唯讀根檔案系統）；auth-proxy 與其 init 加 securityContext（uid 101、drop ALL、禁提權、RuntimeDefault）；pod 層預設 seccomp RuntimeDefault；`prune-runs` initContainer 清掉專案已刪除的 run 紀錄（含提示詞）；agent-defaults：清除 OpenRouter key 後預設代理由 opencode 還原為 claude。升級時 daemon pod 重啟一次、console 重建一次（資料保留），不新增 PVC、不改資源，ResourceQuota 不受影響 | AI-OD-007-4 / -6、AI-OD-004-1 |
| 0.5.6 | daemon pod（runtimeInstall 時含 console）帶 `paas.woowtech.io/egress-profile=web`（`networkPolicy.egressProfile`）：operator 開 web profile 後公網只剩 TCP 80/443，chart 的 80/443 限制才生效 | 商用驗收 egress-all-ports-open／woow_paas_platform #1802 |

## 已知限制（上游行為，非 chart 可修）

- **網頁版「Export as PDF」「Export as PPTX」一律 501**（`/api/projects/<id>/export/{pdf,pptx,pdf-image}` 回 `desktop … only available in the desktop runtime`）：UI 只顯示「Exporting… N s」約一分鐘後無聲消失。HTML／ZIP 匯出正常。這是 nexu-io/open-design 的桌面版功能，雲端沒有對應 runtime；請改用 HTML／ZIP，或在瀏覽器自行列印。上游待修（網頁版隱藏選項、501 顯示明確訊息）。
- **刪除專案不會清其 run 紀錄**：見 `runsPrune.*`；pod 運行中仍可經 `GET /api/runs/<id>` 讀到，下次啟動才清。
- **單一共用登入**：服務只有一組管理員帳密（basic-auth 與 `/console/` 共用），沒有個人帳號；多人使用請共用該帳密，平台側權限由工作區角色管理。
- **資料碟寫滿**時上傳回 `500 INTERNAL_ERROR upload failed`（daemon 不分辨 ENOSPC）。
- **`/app/.od/.woow-mcp` 在 od-data PVC 內**：fsGroup 讓 agent 的 uid 1001 對該磁碟區根目錄有寫入權，理論上可置換 MCP 的 state 目錄（需 mcp 容器重啟才會讀到）。根治要把 MCP state 放獨立 PVC（改磁碟區拓撲，須另案決定）；目前以 state 目錄 0700／uid 10001 保護內容。mcp runtime 啟動時拒用不屬於 uid 10001 的 state 目錄（`paas-opendesign-mcp` check_data），所以被置換時只會讓 MCP 起不來或重新產生 token（可用性），不會讀到或沿用別人放的 token／工具開關。chart 內收緊無效：`.woow-mcp` 本身改權限擋不住對上層目錄的改名，對上層加 sticky bit 需要 root init 容器。

## 相關

- **platform 側安全模型 / 運作 / Known gaps**：[`opendesign-console.md`](https://git-prod.woowtech.io/odoo-addons/woow_paas_platform/src/branch/develop/docs/reference/features/opendesign-console.md)
- OpenDesign 上架全案（定價、C 案 auth、quota/origin/chart 修復鏈）：`woow_paas_platform` issue #380
- 發布方式（OCI + 傳統 Helm Repo）：見 repo 根 [`README.md`](../../README.md)
