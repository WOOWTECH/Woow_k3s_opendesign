# Woow OpenDesign（PaaS 版鏡像）

[English](README.md) · [來源與同步方式](MIRROR.md)

這個 repo 是 **WOOW PaaS 平台上 OpenDesign 雲端服務的唯讀鏡像**。
正式來源在內部 Gitea（`git-prod.woowtech.io`），所有修改都先在那裡經過審查與正式環境核可，
再用 [`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh) 同步過來。

> ⚠ 請不要直接改這裡的 `image/`、`console/`、`chart/`，下次同步會被覆蓋。

## 內容

| 目錄 | 內容 | 來源 |
|---|---|---|
| [`image/`](image/) | OpenDesign 主程式 image | Gitea `woow-paas/paas-odoo-ci` 的 `open-design/` |
| [`console/`](console/) | Console image（ttyd 網頁終端＋Flask 管理頁） | Gitea `woow-paas/paas-odoo-ci` 的 `open-design-console/` |
| [`chart/`](chart/) | 每個租戶一套的 Helm chart | Gitea `woow-paas/woow-paas-charts` 的 `charts/open-design/` |

目前版本與對應的來源 commit 見 [MIRROR.md](MIRROR.md)。

## 版本

| 元件 | 版本 |
|---|---|
| OpenDesign | **0.24.1**（以上游官方預建 image `ghcr.io/nexu-io/od` 為基底，digest 釘死） |
| Claude Code | **2.1.284** |
| OpenCode | **1.18.33** |
| Chart | **0.2.1** |

`image/Dockerfile` 最後一步是 build 時的檢查：Claude Code 與 OpenCode 版本必須完全相符、
所有工具都要在 PATH 上，任何一項不符 build 就會失敗，不會產出有問題的 image。

## 在 PaaS 上怎麼運作

- 使用者在平台 `/woow` 建立 open-design 服務後，operator 會在該工作區的 namespace 裝一套 chart。
- 每個服務有兩顆磁碟：資料（`/app/.od`）與 home（`/home/opendesign`，存 Claude 登入狀態與 OpenCode 設定）。
- 對外網址是平台配發的子網域，經 Cloudflare Tunnel 連進來。

### 登入與帳密管理

- OpenDesign 主程式只聽 `127.0.0.1`，外部只能經過同一個 pod 裡的 **nginx 驗證代理**（HTTP basic auth）進入。
- **ttyd 網頁終端與 console 管理頁使用同一組帳號密碼。**
- 帳號與密碼都可以在平台的服務頁 **「Admin Credentials」** 自行修改：
  - 帳號：1–64 字元（英數字與 `. _ @ -`）
  - 密碼：可選「平台隨機產生」（只顯示一次）或「自行設定」（12–128 字元、不含空白）
  - 存檔後主程式與 console 會重啟，約一分鐘後生效
- 選填的 API Key（Anthropic、OpenRouter）在服務的「設定」頁填寫，存在 Kubernetes Secret。

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 只做驗證、**不發佈**：

- `helm lint` ＋ chart 內建的所有測試
- 兩個 image 都 build 一次（不推送）

正式環境的 image 與 chart 由 Gitea 建置並發佈到私有 registry，過程需要人工核可。

## 重新同步

```bash
scripts/sync-from-gitea.sh                # 兩個來源都取 main
scripts/sync-from-gitea.sh <ci-ref> <charts-ref>
```

需要能讀取 Gitea 上的兩個 repo。

## 舊版（單機 k3s chart）

之前在 `pi-agent-woow` namespace、透過 Nginx Proxy Manager 對外的單機版（OpenDesign 0.21.1，
`od-woow-k3s.woowtech.io`）保存在 [`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance)
分支與 `v2.0.1` tag。該部署已於 2026-09-29 搬進 PaaS 平台。

## 授權

[MIT](LICENSE)
