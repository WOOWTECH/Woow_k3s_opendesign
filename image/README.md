# open-design image

供 PaaS 平台 cloud service 使用的 **OpenDesign daemon** image（daemon :7457 + Next.js UI +
預裝 Claude Code / OpenCode 兩個 agent CLI + design 工具鏈）。

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/open-design:{tag}`（PaaS 外殼）與
  `jcr-prod.woowtech.io/woow-paas-docker-local/open-design-core:{tag}`（共用核心，同一個 tag）
- 平台側（`woow_paas_platform` seed）會 **pin image digest**；chart 由 `woow-paas-charts` 建置。
- 對應 issue：`odoo-addons/woow_paas_platform#380`（支線 B）。

## 供應鏈 provenance

自 2026-10-14 起，底層是**從 WoowTech fork 建出的 OpenDesign**，不再直接用上游預建 image：

| 項目 | 來源 |
|------|------|
| fork | Gitea [`woow-paas/open-design`](https://git-prod.woowtech.io/woow-paas/open-design)，tag／commit 釘在 [`od-source.env`](od-source.env)（目前 `woow-od-v0.24.1-w2.11`＝`05b23f5a5259d4f2c22e5c6e3eb92ce9103ed34a`，含 HA Ingress 設定頁重整、Pi 自訂模型選單（金鑰只放環境變數時改問 `pi --list-models`）及 OpenCode 雙設定檔合併） |
| 上游基準 | `open-design-v0.24.1`＝`89e64d813bb1c7a11519b3f668f011f7017637d7`（workflow 驗證它是 fork commit 的祖先） |
| 底層建置 | fork 的 `deploy/Dockerfile`＝上游自己的嚴格 build（`pnpm install --frozen-lockfile`）；node 基底 `node:24.21.0-alpine3.24` 以 index digest 釘死——與 `ghcr.io/nexu-io/od:0.24.1` 同一份檔案、同一個 node 基底，daemon／web 以外的每一層都相同 |
| fork 帶的改動 | Omnigent 原生設定與已安裝引擎驗證、OpenCode 原生模型、headless 網頁用戶端修正；內建 `woowtech-brand` skill與原生 `woow-omnigent`、`woow-paseo` plugin；Omnigent 設定由 GUI 開啟；叢集內建置修正（略過 onnxruntime 的 CUDA 下載；better-sqlite3 執行期用上游預編譯檔，w2.1） |
| 本層加的東西 | Claude Code／Codex／Pi／OpenCode、design 工具鏈（含 python-pptx／pptxgenjs）、omnigent CLI（Omnigent host）＋ fork 的 Omnigent SDK 修補（`omnigent-sdk-patches/`，基準與結果 sha256 不符即 build 失敗）、移除上游 `brainstorming` skill、HOME 與 /etc/skel、build-time 版本契約 |

流程：`build-open-design-image.yml` 先 clone fork（CI 帳號、叢集內網址）→ 核對 tag＝釘死的 SHA、上游 tag 是祖先、`core-legal/` 與 fork 一致 → 建底層 `od-woow-base:<sha>` → 以 `OD_BASE=<底層>` 建 `open-design-core`（`Dockerfile.core`）→ 以 `CORE=<core>` 建 PaaS 外殼（`Dockerfile`）。`OD_BASE`、`CORE` 都刻意沒有預設值：少了 fork 底層或 core 就 build 失敗，不會悄悄退回上游的 daemon／web。

為什麼不直接用上游預建 image：WoowTech 的 daemon／web 改動（Omnigent 原生整合等）必須從原始碼建；用上游自己的 `deploy/Dockerfile` 保留了「嚴格、可重現」，不是退回舊版 `git clone` + `pnpm build` 且多處 `|| true` 的做法。

升版：fork 合上游新 release → 在 fork 打新 tag → 改 `od-source.env` 的 tag／SHA／上游三項 → 重 build；`woow-patches/` 與 `omnigent-sdk-patches/` 任何目標對不上都會讓 build 失敗，必須逐一重驗。

## 版本 pin（可重現性優先）

| 元件 | pin 版本 | 取得方式 |
|------|---------|---------|
| open-design | `0.24.1`（上游 package.json 仍是 `0.23.1`；core 以 `OD_APP_VERSION=0.24.1` 讓 `/api/version` 回報 0.24.1，見下）＋ WoowTech fork | fork tag＋commit SHA 雙釘（`od-source.env`）；node 基底 index digest |
| `@anthropic-ai/claude-code` | `2.1.296`（與 HA add-on 一致） | `npm install -g`（musl 原生 binary） |
| `opencode-ai` | `1.18.33` | `npm install -g`（musl 原生 binary） |
| `@openai/codex` | `0.162.1` | `npm install -g`（需 `gcompat`） |
| `@earendil-works/pi-coding-agent` | `1.1.0` | `npm install -g --ignore-scripts`（與 HA add-on 相同） |
| `svgo` / `@mermaid-js/mermaid-cli` / `sharp-cli` | `4.1.0` / `12.0.0` / `6.1.0` | `npm install -g` |
| `uv` / `uvx` | `0.12.20` | musl release tarball（`--retry` 下載＋sha256 校驗） |
| `omnigent`（正式 core 預設內含） | `0.16.0` | venv `/opt/omnigent/venv`，uv 管理的 CPython `3.12.14`；omnigent 與全部 94 個相依套件照 `omnigent-requirements.lock`（sha256）以 `--require-hashes` 安裝，build 時編好 bytecode（見下） |
| `tmux` / `re2` / `abseil-cpp` / `icu-libs` | `~3.7` / `~2025.11.05` / `~20250814` / `~78` | Alpine v3.24 apk，`~` 鎖住版本線（同一線的安全修補 `-rN` 仍可裝；換線 build 失敗）。tmux ≥ 3.3 是 omnigent 原生 Claude／pi harness 的需求 |
| `pptxgenjs` | `4.0.1` | `npm install -g`（`NODE_PATH=/usr/local/lib/node_modules`，`require("pptxgenjs")` 可用） |
| `python-pptx` | `1.0.2` | `/opt/venv` |

**版本字串**（AI-OD-001-1）：上游 `open-design-v0.24.1` 的根目錄與 `apps/daemon` 的 `package.json` 都還是
`0.23.1`（上游沒 bump），daemon 的 `/api/version`、`/api/health`、diagnostics 讀的正是那個檔。daemon 優先採用環境變數
`OD_APP_VERSION`（`apps/daemon/src/app-version.ts`，桌面版本來就用它），所以 `Dockerfile.core` 以
`ENV OD_APP_VERSION=${OD_UPSTREAM_VERSION}`（`od-source.env`）釘住；workflow 的 core 複驗與成品複驗都要求
`/api/version` 等於 `OD_UPSTREAM_VERSION`，`scripts/tests/test-open-design-version.sh`（lint.yml）鎖住這三個接點。升上游時只要改
`od-source.env`。

**build-time 契約**（`Dockerfile.core` 的契約 `RUN`，以 uid 1001 執行）：claude／opencode／omnigent 版本必須完全相等、
daemon 入口存在、所有工具在 PATH、python 套件（含 omnigent 的 `cli_auth`、python-pptx）與 pptxgenjs 可載入——任一不符
**build 直接失敗**，不再靜默產出。workflow 另做成品複驗：以 chart 的參數起 daemon，驗 health、OpenDesign MCP
（`od mcp`，stdio）列得出工具、chromium 能把中文頁印成內嵌 Noto Sans CJK 的 PDF；複驗時 daemon 以 uid 1001、
`--cap-drop ALL`、`no-new-privileges` 執行，和 chart 的 securityContext 一致；並確認 ENTRYPOINT 是
`tini --`、PID 1 是 tini 且唯一的直接子行程就是 daemon；新安裝登入前沒有 host supervisor。

## open-design-core（PaaS 與 HA add-on 共用的核心）

| 檔案 | 內容 |
|------|------|
| `Dockerfile.core` | fork 底層＋四個 CLI＋工具鏈＋woow-patches＋版本契約（stage `core-base`）；固定疊 SDK 0.16.0 與五個 patch（stage `core-omnigent`）；最後一層 `COPY core-legal/ /usr/share/` |
| `Dockerfile` | PaaS 外殼：`FROM ${CORE}`＋內建 OpenDesign MCP（`mcp-runtime/`，見下節）＋`WORKDIR /app`／`EXPOSE 7457`／`CMD`；預設 target `paas` 為 `ENTRYPOINT tini --`；host 由原生 daemon 的 GUI setup 管理 |
| `core-legal/licenses/open-design/LICENSE` | OpenDesign 的 Apache-2.0 授權（Apache-2.0 §4(a)）；workflow 核對它與 fork checkout 的 `LICENSE` 逐 byte 相同 |
| `core-legal/doc/woow-open-design/NOTICE.md` | WoowTech 改動說明（§4(b)）：fork commit 清單、woow-patches、其他隨附軟體；`fork-commits:begin／end` 之間的清單必須剛好等於 `git rev-list --reverse <上游>..<fork>`，否則 build 失敗（`scripts/check-open-design-core-legal.sh`） |

發佈：同一次 run 推 `open-design-core:<tag>-pending-approval` 與 `open-design:<tag>-pending-approval`，同一張核可單；`/approve` 依序 promote core（不推 `:latest`）與 PaaS（照舊推 `:latest`），`/reject`、逾時兩個候選一起清。成功時 run 的 notice 印出 core 的 tag＋digest，HA 由 GitHub `WOOWTECH/Woow_ha_opendesign_add_on` 的 **Import open-design-core**（`import-core.yml`）以唯讀 JCR 帳號按 digest 複製到公開的 `ghcr.io/woowtech/open-design-core:<tag>`（`skopeo copy --preserve-digests`，拷完以登入與匿名兩條路徑核對 digest）。core 只有 amd64。

升 fork：改 `od-source.env` 的 tag／SHA，並更新 `NOTICE.md` 的 fork commit 清單與摘要；`bash scripts/check-open-design-core-legal.sh <fork checkout> <上游 SHA> <fork SHA>` 不符時會印出應有的清單（格式同 NOTICE）。fork 的 LICENSE 若有變也要重新複製。

## 內建 OpenDesign MCP server（`mcp-runtime/`，chart open-design 0.5.0 起）

PaaS 外殼內建對外的 OpenDesign MCP server，取代另外訂閱的「Open Design MCP」（`mcp-opendesign` 範本）。
**程式就是 HA add-on 的那一套**：`mcp-runtime/ha/` 是 GitHub `WOOWTECH/Woow_ha_opendesign_add_on` 的
`mcp-runtime/` 以 commit 釘住的複本（`HA_SOURCE.json`，`sync-ha-mcp-runtime.sh` 重新複製；不可手改），
包含 Woow MCP gateway、vendored `opendesign_mcp_server`、工具清單與預設、保護、管理頁與 hash 釘住的 wheel。
兩邊的工具數、預設與行為因此一致；PaaS 只多一層放置（`mcp-runtime/paas_opendesign_mcp/`）：

| | HA add-on | PaaS（本 image＋chart 0.5.0） |
|---|---|---|
| 行程 | add-on 容器內第 4 個程序，root bootstrap 降權成 uid 10001 | daemon pod 的 `mcp` sidecar 容器，Kubernetes 直接以 uid 10001 啟動（`/opt/woow/bin/paas-opendesign-mcp`），唯讀根檔案系統 |
| 後端 | 127.0.0.1:7456 | 同一個 pod 的 daemon，127.0.0.1:7457（loopback 豁免 OD_API_TOKEN） |
| MCP 入口 | LAN 0.0.0.0:8081：`/mcp`＋Bearer、`/private_<token>/mcp` | 127.0.0.1:8081，經 chart 的 nginx：`https://<服務網址>/mcp`（Bearer）、`/private_<token>/mcp`（Claude.ai，不記 log） |
| 管理頁 | HA Ingress | `https://<服務網址>/mcp-admin/`，同一組帳號密碼（nginx basic-auth，`X-Remote-User-Id`＝登入帳號） |
| 狀態 | `/data/mcp` | od-data PVC 的 subPath，`/data/mcp/state`（0700，uid 10001；daemon 容器讀不到） |
| socket | `/run/ha-opendesign-mcp` | emptyDir `/run/od-mcp`，只有 authproxy 與 mcp 容器掛載 |

`paas_opendesign_mcp/launch.py` 只把 add-on 套件裡的放置常數（後端、狀態、socket、監聽位址）換成 PaaS 值，
並在啟動時於端點未設定時把管理頁的「MCP 用戶端端點」預填成 `<服務公開網址>/mcp`，然後原樣執行 add-on 的
`ha_opendesign_mcp.runtime.main()`。add-on 改名或拿掉這些常數時啟動即失敗（要先審查）。

驗證：`install.sh`（build 時）核對複本與 wheel、確認沒有任何 add-on 路徑殘留；`.gitea/workflows/test-open-design-mcp.yml`
（PR）在已發佈的 core 上建外殼並跑 `mcp-runtime/tests/e2e/run-e2e.sh`；`build-open-design-image.yml` 對候選映像跑同一支 e2e。
細節見 [`mcp-runtime/README.md`](mcp-runtime/README.md)。

## Omnigent 原生 host

2026-10-26 重新納入已驗收的原生整合；2026-10-15 的暫停決定已撤回。每個正式 core 都預裝
SDK `0.16.0` 與五個 patch：模型選項、quota error、native interrupt、Pi 自訂模型選項及 OpenCode 雙設定檔合併。來源為
`05b23f5a5259d4f2c22e5c6e3eb92ce9103ed34a` 的 `deploy/omnigent/sdk-patches`，
`SOURCE.json` 記錄複本雜湊；`manifest.json` 核對每個 patch、原始檔與結果的 sha256。
Pi 選單 patch 在 Pi 的檔案算不出任何選項時（金鑰只在環境變數、或只覆寫內建供應商）改問 `pi --list-models`，細節見 fork 的 `deploy/omnigent/sdk-patches/PI-MODEL-OPTIONS.md`；`verify-omnigent-runtime.py` 用假 `pi` 驗證這條路徑，也驗證 Pi 的「No models available」提示不會變成模型。

`Dockerfile.core` 使用 `/opt/omnigent/venv/bin/python -I -B` 套用並驗證完整 patch set；
原生 daemon 打包的 `sdk-patches` 必須逐 byte 相同，`host-kit` 必須符合
`omnigent-host-kit.json`。SDK 與相依套件繼續使用 hash lock，Alpine 的 re2／Claude SDK
sdist 編譯與原生 Claude CLI 解析契約維持。

容器啟動鏈是 `tini → daemon`。`omnigent-host-entry` 與 `with-omnigent` stage 已移除；
chart **`omnigentHost.enabled=false` 保留**，這表示停用舊 supervisor。使用者在外掛 GUI
輸入 server、帳號與密碼後，daemon 才啟動隨附 host-kit；不得同時啟動 chart supervisor。

image 不設定 `OMNIGENT_CONFIG_HOME`／`OMNIGENT_DATA_DIR`，不預填 server 或帳密，
不複製 legacy `~/.omnigent`。原生 service 使用 `<OD_DATA_DIR>/integrations/omnigent/host`，
新安裝必須顯示 `needs-login`、`server=null`。現有 legacy token 留待使用者處理，不自動匯入。
GUI 只掃描及連結已有 Claude、Codex、Pi、OpenCode；缺少 engine 不觸發下載。

檢查命令（repo 根目錄）：

```bash
python3 -B scripts/verify-open-design-omnigent.py
python3 -B -m unittest discover -s open-design/omnigent-sdk-patches/tests -v
python3 -B scripts/tests/test-open-design-omnigent.py
```

候選 workflow 以 uid 1001、無外網的新 core/PaaS 容器跑 `tests/omnigent-image-smoke.mjs`：
檢查 GUI 狀態與缺少帳密的拒絕回應、四個預裝 engine、私有 config 路徑、原生 dependency resolver
重用 image SDK（拒絕執行任何安裝命令）、登入前沒有 host。原有 Paseo smoke、MCP container e2e、
匯出／白牌／版本／授權驗證繼續執行。這些離線契約不代替真實 server 登入、模型對話與 HA Ingress 驗收。

## WOOW patches（`woow-patches/`，修上游 build 好的檔案）

重產 zh-TW 對照表（升 `OD_BASE` 時）：`python3 woow-patches/zh-tw-locale.py generate <web chunk> woow-patches/zh-TW-s2twp.json`
（需要 `opencc-python-reimplemented==0.1.7`，只在開發機用）。

round-1 QA 找到、改動很小的上游問題，先在我們的 image 修，再回報上游。每個 patch 都是對 build 好的檔案做
**精確字串**修改；目標字串對不上（例如上游升版）就讓 build 失敗，不會悄悄沒修到。以 uid 1001（/app 的擁有者）
執行，檔案擁有者不變。升 `OD_BASE` 時要逐一確認。

| 問題 | patch | 驗證 |
|------|-------|------|
| ISS-OD-01 簡報「另存 PDF」只印出目前那一頁（`.slide:not(.active){display:none !important}` 的 specificity 0,2,0 壓過列印用的 `.slide{display:flex !important}` 0,1,0） | `deck-print.sh`：在 `@media print` 內 `.slide:last-child{…}` 之後加 `.slide:not(.active) { display: flex !important; }`；daemon 的 `@open-design/contracts`（產生簡報的框架）必須有改到，web chunk／skills 裡同樣的框架文字一起改 | workflow 複驗：用 contracts 匯出的 `DECK_SKELETON_HTML` 做 3 頁簡報，chromium 印 PDF 必須 3 頁；拿掉這條規則的同一份必須 1 頁 |
| ISS-OD-05 匯出的 PNG／PDF（與新分頁預覽）裡 logo 等專案內相對路徑的圖破圖（`exports.ts` `buildBlobSafeSrcdoc()` 沒拿到 baseHref 時退回網站根目錄） | `export-basehref.py`：只改那個退回值——頁面是專案／檔案路由（`/projects/<id>[/conversations/<cid>][/files/<dir>/<file>]`）時改用 `<origin>/api/projects/<id>/raw/<dir>/`（和預覽用的 `projectRawUrl()` 一樣），其他頁面照舊；有傳 baseHref 的呼叫不受影響。目標字串必須剛好出現一次 | 本機以 node 實跑新舊退回函式（7 種路徑）；`node --check` 改過的 chunk；workflow 複驗 daemon 送出的 chunk 帶新邏輯 |
| ISS-OD-08 繁中介面的提示語是簡體（zh-TW 語系裡還有 zh-CN 字串，例如「请审查并润色现有动效…」） | `zh-tw-locale.py` ＋ `zh-TW-s2twp.json`：在 web chunk 裡找出 **zh-TW 那一個字典物件**（以只在 zh-TW 出現的標記定位），只對其中仍含簡體字的值換成 OpenCC s2twp 結果（261 個；「台／群／峰」單獨出現不算簡體，s2twp 的「許可權／儀錶板／瞭解」改回「權限／儀表板／了解」）。對照表離線產生後 commit（可逐條審），build 時只套用、不需要 OpenCC；任何一條對不上就 build 失敗。zh-CN 字典與 key 不動 | 本機：套用後該 chunk 的 zh-TW 值為「請審查並潤色現有動效…」，zh-CN 仍是「请审查并润色…」，`node --check` 通過，重跑會失敗（不重複套）；workflow 複驗 daemon 送出的 chunk 兩者各一份 |
| ISS-OD-05（圖片匯出）「匯出為圖片」（PNG／JPEG／WebP）裡專案內的圖（logo）仍是破圖＋alt 文字：上面的 baseHref 修正只涵蓋 PDF／新分頁；web 版（沒有桌面 host）的圖片匯出走預覽的 snapshot bridge（`srcdoc.ts` `captureSnapshot` → `syncElementState`），把 DOM 複製進 SVG `<foreignObject>` 再當圖片點陣化，而 SVG 圖片不會載入外部資源，bridge 又把 `<img>` 原樣複製成網址 | `snapshot-inline-img.py`：`syncElementState` 對已載入的 `<img>` 改用 canvas 轉成 data URL（同源的專案素材不會汙染 canvas；會汙染的跨源圖照舊保留網址），並移除 srcset 讓 data URL 生效。bridge 文字在 daemon（`apps/daemon/dist`，URL 載入的預覽，UI 圖片匯出走這條）與 web bundle（srcDoc 預覽）各有一份，兩份都改；目標字串在兩邊都必須剛好出現一次 | sandbox 以 Playwright 實測（真的 UI「匯出為圖片」→ PNG）：候選 20261002.0808 logo 消失（藍色像素 0），在瀏覽器端套同一段修改後 logo 出現（15104）；新 image 直接驗證；workflow 複驗兩份 bridge 都已修改、上游那行已不存在 |
| ISS-OD-11 付費白牌服務出現上游 NPS／CSAT 問卷（每輪生成後蓋住預覽）與 OpenDesign Cloud、Discord、@OpenDesignHQ 導流連結 | `white-label.py`：在靜態 web export 每一頁 `<head>` 最前面插入（app script 執行前）：問卷自己的「已結束」旗標（localStorage `open-design:experience-survey:v1:retired`，上游 `isSurveyRetired()` 因此為真，問卷不會出現、也不送出），以及以上游 `data-testid` 隱藏 `entry-nav-rail-social`（Discord／X）、`entry-cloud-signin-tip`（OpenDesign Cloud 登入提示）的樣式，問卷卡片的 CSS module class 也一併隱藏 | 本機：5 個 html 都插入、重跑 0 頁；workflow 複驗 daemon 送出的首頁 `<head>` 第一個元素就是這段 |
| #1439（R8）白牌第二輪：「聯絡我們」彈出上游飛書／Discord；「切換到 OpenDesign Cloud」默默把整個服務的預設 agent 改成沒裝的 amr；設定頁「登入／註冊」回 500 英文錯誤；首次引導頁主按鈕是 Cloud 註冊；隱藏的側欄連結仍指向上游 | `white-label.py` 的樣式再隱藏 `chat-error-switch-to-cloud`、`.settings-cloud-signin-callout`、`.amr-login-pill`、`.onboarding-cloud__primary`、AMR agent 卡（`:has()` 獨立一條規則，不支援的瀏覽器只丟這條）與支援管道的品牌圖示；`white-label-links.py` 改 build 出來的 JS（每處都要命中預期次數，否則 build 失敗）：支援對話框兩個管道改成 `mailto:support@woowtech.io` 與同站 `/_woow/support`（chart 的 auth proxy 302 到 `whiteLabel.supportUrl`，換網址不必重 build），各語系名稱改成 WoowTech 客服信箱／服務中心、按鈕「前往」；App 不再把 `onSwitchToCloud` 傳給專案頁；殘留的 Discord／@OpenDesignHQ／support@open-design.ai 連結改指 WoowTech；「{agent} 尚未登入」錯誤卡的繁中／簡中說明改成指到 `/console/` 登入、平台服務設定填 API Key 或改用 OpenCode | 本機對 0.24.1 build 產物：所有替換命中、重跑因找不到目標而失敗（不會重複套用）；沙盒實測錯誤卡只剩「聯絡我們／匯出日誌」，對話框兩個 WoowTech 管道；workflow 複驗 daemon 送出的 chunk 含新管道、`onSwitchToCloud:void 0`，且所有 chunk 都沒有上游連結 |

## 如何 build

### 正式 pipeline（推薦，native amd64）

`.gitea/workflows/build-open-design-image.yml`：

- `workflow_dispatch`：填 `tag`（UTC 時戳 `YYYYMMDD.HHMM`）
- 或 push tag `open-design-v*`
- 流程（gate-after-build，同 code-server／pi-agent）：build core → build PaaS 外殼 → core 複驗＋成品複驗 →
  推兩個候選 tag `<tag>-pending-approval` → 開 prod approval issue → 核可留言後 registry 端依序 promote
  core（正式 tag）與 PaaS（正式 tag＋`:latest`）。
  候選 tag 可在叢集內用 `paas-registry` pull secret 拉來實測。

runner 為 amd64，`docker build` 原生產出 amd64，透過內部 JCR service URL 推送（繞過 Traefik）。

### 完整本機建置（不 push）

先由主線更新 `od-source.env` 的最終 fork tag／SHA 及 `core-legal/.../NOTICE.md`。
以下命令在 repo 根目錄執行；需要 Docker/buildx 與 registry／source 讀取權限，arm64 另需 QEMU。
不使用驗收用 overlay image，也不把私有資料帶入 build context。

```bash
set -euo pipefail
. open-design/od-source.env
OD_SRC="$PWD/.ci-build/od-native-source"
TAG=$(date -u +'%Y%m%d.%H%M')
mkdir -p .ci-build
test ! -e "$OD_SRC"
git clone --no-checkout --single-branch --branch "$OD_SOURCE_TAG" \
  "https://git-prod.woowtech.io/${OD_SOURCE_REPO}.git" "$OD_SRC"
git -C "$OD_SRC" fetch --no-tags origin "refs/tags/${OD_UPSTREAM_TAG}:refs/tags/${OD_UPSTREAM_TAG}"
test "$(git -C "$OD_SRC" rev-parse "refs/tags/${OD_SOURCE_TAG}^{commit}")" = "$OD_SOURCE_SHA"
test "$(git -C "$OD_SRC" rev-parse "refs/tags/${OD_UPSTREAM_TAG}^{commit}")" = "$OD_UPSTREAM_SHA"
git -C "$OD_SRC" merge-base --is-ancestor "$OD_UPSTREAM_SHA" "$OD_SOURCE_SHA"
git -C "$OD_SRC" checkout --detach "$OD_SOURCE_SHA"
git -C "$OD_SRC" remote remove origin
bash scripts/check-open-design-core-legal.sh "$OD_SRC" "$OD_UPSTREAM_SHA" "$OD_SOURCE_SHA"
python3 -B scripts/verify-open-design-omnigent.py --source "$OD_SRC"
python3 scripts/verify-open-design-paseo.py

docker buildx build --platform linux/amd64 --load -f "$OD_SRC/deploy/Dockerfile" \
  --build-arg NODE_IMAGE="$OD_NODE_IMAGE" --build-arg RUNTIME_IMAGE="$OD_NODE_IMAGE" \
  --label org.opencontainers.image.version="$OD_UPSTREAM_VERSION" \
  --label org.opencontainers.image.revision="$OD_SOURCE_SHA" \
  --label org.opencontainers.image.source="https://git-prod.woowtech.io/${OD_SOURCE_REPO}" \
  --label io.woow.opendesign.upstream-revision="$OD_UPSTREAM_SHA" \
  -t "od-woow-base:$OD_SOURCE_SHA" "$OD_SRC"
docker buildx build --platform linux/amd64 --load -f open-design/Dockerfile.core \
  --build-arg OD_BASE="od-woow-base:$OD_SOURCE_SHA" \
  --build-arg OD_SOURCE_SHA="$OD_SOURCE_SHA" --build-arg OD_UPSTREAM_SHA="$OD_UPSTREAM_SHA" \
  --build-arg OD_UPSTREAM_VERSION="$OD_UPSTREAM_VERSION" \
  -t "open-design-core:$TAG" open-design
docker buildx build --platform linux/amd64 --load -f open-design/Dockerfile \
  --build-arg CORE="open-design-core:$TAG" -t "open-design:$TAG" open-design

for IMG in "open-design-core:$TAG" "open-design:$TAG"; do
  docker run --rm --network none --entrypoint /opt/omnigent/venv/bin/python "$IMG" \
    -I -B /usr/local/share/woow/verify-omnigent-runtime.py
done
fixture="od-native-check-$TAG"
trap 'docker rm -f "$fixture" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$fixture" --network none --user 1001:1001 \
  --cap-drop ALL --security-opt no-new-privileges \
  -e OD_DATA_DIR=/tmp/od-native-check "open-design:$TAG"
for _ in $(seq 1 60); do
  docker exec "$fixture" curl -sf http://127.0.0.1:7457/api/health >/dev/null && break
  sleep 2
done
docker exec "$fixture" curl -sf http://127.0.0.1:7457/api/health >/dev/null
docker exec -i "$fixture" node --input-type=module < open-design/tests/omnigent-image-smoke.mjs
docker exec -i "$fixture" node --input-type=module < open-design/tests/paseo-image-smoke.mjs
mkdir -p ".ci-build/mcp-evidence-$TAG"
IMG="open-design:$TAG" PROOF_PREFIX="od-local-$TAG" \
  bash open-design/mcp-runtime/tests/e2e/run-e2e.sh ".ci-build/mcp-evidence-$TAG"
```

### 發佈相依與驗收條件

| 順序 | 必要輸入／驗證 | 負責端 |
|---|---|---|
| 1 | 合併 c8＋aa0 的 native tag／SHA；保留 Paseo／MCP；daemon/web 套件測試、typecheck、build；`deploy/Dockerfile` 在 daemon build 前 COPY SDK patches | native/main |
| 2 | `od-source.env` tag/SHA、完整 LICENSE/NOTICE commit 清單；source 契約通過（舊 w2.5 pin 會被拒絕） | main＋CI |
| 3 | native source → core → PaaS 完整 build；兩顆成品契約、Omnigent／Paseo smoke、MCP e2e、PDF／白牌／版本檢查；真容器完整 installed-SDK 90 tests（不可 skip/deselect） | Gitea build |
| 4 | `.gitea/workflows/test-open-design-mcp.yml` 的 `TEST_CORE` 改為新候選或正式 immutable digest；目前仍保留舊 pin，新 native gate 會失敗，不能視為可發佈 | main |
| 5 | 隔離候選 GUI fresh install、legacy token 不自動採用、真實登入／已裝 engine 與 model/module、reply/stop、quota/interrupt、disconnect/reconnect、reload/restart、disable/re-enable；只一個 host supervisor | 實機驗收 |
| 6 | 兩顆候選均通過後，既有核可單 HMAC／人員／時效／關單／四個 manifest 守衛，依序 promote core、PaaS；不得重建或覆寫正式 tag | release coordinator |
| 7 | HA `import-core.yml` 按已批准 core digest 匯入 GHCR，登入與匿名 digest 一致；HA main 先整合另一團隊 pending 0.2.7，再選版本與更新 core pin | HA/release coordinator |
| 8 | HA 真實 Supervisor/Ingress、升級保留與新裝隔離、MCP/Paseo/Omnigent；正式 add-on／Store／Local Download 發行和通知一致 | HA/release coordinator |

installed-SDK 90 tests 使用最終 native checkout 的
`deploy/omnigent/sdk-patches/tests/native/README.md` 與三個完整測試檔；在一次性候選容器內
準備 pytest 工具後，以 `/opt/omnigent/venv/bin/python -I -B -m pytest` 執行。
必須先驗 SDK version=0.16.0、forwarder/client/bridge/interrupt 全部由候選的 site-packages 載入，
禁止用 checkout 模組替代。預期 **90 passed、0 skipped、0 deselected**；安裝測試工具的容器不得當成正式映像。

建置 workflow 在 push 候選前執行 `scripts/test-open-design-installed-sdk.py`：七個測試工具
wheel 依 `tests/sdk-test-wheels.json` 下載並驗 sha256，容器使用 `--network none`，以 uid 1001
載入映像內完整 SDK。測試由同一個隔離 Python 的 `pytest.main` 執行，JUnit 必須恰好有
90 個成功案例；缺檔、skip、部分選取或 SDK 檔案改動都會失敗。測試容器隨後移除，不回寫映像。

Gitea 現有 `build` job 的 `needs: [gate]` 保留，避免無關 issue comment 進入 concurrency。
這次 native source、core、PaaS 和測試仍依序在同一 job 執行，無需新增多 job 相依。
跨 repo 發佈相依是上表的 artifact 清單，不能只憑 native repo 的 CI 綠燈當作 HA 或 PaaS 驗收。
正式發佈一律走 workflow；本機不推 JCR，不 dispatch、merge 或更動正式環境。

### Native Paseo packaging

The w2.5 fork compiles the native Paseo launcher and atomic MCP server API into
`open-design-core`. Both the PaaS shell and HA add-on install the public shared
`opendesign-paseo-plugin` runtime 0.2.3 at commit
`56fcee82d610b56d5263e88cff04f9ece602a9ef` (the HA add-on follows with 0.2.11).
PaaS vendors the npm package plus its lockfile under `paseo-runtime/`; the
directory is byte-identical to the published v0.2.3 release (no local patch), and
`SOURCE.json` records the archive and file hashes. 0.2.3 adds the managed runtime
support baked into this image (#448), local speech off for new daemon homes, the
provider home directories (`.codex`, `.claude`, `.pi/agent`) created when the
runtime context is built, and one catalog refresh for a provider whose model list
was cached empty or failed.
Run `python3 scripts/verify-open-design-paseo.py` from the repository root to
verify the vendored source.

The chart (0.5.9 or later) starts the bridge inside the OpenDesign container when
`paseo.enabled` is set, supplies the canonical HTTPS origin and proxies the
setup page behind native basic authentication. The installed runtime alone does
not start a bridge without the chart configuration. The release workflow and PR
gate run `tests/paseo-image-smoke.mjs` against the actual compiled daemon as UID
1001: native launcher discovery, atomic MCP registration, unrelated-server
preservation, setup page and cross-origin rejection. These checks make no model
calls. Live HA/PaaS acceptance and immutable image pins are recorded separately.

**First activation contract (#448).** The managed `@getpaseo/cli` runtime (lock-pinned, `0.11.2`) is built into the PaaS
shell at `/opt/opendesign-paseo/managed-runtime` (`Dockerfile`, stage `paseo-runtime`, using the package's own
`runtime-layout` so the release path, lock hash and receipt are what the host verifies). The host package uses it in place,
read-only, once the receipt matches its lock: enabling Paseo runs **no `npm`**, needs **no registry access** and writes
**no runtime or npm cache to the data volume** (it used to write about 0.8 GB, over TCP/443, with a 300 s budget). A new
daemon home also starts with local dictation/voice mode off, because Paseo otherwise downloads about 0.7 GiB of speech
models from github.com when the daemon starts; a tenant can turn them on in Paseo's own settings (that needs github.com
TCP/443 and the space). Remaining network use is by design: provider APIs after login and the Paseo relay for pairing.
`tests/paseo-bundled-runtime-offline.sh` proves it in the candidate and PR gates: fresh container, `--network none`, a
256 MiB data volume, `npm` replaced by a failing stub, activation through the real HTTP bridge must reach `phase=running`.
An image without `managed-runtime` still falls back to the old on-volume `npm ci`; the gates fail such an image.

### Updating the vendored Paseo plugin

`paseo-runtime/` is a copy of a public release of `WOOWTECH/opendesign-paseo-plugin`; do not edit it by hand. To move to
another release (`<version>` is the release tag without the `v`):

```bash
python3 scripts/sync-open-design-paseo.py <version>      # download, verify, replace the directory, rewrite SOURCE.json
python3 scripts/verify-open-design-paseo.py --release    # the copy is exactly that published release
git diff --stat open-design/paseo-runtime
```

The sync needs only network access to github.com (no token). It requires the archive sha256 to equal both the release's
`SHA256SUMS` and the digest the GitHub API reports for the asset, takes the commit from the release's
`runtime-provenance.json` (checked the same way), extracts the archive in memory (absolute or `..` paths, symlinks, devices,
duplicates and executable files are refused) and adds the release's `package-lock.json`, which npm leaves out of the
archive. Running it for the version that is already vendored changes nothing. After a version change also update the
version and commit quoted above, and keep the HA add-on's copy on the same release.

`verify-open-design-paseo.py` without the flag stays the offline self-check of the directory against `SOURCE.json`. The PR
gate (`test-open-design-mcp.yml`) also runs it with `--release`: network errors are retried three times, and a GitHub that
stays unreachable fails the step with a message. `scripts/tests/test-open-design-paseo-release.py` (lint workflow) tests
the helpers offline.
