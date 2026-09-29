# open-design image

供 PaaS 平台 cloud service 使用的 **OpenDesign daemon** image（daemon :7457 + Next.js UI +
預裝 Claude Code / OpenCode 兩個 agent CLI + design 工具鏈）。

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/open-design:{tag}`
- 平台側（`woow_paas_platform` seed）會 **pin image digest**；chart 由 `woow-paas-charts` 建置。
- 對應 issue：`odoo-addons/woow_paas_platform#380`（支線 B）。

## 供應鏈 provenance

自 0.24.1 起**不再從原始碼 build open-design**，改以上游預建 image 為 base：

| 項目 | 來源 |
|------|------|
| base image | `ghcr.io/nexu-io/od:0.24.1@sha256:587a9928…`（上游 [nexu-io/open-design](https://github.com/nexu-io/open-design) `deploy/Dockerfile` 產出；node:24-alpine） |
| 上游 commit | `89e64d813bb1c7a11519b3f668f011f7017637d7`（image label `org.opencontainers.image.revision`，workflow 會印出） |
| 本層加的東西 | Claude Code、OpenCode、design 工具鏈、HOME 與 /etc/skel、build-time 版本契約 |

為什麼換：舊版 `git clone` + `pnpm build` 且多處 `|| true`，build 壞了也照樣產出 image；上游預建 image 與官方 release 位元一致，本層只疊加工具。

## 版本 pin（可重現性優先）

| 元件 | pin 版本 | 取得方式 |
|------|---------|---------|
| open-design | `0.24.1`（daemon package `0.23.1`） | base image，**index digest 雙釘** |
| `@anthropic-ai/claude-code` | `2.1.284` | `npm install -g`（musl 原生 binary） |
| `opencode-ai` | `1.18.33` | `npm install -g`（musl 原生 binary） |
| `svgo` / `@mermaid-js/mermaid-cli` / `sharp-cli` | `4.1.0` / `12.0.0` / `6.1.0` | `npm install -g` |
| `uv` / `uvx` | `0.12.20` | musl release tarball |

**build-time 契約**（`Dockerfile` 最後一個 `RUN`，以 uid 1001 執行）：claude／opencode 版本必須完全相等、
daemon 入口存在、所有工具在 PATH、python 套件可 import——任一不符 **build 直接失敗**，不再靜默產出。

**已知差異（相對 0.15.1 的 Debian image）**：base 變成 Alpine（musl）；python 端**沒有** playwright
（上游不支援 musl），瀏覽器一律用系統 `chromium-browser`（`PUPPETEER_*`／`PLAYWRIGHT_*` 環境變數已指向它）。

**版本更新流程**：改 `OD_BASE`（tag 與 digest 一起）與各 `ARG *_VERSION` → 重跑 workflow 產新 tag
→ 取新 digest → 回報平台側 re-pin（`woow_paas_platform` 的 open-design seed）。

## 如何 build

### 正式 pipeline（推薦，native amd64）

`.gitea/workflows/build-open-design-image.yml`：

- `workflow_dispatch`：填 `tag`（UTC 時戳 `YYYYMMDD.HHMM`）
- 或 push tag `open-design-v*`

runner 為 amd64，`docker build` 原生產出 amd64，透過內部 JCR service URL 推送（繞過 Traefik）。

### 本機一次性（arm64 需 QEMU 模擬 amd64）

```bash
TAG=$(date -u +'%Y%m%d.%H%M')
docker buildx build --platform linux/amd64 \
  -t jcr-prod.woowtech.io/woow-paas-docker-local/open-design:$TAG \
  --push open-design
docker manifest inspect -v \
  jcr-prod.woowtech.io/woow-paas-docker-local/open-design:$TAG
```
