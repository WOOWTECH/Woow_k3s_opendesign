# open-design-console image

OpenDesign **console** 專用 baked image：把 console pod 需要的工具（web terminal
`ttyd`、`kubectl`、Flask dashboard 的 Python 依賴）預先烤進 image，讓 runtime
container **不做任何網路下載**，解掉上游「開機 runtime-install（curl 拉
GitHub / dl.k8s.io）」反模式——租戶 NetworkPolicy egress 受限下更穩定。

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/open-design-console:{tag}`
- 對應 issue：`odoo-addons/woow_paas_platform#380`（支線 B，第二顆 image）。
- chart（支線 A）的 `console.image` 預設指向此座標。

## 設計要點

- **app code 不 bake**：`app.py` / `entrypoint.py` / `connect.sh` / `index.html` 由
  chart 從 ConfigMap 於啟動時注入（掛 `/mnt/scripts` + `/mnt/html` → copy 進 `/app`），
  故 app 改動免重建 image；本 image 穩定、少重建（僅工具升版時）。
- 執行：`python /app/entrypoint.py`（ttyd :7681 + Flask :18790）。

## 供應鏈 provenance / pin

| 項目 | 來源 / pin |
|------|-----------|
| Dockerfile 上游 | [woow-paas-charts](https://git-prod.woowtech.io/woow-paas/woow-paas-charts) PR #41 `charts/open-design/Dockerfile.console`（branch `feat/open-design-chart`, sha `5c3b5c1`） |
| base image | `python:3.9-slim` |
| ttyd | `1.7.7`（x86_64 static） |
| kubectl | `v1.36.2`（**依 pin 鐵律**：上游原為空字串 → build 時抓 `stable.txt`，vendored 時改 pin 當下 stable） |
| Flask / requests | `3.1.0` / `2.32.3` |

> pin 目的：可重現性優先。升版流程同 open-design：改 pin → 重跑 workflow → `docker manifest inspect -v` 取新 digest → 回報平台 re-pin。

## 如何 build

正式 pipeline：`.gitea/workflows/build-open-design-console-image.yml`
（`workflow_dispatch` 填 `tag`，或 push tag `open-design-console-v*`；native amd64、內部 JCR 推送、含 prod approval gate）。
