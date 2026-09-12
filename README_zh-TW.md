# Woow k3s OpenDesign

在 `woow-k3s` 叢集上執行的 OpenDesign **0.21.1**：一個容器映像與一份 Helm
chart，安裝到**既有的** `pi-agent-woow` namespace，並透過叢集現有的 Nginx
Proxy Manager（NPM）對外發佈——與五套 `pi-agent` 完全相同的拓撲。

[English](README.md) · [維運手冊](DOCS.md) · [變更記錄](CHANGELOG.md) · [1.x 遷移與金鑰輪替](docs/MIGRATION.md)

> **2.0.0 是重寫，不是升級。** 本倉庫的 1.0.0 chart 根本裝不起來：`nodeSelector`
> 帶著字面量佔位符 `__K3S_NODE_HOSTNAME__`，`helm install` 會被 API server 拒絕；
> 映像指向 `localhost/*` 且 `pullPolicy: Never`；`values.yaml` 裡直接提交了真實憑證。
> console 與 MCP 兩個元件已整個移除。動任何既有部署之前請先讀
> [docs/MIGRATION.md](docs/MIGRATION.md)——**1.x `values.yaml` 內的憑證已經在公開的
> git 歷史裡，必須輪替。**

## 這份 chart 部署什麼

在 namespace `pi-agent-woow` 內，一個 Pod、兩個容器：

| 物件 | 名稱 | 用途 |
|---|---|---|
| Deployment | `<release>` | `opendesign` 容器（OD daemon，僅 loopback）＋ `nginx` sidecar（對 Pod 網路的唯一監聽點） |
| Service | `<release>` | ClusterIP `:7457`，NPM 唯一轉發目標。**不可**改成 NodePort／LoadBalancer。 |
| ConfigMap | `<release>-config` | OD 環境變數，不含任何密文。 |
| ConfigMap | `<release>-nginx` | sidecar 的 `nginx.conf` 與 `od-export-bridge.js`，以 checksum annotation 綁定，改動即滾動 Pod。 |
| PersistentVolumeClaim | `<release>-data` | 20Gi `longhorn`（Retain）＋`helm.sh/resource-policy: keep`，掛在 `/data/opendesign`。 |
| PersistentVolumeClaim | `<release>-backup` | 20Gi `longhorn`，僅在 `backup.enabled`（預設開啟）時建立。 |
| NetworkPolicy | `<release>` | Ingress：僅 `app=npm` 的 Pod 與 `192.168.0.0/16`，僅 7457 埠。Egress：kube-dns，之後排除 Pod／Service／LAN／metadata 網段。 |
| CronJob | `<release>-backup` | 每晚把資料 PVC 打包成 `tar.gz` 寫入備份 PVC，依 `backup.retain` 保留份數。 |

**沒有** Namespace、**沒有** Secret、**沒有** ServiceAccount、**沒有** Role／
RoleBinding，也**沒有** `nodeSelector`。

## 架構

```text
瀏覽器
  └─ Cloudflare  ──► deployment/pi-tunnel-cloudflared  (ns pi-agent-woow)
                       └─ http://npm.pi-agent-woow.svc.cluster.local:80
                            └─ NPM proxy host  ◄── 認證邊界（Access List／basic auth）
                                 └─ service/<release>:7457
                                      └─ nginx sidecar :7457   (不做認證、不改路徑)
                                           └─ 127.0.0.1:7456   OD daemon
                                                ├─ /data/opendesign        (Longhorn RWO)
                                                └─ 系統 Chromium + playwright-core 1.55.0
```

OD daemon 綁在 `127.0.0.1`，**在 Pod 網路上完全無法連到**。這是刻意的：OD 若綁在
非 loopback 位址，就必須設 API token 或 `OD_DISABLE_API_AUTH=1` 才肯啟動，而 1.x
chart 選了後者。維持 loopback 代表這道安全底線被「遵守」而不是被「關掉」，也代表
任何 NetworkPolicy 規則都不需要（也不可能）提到 7456 埠。

nginx sidecar 的存在只有兩個理由：終結 Pod 網路連線，並把 `Host` 正規化成 OD 接受
的 loopback 形式。它**不做認證**、**不改路徑**、**不清空 `Origin`**。它唯一會改動
內容的地方，是在 `<head>` 注入 `<script src="/od-export-bridge.js">`，把 UI 的 PDF
按鈕從桌面版專用的 `/export/pdf` 導到二進位的 `/export/pdf-image`。

## 前置條件

除另註明外，均於 2026-09-09 在 `woow-k3s` 上實際查證。

| 需求 | 狀態 |
|---|---|
| Kubernetes ≥ 1.24 | Server 為 `v1.34.5+k3s1` |
| namespace `pi-agent-woow` 已存在（Rancher 管理，chart 不建立） | 已存在 |
| `longhorn` StorageClass、`Retain`、可擴容 | 已存在（`driver.longhorn.io`，RECLAIMPOLICY `Retain`，ALLOWVOLUMEEXPANSION `true`） |
| `pi-agent-woow` 內有 `service/npm`，埠 80／81 | 已存在，ClusterIP `10.43.65.207` |
| `deployment/pi-tunnel-cloudflared` 位於 NPM 前方 | 已存在 |
| 所有節點皆為 `amd64`（映像只出 amd64） | 4／4 節點皆為 `amd64` |
| Helm ≥ 3.8（支援 OCI） | 用戶端條件 |
| OpenDesign 的公開網域與 Cloudflare DNS／tunnel 路由 | **尚未建立。** 必須由維運人員先選名並建立，見下方 |
| `ghcr.io/woowtech/woow-k3s-opendesign` 已發佈且為公開 | 已發佈 `2.0.1`，可匿名拉取（與 `woow-k3s-pi-agent` 相同）。OCI chart 為 `oci://ghcr.io/woowtech/charts/opendesign:2.0.1` |

> 本叢集有**兩個** StorageClass 被標為預設（`local-path` 與 `longhorn`）。PVC 若
> 省略 `storageClassName`，選誰由不確定的 tiebreak 決定。因此本 chart 每一個 PVC
> 都明寫 class，`tests/validate.py` 會在漏寫時讓建置失敗。

## 安裝

chart 位於 `chart/`，安裝進既有 namespace，且不含任何密文。

```bash
# 1. 你的 values。publicUrl 必須設定：chart 預設值是一個 example.com 網域，
#    好讓「什麼都不給」也能渲染；而它對不上任何真實瀏覽器來源，所以忘了改
#    會直接壞掉（fail closed），不會變成什麼都信任。
cat > od-values.yaml <<'YAML'
publicUrl: "https://od-woow-k3s.woowtech.io"   # 你在 Cloudflare + NPM 建立的網域
image:
  digest: "sha256:..."                          # 取自發佈作業摘要；建議設定
YAML

# 2. 從 clone 安裝
helm -n pi-agent-woow install od ./chart -f od-values.yaml

# 3. 或直接從 GHCR 安裝，不必 checkout
helm -n pi-agent-woow install od \
  oci://ghcr.io/woowtech/charts/opendesign --version 2.0.1 -f od-values.yaml

# 4. 或從 GitHub 原始碼 tarball 安裝（適合離線審查流程）
curl -fsSL https://github.com/WOOWTECH/Woow_k3s_opendesign/archive/refs/tags/v2.0.1.tar.gz \
  | tar -xz
helm -n pi-agent-woow install od ./Woow_k3s_opendesign-2.0.1/chart -f od-values.yaml
```

第 3、4 種方式的版本必須是 GHCR 上真的存在的版本。`image.tag` 預設等於 chart 版本，
所以尚未打 tag 發佈的 chart 版本不會有對應映像：這種情況請改釘 `image.digest`
（或 `image.tag`）。

安裝前務必先渲染並做伺服器端 dry-run：

```bash
helm -n pi-agent-woow template od ./chart -f od-values.yaml | \
  kubectl --context woow-k3s -n pi-agent-woow apply --dry-run=server -f -
```

`--dry-run=server` 正是能在 1.x 時代就抓到那個佔位符錯誤的檢查。請照做；也請絕對
不要直接 `apply` 渲染結果——chart 是唯一的寫入者。

### 驗證

```bash
kubectl -n pi-agent-woow rollout status deploy/od
helm -n pi-agent-woow test od          # 唯讀：經 Service 打兩個 GET
```

`helm test` 會起一個短命 Pod，經 Service 對 `/api/health` 與 `/api/version` 各發一個
GET——與 NPM 走的是同一條路，所以通過就代表 Service → sidecar `:7457` →
`127.0.0.1:7456` → daemon 整條鏈是通的。它不掛任何 volume、不寫任何東西。這個 hook
Pod **刻意不帶** chart 的 selector 標籤：帶了就會被算進 Service 的 EndpointSlice，
在它存活期間吃掉一部分真實流量。

`networkPolicy.enabled: true` 時，hook 還需要 `networkPolicy.allowHelmTest: true`；
它只會在 7457 埠多加一個 ingress 來源（本 release 的 hook Pod），不動任何 pod template。

每個 GET 都會重試（`helmTest.retries`，預設 15 次、間隔 2 秒）。這不是湊數：hook Pod
在執行前幾秒才被建立，而放行它的 NetworkPolicy 是以「Pod IP 的 ipset」實作的，policy
controller 需要時間學到這個 IP；太早連線會被 reject，症狀看起來就跟 Service 壞掉一模
一樣。實測只試一次的話，連續執行 `helm test` 大約有一半會失敗。

hook Pod 在跑完後會留著（`helm.sh/hook-delete-policy: before-hook-creation`），所以
`kubectl -n pi-agent-woow logs od-test-connection` 還看得到它當時看到什麼；下一次
`helm test` 會把它換掉。

**解除安裝不會刪資料。** `keepOnUninstall: true`（預設）會讓兩個 PVC——以及由 chart
建立的 extra-env Secret——都帶上 `helm.sh/resource-policy: keep`，且位於 `Retain` 的
StorageClass 上。

## 對外發佈（chart 範圍外，由維運人員執行）

chart 刻意不管 `pi-agent-woow` 以外的任何東西。以下兩步是你的責任：

1. **cloudflared**：把 OpenDesign 網域加進 `pi-tunnel` release 的 ingress 清單，
   指向 `http://npm.pi-agent-woow.svc.cluster.local:80`，然後
   `helm upgrade pi-tunnel`。
   **絕對不要 `kubectl patch` 那個 `pi-tunnel-cloudflared` ConfigMap。** 該
   ConfigMap 過去曾被手工附加過 Helm 不知情的網域，下一次 `helm upgrade` 就會把
   那些公開網域打成 404；它自己的註解就記著這件事。
2. **NPM**（`https://pi-agent-npm.woowtech.io`，即 npm:81）→ *Hosts → Proxy Hosts
   → Add*：
   - Domain Names：你的 OpenDesign 網域
   - Scheme `http`，Forward Hostname `<release>.pi-agent-woow.svc.cluster.local`，
     Forward Port `7457`
   - **Websockets Support：開啟**（OD 需要串流）、Block Common Exploits：開啟
   - **Access List：沿用 `pi-agent` 系列使用的同一份 basic auth 清單**——這就是認證邊界
   - SSL：比照相鄰主機申請／掛載憑證

`npm` 的 Deployment、Service、NetworkPolicy 都不需要任何改動。

## 設定 values

完整說明見 `chart/values.yaml`（含註解）與 `chart/values.schema.json`（由
`helm lint` 強制）。實際會動到的幾個鍵：

| 鍵 | 預設 | 說明 |
|---|---|---|
| `publicUrl` | `https://opendesign.example.com` | **請設定。** 決定 `OD_ALLOWED_ORIGINS` 與 `OD_PUBLIC_BASE_URL`。預設是 example 網域，好讓 chart 自己的預設值可以 render／lint／kubeconform；它對不上任何真實來源，所以是 fail closed，且 `NOTES.txt` 會在你還沒改時大聲警告。填**空字串**、或不是「沒有路徑的 `https://` origin」，都是硬性渲染失敗。 |
| `keepOnUninstall` | `true` | 為兩個 PVC 與（由 chart 建立的）extra-env Secret 加上 `helm.sh/resource-policy: keep`。只有丟棄用的測試 release 才該設 `false`。 |
| `image.digest` | `""` | `sha256:...`。有值時優先於 `image.tag`。正式環境請設定。 |
| `image.tag` | chart 版本 | 會浮動的 tag 會被 schema 與 `tests/validate.py` 拒絕。 |
| `nginx.requireOriginOnMutation` | `true` | sidecar 對沒有 `Origin` 的 POST／PUT／PATCH／DELETE 回 403。對瀏覽器正確；會擋掉不送 `Origin` 的非瀏覽器用戶端。 |
| `persistence.data.size` | `20Gi` | `longhorn` 支援線上擴容。 |
| `backup.enabled`／`.schedule`／`.retain` | `true`／`17 3 * * *`／`7` | |
| `opendesign.extraEnv` | `{}` | 僅供經審查的追加項；chart 自有的變數會被拒絕。**會以明文渲染進 `-config` ConfigMap——絕不可放金鑰。** |
| `opendesign.rejectSecretShapedExtraEnv` | `false` | 設 `true` 時，`extraEnv` 裡任何 `*_API_KEY`／`*_TOKEN`／`*_SECRET`／`*_PASSWORD` 都會讓渲染失敗。目前預設 `false`，唯一原因是 live release 還在用這條路傳一把金鑰，見 [docs/MIGRATION.md](docs/MIGRATION.md)。 |
| `opendesign.extraEnvSecret.enabled` | `false` | 設 `true` 會在 OpenDesign 容器加上 `envFrom.secretRef`，金鑰就不會經過 ConfigMap。這會改動 pod template，因此會滾動一次 Pod。 |
| `opendesign.extraEnvSecret.create` | `false` | `false` = Secret 已經存在，chart 只引用它（建議形狀）。`true` 則由 chart 依 `.data` 渲染，每個值都有 `required()`。兩種模式與欄位見 [examples/secrets.example.yaml](examples/secrets.example.yaml)。 |
| `networkPolicy.allowHelmTest` | `false` | 設 `true` 會為 `helm test` hook Pod 多開一個 ingress 來源。NetworkPolicy 開著時，`helm test` 需要它。 |
| `helmTest.enabled` | `true` | 是否附帶唯讀的 `helm test` hook。 |

仍然沒有 `secrets:` 區塊，也沒有 `service.type`。Secret 只會被「引用」，或在明確
opt-in 下才由 chart 建立，理由見〈安全〉。

正在運行的那個 release 的 values（不含密文）已提交在
[`deploy/woow-k3s/opendesign.yaml`](deploy/woow-k3s/opendesign.yaml)。

## 匯出能力

| 格式 | 支援情況 |
|---|---|
| 獨立 HTML | OpenDesign 原生支援 |
| 專案 ZIP | OpenDesign 原生支援 |
| PNG／JPEG | 支援 |
| 截圖式 PDF | 支援；UI 的 PDF 動作由 `od-export-bridge.js` 導到二進位的 `/export/pdf-image` |
| 截圖式 PPTX | 支援；每張投影片一張整頁圖 |
| 可編輯 PPTX | **不支援**，渲染器會回傳明確錯誤 |

那個 bridge 是必需品而非裝飾：OD 0.21.1 的
`PROJECT_RUN_SCOPED_EXPORT_PATH_RE` 並不包含 `/export/pdf`——那是 Electron／桌面
版路徑，而本部署注入的是 `desktopArtifactExporter: null`。沒有 bridge，PDF 按鈕
按下去不會下載任何東西。

渲染器原封不動移植自 Home Assistant add-on：序列化執行（`Semaphore(1)`）、120 秒
絕對逾時、64 張投影片、4800 萬像素、128MiB 輸出、32MiB HTML、4 次遠端抓取／
64MiB 遠端位元組上限，加上輸出路徑正規化封鎖、停用 WebSocket，以及會拒絕
RFC1918／CGNAT／link-local／loopback／metadata 位址的 IPv4／IPv6 請求政策。CJK 與
emoji 字型已內建於映像，擷取不依賴外部字型 CDN。

## 備份與還原

本叢集的 Longhorn **沒有可用的備份目標**（`backuptargets/default` 回報
`available: false`，且 `recurringjobs` 為零），所以 chart 自帶 CronJob，而不是假裝
Longhorn 有在管。

每晚 03:17（Asia/Taipei），`<release>-backup` 以 `/bin/sh` 覆寫進入點執行 OD 映像，
唯讀掛載資料 PVC、可寫掛載備份 PVC，寫出
`/backup/opendesign-<UTC 時間戳>.tar.gz`，並只保留最新的 `backup.retain` 份。它帶有
**required** 的 podAffinity（`app=opendesign`／`kubernetes.io/hostname`），因為
Longhorn RWO 磁碟只會掛在單一節點上，否則 Job 會卡在 attach。**不要**把它改成
`preferred`。

還原：

```bash
kubectl -n pi-agent-woow scale deploy/od --replicas=0
# 起一個同時掛上兩個 PVC 的維護 Pod，然後：
#   tar xzf /backup/opendesign-<時間戳>.tar.gz -C /data
kubectl -n pi-agent-woow scale deploy/od --replicas=1
```

這是**同一個 Longhorn 叢集內**的副本。它能救「誤 `helm uninstall`」或「誤刪
PVC」，但**救不了整個叢集掛掉**。要異地保存，得在叢集層級設定 Longhorn backup
target，或在 CronJob 加上傳步驟——兩者都不在本 chart 範圍內。

## 升級

```bash
helm -n pi-agent-woow upgrade od ./chart -f od-values.yaml
```

Deployment 使用 `strategy: Recreate`，因為資料卷是 Longhorn RWO，無法同時掛在兩個
不同節點的 Pod 上。每次滾動都會有短暫中斷；這是正確機制，而不是拿節點綁定去繞過。

請把發佈作業印出的 digest 填進 `image.digest`。改動 nginx ConfigMap 會透過
`checksum/nginx` annotation 自動滾動 Pod。

## 解除安裝

```bash
helm -n pi-agent-woow uninstall od
```

namespace 會保留（由 Rancher 管理且共用：本 chart 從不渲染 Namespace，所以也永遠
刪不掉別人的 namespace）。兩個 PVC 也會保留，因為 `keepOnUninstall: true` 幫它們
——以及由 chart 建立的 extra-env Secret——加上了 `helm.sh/resource-policy: keep`。
真的要刪資料：

```bash
kubectl -n pi-agent-woow delete pvc od-data od-backup   # 幾乎不可逆
```

即便如此，PV 仍是 `Retain`，磁碟會以 `Released` 狀態留著，直到有人在 Longhorn 裡
手動刪除。

## 安全

**認證邊界就是 NPM 的 Access List，除此之外沒有別的。** 必須把這句話講白，因為
1.x chart 把它搞反了。

- OpenDesign **本身沒有任何應用層認證**，從來就沒有。任何能連到
  `service/<release>:7457` 的人，就等於拿到完整 UI 與 API。
- 因此 Service 只能是 ClusterIP，`service.type` 不是可設定的 values 鍵。沒有
  NodePort、沒有 LoadBalancer，因為兩者都會繞過 NPM。
- NetworkPolicy 在 7457 埠只放行兩種來源：標籤為 `app=npm` 的 Pod，以及
  `192.168.0.0/16`（區網管理／除錯）——與五套 `pi-agent` 完全相同的形狀。其餘一律拒絕。
- daemon 綁在 loopback，所以就算 NetworkPolicy 寫錯，7456 埠也不會外露。
- chart 不建立 ServiceAccount，並設 `automountServiceAccountToken: false`。除非你
  明確設定 `opendesign.extraEnvSecret.create: true`，它也不建立任何 Secret；預設是
  引用「已經存在」的 Secret，金鑰完全不經過 Helm。
- `opendesign.extraEnv` 會**以明文渲染進 `-config` ConfigMap**。用來放
  `OD_ALLOWED_INTERNAL_HOSTS` 沒問題，放金鑰就是錯的：namespace 內任何能
  `get configmaps` 的東西都讀得到，`helm get values` 也會回顯。伺服器端金鑰應該放
  `opendesign.extraEnvSecret`，而 `rejectSecretShapedExtraEnv: true` 會把這句建議
  變成渲染失敗。
- `OD_API_TOKEN` 與 `OD_DISABLE_API_AUTH` 在本倉庫**任何地方都不存在**，且
  `tests/validate.py` 會在任一字串重新出現於 chart 檔案時讓建置失敗。1.x chart 設了
  `OD_BIND_HOST: "0.0.0.0"` 與 `OD_DISABLE_API_AUTH: "1"`，註解寫「Auth handled by
  Cloudflare Tunnel」——那個反轉正是本次重寫要拆掉的東西。
- `OD_ALLOWED_ORIGINS` 設為單一公開來源。帶著其他 `Origin` 的跨站請求會被 OD 拒絕；
  **完全沒帶** `Origin` 的變更型請求則由 sidecar 拒絕
  （`nginx.requireOriginOnMutation`）。
- chart **不建立任何 Secret 與 ServiceAccount**，並設定
  `automountServiceAccountToken: false`。1.x 的 console 有一個握著 `pods/exec` 與
  `secrets: get,patch,update` 的 ServiceAccount，前面只擋一組共用 ttyd 密碼；它是被
  「刪除」，不是被「修好」。
- **BYOK**：供應商、模型與 API 金鑰都在瀏覽器輸入，只留在該瀏覽器的 local storage。
  任何供應商金鑰都不會進入 chart、ConfigMap、Secret、環境變數或 `/data`。發佈前的
  release gate 會驗證金鑰不會出現在容器日誌或 `/data`。
- nginx sidecar 以 UID／GID 101 執行，root 檔案系統唯讀，丟棄所有 capability，暫存
  目錄放在 `/tmp` 的 `emptyDir`。OD 容器的 PID 1 只以 root 存活到把 root 所有的
  Longhorn 掛載點 chown 完，隨即以 `su-exec` 降權到 UID 1001，capability 收斂到
  `CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID`。

輪替提醒：1.x `values.yaml` 提交過一把真實的 64 位十六進位 MCP JWT 金鑰、一組 MCP
管理員密碼與一組 ttyd 密碼。它們在本倉庫的**公開** git 歷史中——那個 commit 仍可
經由未刪除的分支與 GitHub 自己的 `refs/pull/N/head` 取得，刪分支並不會讓它消失，
三者都必須當成已洩漏處理。詳見 [docs/MIGRATION.md](docs/MIGRATION.md)。

## 版本與發佈

chart 版本與映像 tag 是**同一個數字**。`chart/Chart.yaml` 的 `version: 2.0.1` 是唯一
來源；`appVersion` 是 OpenDesign 版本（`0.21.1`）。Git tag 為 `v<chart 版本>`。

`helm.sh/chart` 是 pod template 的標籤之一，所以「動 chart 版本 + upgrade 既有
release」就會滾動一次 Pod。因此「不得重啟任何東西」的變更——例如讓正在跑的
`opendesign` release 接上本 chart 的新版本——會刻意不動版本號，把 bump 留給那個
被允許重啟的 release。

`latest` 在 `Chart.yaml`、`values.yaml`、`Dockerfile`、workflow 與文件中一律禁止，
由 `tests/validate.py` 強制。

推 `v*` tag 會依序執行：validate → smoke → release preflight → release
architecture gate → publish。preflight 採 fail-closed：除非
`ghcr.io/woowtech/woow-k3s-opendesign:<版本>` 與
`ghcr.io/woowtech/charts/opendesign:<版本>` **兩者都**能被證明不存在，否則拒絕發佈。
已發佈版本不可變更：部分失敗的發佈只能改 `chart/Chart.yaml` 版本後重新打 tag，不能
覆蓋。細節見 [docs/CI.md](docs/CI.md)。

## 開發與驗證

```bash
./tests/run.sh
```

這就是唯一的閘門。它會執行 metadata／密文驗證器、workflow 政策檢查、對渲染結果做
`helm lint` + `helm template` + `kubeconform`、Node 單元測試，以及 shell 與
`nginx -t` 語法檢查。需要 Node、帶 PyYAML 的 Python 3、`helm`、`kubeconform` 與
`yq`；不需要 Docker，也不需要叢集。若環境中有 kubeconfig，它會額外對渲染結果執行
`kubectl apply --dry-run=server`——唯讀，而且正是能抓到 1.x 安裝失敗的那道檢查。

`tests/container-smoke.sh` 需要容器執行環境，會建立真正的雙容器 Pod（OD ＋ nginx
sidecar），驗證健康檢查、loopback 綁定、逐像素 PNG 斷言、`pdfinfo` 頁數、PPTX 投影片
數、匯出 bridge，以及 `Origin` 的放行／拒絕兩條路徑。

## 上游與授權

執行環境衍生自 `ghcr.io/nexu-io/od:0.21.1`，在 `Dockerfile:1` 以 digest 釘住，並由
`tests/validate.py` 再次斷言。OpenDesign 有其自身的上游授權與聲明。本倉庫的封裝、
chart 與整合程式碼採 MIT 授權，見 [LICENSE](LICENSE)。
