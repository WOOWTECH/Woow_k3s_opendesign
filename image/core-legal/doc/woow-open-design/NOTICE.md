# WoowTech notice for open-design-core

This image contains **OpenDesign** (<https://github.com/nexu-io/open-design>), licensed
under the Apache License, Version 2.0. The full license text is in
`/usr/share/licenses/open-design/LICENSE`. Upstream OpenDesign ships no NOTICE file.

WoowTech (WOOWTECH) modified OpenDesign. As required by section 4(b) of the license,
this file states what was changed. The changes are distributed under the same
Apache-2.0 license.

## Source

| | |
|---|---|
| Upstream release | `open-design-v0.24.1` = `89e64d813bb1c7a11519b3f668f011f7017637d7` |
| WoowTech fork | `woow-paas/open-design` (WoowTech Gitea), commit recorded in the image label `io.woow.opendesign.source-revision` |
| Fork revision | `woow-od-v0.24.1-w2.11` = `05b23f5a5259d4f2c22e5c6e3eb92ce9103ed34a` |
| Image build | `woow-paas/paas-odoo-ci`, `open-design/Dockerfile.core` |

The image labels `io.woow.opendesign.source-revision` and
`io.woow.opendesign.upstream-revision` name the exact commits this image was built from.

## Changes in the WoowTech fork (on top of the upstream release)

The build fails when this list does not match the fork commits between the two
revisions above, so it is always complete for the image that carries it.

<!-- fork-commits:begin -->
- `06433424020c414fe0703b3dc3e36c332572a6dd` feat: add native Omnigent setup and installed-engine verification
- `d9bfb4fa738df3aaaa11caa26d2349bb17bad9dc` fix: fence stale Omnigent status snapshots
- `522941035c0f0c1f4ccfc5639f553954fe1af65e` fix: support native OpenCode models and reliable engine setup
- `2ad164d670690921ab212fef40ad0914a3572867` fix: wait for all native runners before connection probes
- `03816487508749c7467fb7abcf06de88231ddd4b` fix: open Omnigent in headless web clients and reproduce SDK patch
- `92c2cfa3a59affc30dc3a5bcbfae5f379e559b25` build: bundle WoowTech skill and plugin; skip unused onnxruntime CUDA download
- `584a1de05203c384ba166d077396bd38adf4e30d` build: compile better-sqlite3 against the node image's bundled headers
- `ba3a448d2f8955b39cba7d4fef45c9b0d5d3d464` build: ship better-sqlite3's prebuilt binary instead of the locally compiled one
- `1c7e697ef8a3d0aadd7b736b7110a3df83cf6ff5` build: stop bundling the Omnigent plugin for now
- `605efabdd33cc7bf86876c12d12f77429ef58384` feat(plugins): built-in MCP Server and CLI Terminal launcher plugins
- `b8a1371924d3aedb74dff563a5ff35a783919dee` feat(plugins): built-in launchers lead the default Plugins tab; translate scope tabs
- `92401c3305e9e6d49abb7fe2b25f02779d1b384f` feat(plugins): add bundled Paseo setup launcher
- `d83a189f0a033fb224d71a2539dae0e5cfa8c785` feat(daemon): add atomic MCP server CAS mutations
- `068a6ec1ed381eaa2490b5981a44ad8cd324bb14` feat(omnigent): native plugin launcher and private host runtime
- `cd2b9917fb742ab2359427c5a9f4dad787e95108` fix(omnigent): ship pinned SDK runtime on Alpine
- `704c8c8e3918dab80e03fb41cfda07e62f28ab9a` fix(omnigent): bound registry layers and align SDK selection
- `9c94b4be22bf4e571c094d1e145363dd985ff5f8` fix(omnigent): guide engine readiness failures to native CLI
- `f95a85bcd534c3b981b0a9a494b0c92f9dca480d` fix(omnigent): resume approved local hosts on daemon startup
- `fa6392cea049ee8e1116b46b302ef7420b38e098` feat(omnigent): guide native provider sign-in and explain quota errors
- `909cc4d6e556205640bbffcc326fc74699b026d7` build(omnigent): preserve current Paseo and native MCP base
- `eed756c556de74ebd943557442f9e020f8c73964` build(omnigent): retain inherited snapshot route patch
- `2b9716442b7d6ce4aa7501d0cfd20b4869f0d413` build(omnigent): patch only rebuilt snapshot web assets
- `2fef8017bba43aac3b94ffadbb8da15678016e83` fix(web): backport mobile native launcher actions
- `6a6687791963ed98d909f8e8b68e541f28e6c542` fix(web): keep native launcher actions usable on mobile
- `b3270069b93548bbfced8cb17fa90039fd88422a` build(omnigent): preserve deployed mobile launcher image
- `345687284bbb24538c272f77b942ff3cfe757389` docs(omnigent): ship native OpenCode model picker source patch
- `4af5992900037292fed09ea2d2ebf7570caa41d7` chore: preserve whitespace in distributable unified patches
- `7ddb09b8484d4c6a58be5603a9cc88dff5df34d6` docs(omnigent): publish reproducible server UI delivery metadata
- `828638f100a84357d7d4dbf56411683d9eea5dba` fix(omnigent): show exhausted quota during OpenCode retries
- `4c92e25efe5735ee41bf52bbac8399b31d01d9b3` fix(omnigent): abort OpenCode retries through its native API
- `d38fa37445a9b76eddfb2de1be08e8eb62ec94d9` ci: keep plugin tags from publishing the shared OD image
- `218ec61bb9240defb062f3b87663845db788c89a` Add verified Omnigent recovery tools and lifecycle acceptance
- `73a8fbf47a5eff67fac4ba89131ed2e48c27e504` docs(omnigent): record four-engine GUI and production backup acceptance
- `c8ae3900f9ff5d58f50d11f4055756f6e7f14a25` feat: release native Paseo launcher and atomic MCP updates
- `aa0f75f430b12fc1f82511d6af07e92418c7b6c6` Add verified application recovery evidence and sealed backup tools
- `11d0f7e4f7523da56c6955d327ee451c8c5c8cc5` feat(omnigent): merge native integration with isolated host setup
- `eb64ef3220815037572b4e3e3ffd3cd46a0f4e2a` fix(build): include verified SDK patches in native Docker context
- `888bb9e42ffa00241141505c13e2d87f3eb5a050` ci(gitea): validate native Omnigent integration
- `c3a691e2804d24dc9a1daf5ac5e3c3fbb4e4244e` fix(ci): run recovery suites without root privileges
- `f37830c5a725d6e14da8cce3878e0f40294cccc8` fix(omnigent): bound daemon-owned host shutdown and disable
- `10eff184732a8aa4915938717a473986e458dec7` docs(omnigent): describe host stop on disable and disconnect
- `8330bcb21e80fae8c4051c3bc42468610578dbe5` fix(omnigent): refresh approved restarts and stop disconnected hosts
- `f634a05d73b301b198e969e1a040cfd3956b9b03` fix(omnigent): stop owned hosts after failed disconnect
- `01441cbc17727d04a98d6207ef6953a43557a05a` fix(omnigent): restore private state permissions before startup
- `d7e7541cebc5e0bbd9481bfc093e8416b4681dc3` fix(web): allow first-run access to installed plugins
- `25ef2195a31f1992f7cba6d0e9db33498de35ec2` Merge pull request 'fix(web): open installed plugins during first-run model setup' (#8) from fix/paseo-first-run-plugins-20261026 into woow/omnigent-native-gui
- `0d4dc6160eea1e0128523384e8f949a269944b7e` fix(web): allow Omnigent settings during first run
- `a4aab4826857298fa01b6075ad50c3cd944b3fda` ci(omnigent): run first-run settings routing regression
- `46d0884e8b8226b698bc4b61c4271617047889f5` Merge pull request 'fix(web): allow Omnigent settings during first run' (#9) from fix/omnigent-first-run-settings-20261027 into woow/omnigent-native-gui
- `aed7c0c35d9456082c4b0cd4822e0132164840a4` fix(web): preserve HA Ingress deep links across reload
- `b91e791487a81a0e3227a6d8973d93676fc4d0d3` fix(omnigent): expose Pi custom provider models in picker
- `4ee902736ab39a530bbb33d51f1ac44dc23ee740` Merge pull request 'fix(web): preserve HA Ingress deep links across reload' (#10) from fix/ha-ingress-reload-20261027 into woow/omnigent-native-gui
- `8955515588025a0e3a44835809280e91dcc97dd5` fix(omnigent): merge OpenCode user configs in native sessions
- `6ebc63aacc582251b8bebe42b51d3056ff3374d2` Merge pull request 'fix(omnigent): merge OpenCode user configs in native sessions' (#11) from fix/ha-ingress-reload-20261027 into woow/omnigent-native-gui
- `9ffff30a706a04d022e1f73f207a7971cb18843b` fix(omnigent): ask Pi for models when its files name no provider
- `05b23f5a5259d4f2c22e5c6e3eb92ce9103ed34a` Merge pull request '⛔ 勿代 merge｜待覆核 — fix(omnigent): Pi 模型選單在金鑰只放環境變數時為空（檔案算不出選項時改問 pi --list-models）' (#12) from fix/pi-env-model-options-20261101 into woow/omnigent-native-gui
<!-- fork-commits:end -->

A native Omnigent integration (daemon routes, settings and setup dialog,
installed-engine verification, bundled plugin and daemon-owned host-kit), native OpenCode model support, fixes for
headless web clients, the bundled `woowtech-brand` skill, three bundled launcher plugins
(MCP Server, CLI Terminal and Paseo, which open the shell's protected setup pages), atomic single-server MCP updates and responsive launcher actions, and two build changes for the
WoowTech build network (no onnxruntime CUDA download; node-gyp uses the node image's own
headers). The runtime ships better-sqlite3's official prebuilt binary,
taken from upstream's digest-pinned release image, instead of the locally compiled one
(the local build against Node >= 24.19 headers aborts the daemon on GC, nodejs/node#65446).

The native Omnigent integration also restores approved logins using valid refresh
tokens, stops owned hosts on daemon shutdown, disable and disconnect, and tightens
restored private-state permissions before startup. Shutdown preserves credentials
and host identity for an approved restart; disconnect retains host identity for
reconnection.

The first-run routing fix lets users open the installed Plugins page, Paseo
setup launcher, and Omnigent settings before completing OpenDesign model onboarding.

## Changes made by this image to the built OpenDesign files

Each patch edits exact strings in the built output and fails the build when its target
is missing. Sources are in `paas-odoo-ci/open-design/woow-patches/`.

| Patch | Change |
|---|---|
| `deck-print.sh` (ISS-OD-01) | Deck "Save as PDF" prints every slide, not only the active one (print CSS rule added to the deck framework in the daemon, web bundle and skills). |
| `export-basehref.py` (ISS-OD-05) | PDF / new-tab export resolves project-relative assets against the project's raw directory instead of the site root. |
| `snapshot-inline-img.py` (ISS-OD-05) | "Export as image" inlines loaded project images as data URLs in the snapshot bridge (daemon and web copies). |
| `zh-tw-locale.py` + `zh-TW-s2twp.json` (ISS-OD-08) | Simplified-Chinese strings left in the zh-TW dictionary are converted to Traditional Chinese (OpenCC s2twp, reviewed mapping). |
| `white-label.py` (ISS-OD-11) | Every page retires the upstream experience survey and hides OpenDesign Cloud / community promotion. |
| `white-label-links.py` (#1439) | "Contact us" and leftover community links point to WoowTech support; no "switch to OpenDesign Cloud" callback; the "not signed in" error explains where to sign in on the platform. |

Other changes to the OpenDesign tree: the upstream `brainstorming` skill is removed
(`/app/skills/brainstorming`).

## Other software in this image

The image also contains third-party software that is not part of OpenDesign and keeps
its own license and terms, among others: Claude Code (`@anthropic-ai/claude-code`,
proprietary, "© Anthropic PBC. All rights reserved.", use subject to Anthropic's legal
agreements), Codex CLI, Pi coding agent, OpenCode, svgo, mermaid-cli, sharp-cli,
pptxgenjs, uv, python-pptx, Omnigent SDK 0.16.0 and Alpine Linux packages. Their license files ship with each
package (for example under `/usr/local/lib/node_modules/<package>/` and the
`*.dist-info/` directories of the Python environments).

Every published core includes Omnigent and its Python dependencies in
`/opt/omnigent/venv`.

Omnigent SDK changes are the five reviewed, hash-checked patches for OpenCode
host model options, quota-error forwarding, native interrupt handling, Pi
custom-provider and environment-key models, and OpenCode dual user config merging. They are applied to the bundled
read-only SDK; the native daemon packages the same patch set and starts its
host-kit after GUI setup. The image does not preset server, credentials or a
legacy configuration home, and contains no external host entry wrapper.
