#!/usr/bin/env python3
"""Static metadata / pinning / secret-hygiene validation for Woow_k3s_opendesign.

Ported from the HA add-on's tests/validate.py and retargeted at the Helm chart.
Exit codes: 0 OK, 1 validation failures, 2 missing input (see lib/repolayout.py).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import repolayout as layout  # noqa: E402

import yaml  # noqa: E402

ROOT = layout.ROOT
CHART = layout.CHART
OPT_DIR = layout.OPT_DIR

UPSTREAM_IMAGE = "ghcr.io/nexu-io/od:0.21.1@sha256:441daca881e699657bacf28e0c27b16cd6be551dfff4bd63368dd74bec581f39"
CHART_VERSION = "2.0.0"
APP_VERSION = "0.21.1"
GHCR_IMAGE = "ghcr.io/woowtech/woow-k3s-opendesign"

errors: list[str] = []


def check(condition, message: str) -> None:
    if not condition:
        errors.append(message)


layout.require(who="static validation")

# The nginx.conf and export bridge are chart-owned (they live in the sidecar
# ConfigMap), so they are inspected as rendered, not as guessed source files.
artifacts = layout.ARTIFACTS
if not (artifacts / "nginx.conf").is_file() or not (artifacts / "od-export-bridge.js").is_file():
    layout.require(
        {
            "tests/.artifacts/nginx.conf": artifacts / "nginx.conf",
            "tests/.artifacts/od-export-bridge.js": artifacts / "od-export-bridge.js",
        },
        who="static validation (run tests/lib/extract-chart-assets.py first)",
    )

chart_meta = yaml.safe_load((CHART / "Chart.yaml").read_text(encoding="utf-8"))
values_text = (CHART / "values.yaml").read_text(encoding="utf-8")
values = yaml.safe_load(values_text)
package = json.loads((ROOT / "runtime/package.json").read_text(encoding="utf-8"))
opencode_package = json.loads((ROOT / "runtime/opencode/package.json").read_text(encoding="utf-8"))
opencode_lock = json.loads((ROOT / "runtime/opencode/package-lock.json").read_text(encoding="utf-8"))
workflow_text = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
workflow = yaml.safe_load(workflow_text)

dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
launcher = layout.LAUNCHER.read_text(encoding="utf-8")
entry = (OPT_DIR / "headless-entry.mjs").read_text(encoding="utf-8")
renderer = (OPT_DIR / "headless-renderer.mjs").read_text(encoding="utf-8")
nginx = (artifacts / "nginx.conf").read_text(encoding="utf-8")
export_bridge = (artifacts / "od-export-bridge.js").read_text(encoding="utf-8")

# ---------------------------------------------------------------- chart identity
check(isinstance(workflow, dict) and "jobs" in workflow, "GitHub Actions workflow YAML is invalid")
check(chart_meta.get("name") == "opendesign", "Chart name must be `opendesign`")
check(chart_meta.get("version") == CHART_VERSION, f"chart version must be {CHART_VERSION}")
check(str(chart_meta.get("appVersion")) == APP_VERSION, f"appVersion must be the OpenDesign version {APP_VERSION}")
check(chart_meta.get("apiVersion") == "v2", "chart apiVersion must be v2")
kube_version = str(chart_meta.get("kubeVersion") or "")
check(bool(re.search(r">=\s*1\.(?:2[4-9]|[3-9]\d)", kube_version)), "chart must declare kubeVersion >= 1.24")
check(not (CHART / "templates/namespace.yaml").exists(), "the chart must not create a namespace")

# `latest` is forbidden as a value anywhere. Comments are stripped first so a
# comment that explains the ban does not trip the ban.
for label, text in [
    ("Chart.yaml", (CHART / "Chart.yaml").read_text(encoding="utf-8")),
    ("values.yaml", values_text),
    ("Dockerfile", dockerfile),
    (".github/workflows/build.yml", workflow_text),
]:
    check("latest" not in layout.strip_comments(text).lower(), f"`latest` must not appear in {label}")

# ---------------------------------------------------------------- values surface
check(values.get("publicUrl") == "", "values.yaml publicUrl must ship empty so the install is forced to set it")
image_values = values.get("image") or {}
check(image_values.get("repository") == GHCR_IMAGE, f"image.repository must be {GHCR_IMAGE}")
check(image_values.get("digest", "") == "", "values.yaml must ship an empty image.digest")
check(image_values.get("pullPolicy") == "IfNotPresent", "image.pullPolicy must be IfNotPresent")
check(values.get("imagePullSecrets") == [], "imagePullSecrets must ship empty")
check("type" not in (values.get("service") or {}), "service.type must not be configurable (NPM is the only ingress path)")
check((values.get("nodeSelector") or {}) == {}, "nodeSelector must ship empty; Longhorn is distributed")
for key in ("secrets", "console", "mcp", "namespace"):
    check(key not in values, f"deleted values block is back: `{key}`")
for section in ("data",):
    persistence = (values.get("persistence") or {}).get(section) or {}
    check(persistence.get("storageClassName") == "longhorn", f"persistence.{section}.storageClassName must be `longhorn` (Retain)")
backup_values = values.get("backup") or {}
check(backup_values.get("enabled") is True, "backup must default to enabled; Longhorn has no working backup target")
check((backup_values.get("persistence") or {}).get("storageClassName") == "longhorn", "backup PVC must use the `longhorn` (Retain) class")
check(bool(values.get("nginx", {}).get("requireOriginOnMutation", False)), "nginx.requireOriginOnMutation must default true")
check((CHART / "values.schema.json").is_file(), "values.schema.json must ship so `helm lint` enforces the values contract")

# ------------------------------------------------------------- secret hygiene
# This is the check that would have caught values.yaml:157
#   mcpJwtSecret: "20b2769b...a06a09"   (a real 64-hex JWT key)
#   mcpAdminPassword: "admin"
#   tuiPassword: "changeme-ttyd-admin-password"
def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


# When the chart lives at the repository root, skip the directories that are not
# part of the chart: the test suite's own fixtures legitimately contain a
# digest-shaped literal, and .git/.github are not chart surface.
SKIP_DIRS = {".git", ".github", "tests", "docs", "node_modules", "k8s-manifests", "ci"}
chart_files = sorted(
    path for path in CHART.rglob("*")
    if path.is_file()
    and path.suffix in {".yaml", ".yml", ".json", ".tpl", ".txt"}
    and not (set(path.relative_to(CHART).parts[:-1]) & SKIP_DIRS)
)
check(bool(chart_files), "no chart files found to scan for secrets")
# Keys whose *name* contains a secret word but which never carry a credential.
ALLOWED_SECRET_KEYS = {
    "imagepullsecrets",
    "automountserviceaccounttoken",
    "serviceaccounttoken",
    "secretname",
    "secretkeyref",
}
secret_key = re.compile(r"password|passwd|token|secret|apikey|api_key", re.I)
assignment = re.compile(r"^\s*(?:-\s*)?([A-Za-z_][\w.-]*)\s*:\s*(.+?)\s*$")
empty_values = {"", "[]", "{}", "null", "~", "false", "true", '""', "''"}
hex64 = re.compile(r"\b[0-9a-f]{64}\b")
placeholder_word = re.compile(r"changeme|PLACEHOLDER", re.I)
for path in chart_files:
    body = layout.strip_comments(path.read_text(encoding="utf-8", errors="replace"))
    relative = rel(path)
    check(not hex64.search(body), f"64-hex secret-shaped literal committed in {relative}")
    check(not placeholder_word.search(body), f"placeholder credential literal in {relative}")
    if path.suffix not in {".yaml", ".yml", ".json"}:
        continue
    for line in body.splitlines():
        match = assignment.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if not secret_key.search(key) or key.lower() in ALLOWED_SECRET_KEYS:
            continue
        if value in empty_values or value.startswith("{{"):
            continue
        check(False, f"credential-shaped assignment in {relative}: {key}: {value}")

# ------------------------------------------------------- security inversions
# Scan the RENDERED manifests, not the template source. `_helpers.tpl` and
# NOTES.txt legitimately name OD_API_TOKEN / OD_DISABLE_API_AUTH inside the
# `fail` guard that REJECTS those keys -- scanning source would flag the
# defence as if it were the vulnerability. What ships to the API server is
# what matters, so render first and scan that.
_SOURCE_EXEMPT = {"_helpers.tpl", "NOTES.txt"}
chart_text = "\n".join(
    layout.strip_comments(path.read_text(encoding="utf-8", errors="replace"))
    for path in chart_files if path.name not in _SOURCE_EXEMPT
)
_rendered = layout.render_chart()
if not _rendered:
    print("  SKIP: helm not on PATH -- the security-inversion scan covered chart SOURCE only, "
          "not rendered output. Install helm to run this check properly.")
chart_text = chart_text + "\n" + layout.strip_comments(_rendered)
for needle, label in [
    ("OD_DISABLE_API_AUTH", "the disabled-auth inversion"),
    ("OD_API_TOKEN", "an API token the loopback bind makes unnecessary"),
    ("__K3S_NODE_HOSTNAME__", "the placeholder that makes `helm install` fail"),
    ("pullPolicy: Never", "an unpullable image policy"),
    ("localhost/open-design", "a local-only image reference"),
    ("localhost/od-mcp", "a local-only MCP image reference"),
    ("ttyd", "the withdrawn console"),
    ("od-mcp", "the withdrawn MCP sidecar"),
    ("od-console", "the withdrawn console"),
    ("pods/exec", "console RBAC"),
]:
    check(needle not in chart_text, f"forbidden chart content present: {needle} ({label})")
check(not re.search(r"OD_BIND_HOST[\"']?\s*:?=?\s*[\"']?0\.0\.0\.0", chart_text), "OD_BIND_HOST must never be 0.0.0.0")
# `__OD_EXPORT_BRIDGE_INSTALLED__` is a JS idempotence global that line ~291
# below explicitly REQUIRES; without this exemption the scan forbids the very
# token the suite mandates. Every other dunder still trips it -- the real
# target is an unsubstituted manifest placeholder like __K3S_NODE_HOSTNAME__.
_placeholder_scan = chart_text.replace("__OD_EXPORT_BRIDGE_INSTALLED__", "")
check(not re.search(r"__[A-Z0-9_]+__", _placeholder_scan), "unsubstituted __PLACEHOLDER__ token in a chart file")

for removed in [
    "console",
    "Dockerfile.open-design",
    "headless-renderer.py",
]:
    check(not (ROOT / removed).exists(), f"withdrawn component remains: {removed}")
for pattern in ("templates/console-*.yaml", "templates/mcp-*.yaml", "templates/secret*.yaml", "templates/namespace.yaml"):
    stragglers = list(CHART.glob(pattern))
    check(not stragglers, f"withdrawn chart template remains: {[str(p) for p in stragglers]}")

# ------------------------------------------------------------------- image pin
check(re.search(rf"^ARG BUILD_FROM={re.escape(UPSTREAM_IMAGE)}$", dockerfile, re.M), "Dockerfile base must pin the approved upstream digest")
check("EXPOSE" not in dockerfile, "Dockerfile must not expose a port")
check("OD_DATA_DIR=/data/opendesign" in dockerfile, "OD_DATA_DIR persistence is missing")
check("OD_BIND_HOST=127.0.0.1" in dockerfile, "Dockerfile must set loopback bind")
check("OD_PORT=7456" in dockerfile, "Dockerfile must set the daemon port")
check(re.search(r"^USER root$", dockerfile, re.M), "PID 1 must start as root to prepare the root-owned Longhorn mount")
check("PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1" in dockerfile, "Chromium must come from apk, never a Playwright download")
check("PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser" in dockerfile, "Playwright must use the apk Chromium")
for expected in ["bash", "chromium", "font-noto-cjk", "font-noto-emoji", "fontconfig", "su-exec"]:
    check(expected in dockerfile, f"expected image package missing: {expected}")
check(not re.search(r"(?:apk add[^\n]*\s|\s)nginx(?:\s|$)", layout.strip_comments(dockerfile)), "nginx must not be installed in the image; it is a separate sidecar container")
check("/usr/local/bin/npm ci --omit=dev" in dockerfile, "locked production npm install must use the absolute npm path")
check("test -x /usr/local/bin/npm" in dockerfile, "image build must verify the absolute npm executable")
check("test -x /usr/local/bin/node" in dockerfile, "image build must verify the absolute node executable")
check('test "$(id -u open-design)" = "1001"' in dockerfile, "image build must assert the runtime UID")
check("/usr/local/bin/npm ci --omit=dev --prefix /opt/woow-opendesign/opencode" in dockerfile, "OpenCode install must use the locked production package prefix")
check('test "$(su-exec open-design:open-design opencode --version)" = "1.18.29"' in dockerfile, "image build must assert the exact OpenCode version as UID 1001")
check("PATH=/opt/woow-opendesign/opencode/node_modules/.bin:${PATH}" in dockerfile, "OpenCode binary must be on PATH")
check("io.hass." not in dockerfile, "Home Assistant add-on labels must not survive the port")
check("org.opencontainers.image.source" in dockerfile, "the OCI source label must be set")
check("WOOWTECH/Woow_k3s_opendesign" in dockerfile, "the OCI source label must identify this repository")
check("/usr/local/bin/k3s-opendesign" in dockerfile, "ENTRYPOINT must run the k3s launcher")

# --------------------------------------------------------------- runtime pins
check(package.get("dependencies") == {"playwright-core": "1.55.0"}, "renderer dependency must remain exactly pinned")
opencode_root_lock = opencode_lock.get("packages", {}).get("", {})
opencode_launcher_lock = opencode_lock.get("packages", {}).get("node_modules/opencode-ai", {})
check(opencode_package.get("dependencies") == {"opencode-ai": "1.18.29"}, "OpenCode package must contain only the approved exact dependency")
check(opencode_package.get("private") is True, "OpenCode runtime package must stay private")
check(opencode_root_lock.get("dependencies") == {"opencode-ai": "1.18.29"}, "OpenCode lock root must use the approved exact version")
check(opencode_launcher_lock.get("version") == "1.18.29", "OpenCode lock resolves an unexpected version")
check(opencode_launcher_lock.get("integrity") == "sha512-syIDVwlrYTgTOXzZe9SkInJWethbq6l3SNC762UeXyO0a9V0wGfd+U4yACvppwNBnhIsl0j2QPYYCyLpNaSomg==", "OpenCode launcher integrity mismatch")
check(opencode_launcher_lock.get("bin", {}).get("opencode") == "bin/opencode.exe", "OpenCode lock must expose the opencode executable")
check(opencode_launcher_lock.get("license") == "MIT", "OpenCode lock license must remain MIT")
for platform_package, integrity in {
    "opencode-linux-x64-musl": "sha512-bGAZ9NFzNOzrXVN9oczd1H+vzLH1aGyYg1ZZNtuZiszxKr8+vTjLnNcjzGJIuc6jtjvlWbfp8l+S5fxCVuQo2A==",
    "opencode-linux-arm64-musl": "sha512-9lNhNvW3FdwbI+BDy/y+0bwIQkbz36u/RVQoZH2tYvWjHkOaf8D+mSuDKbKcFqpLFIbbQona01oYSQZzncZIcQ==",
}.items():
    platform_lock = opencode_lock.get("packages", {}).get(f"node_modules/{platform_package}", {})
    check(platform_lock.get("version") == "1.18.29" and platform_lock.get("integrity") == integrity, f"OpenCode {platform_package} lock integrity mismatch")

# ------------------------------------------------------------ renderer integrity
check("canonicalizeOutputDir" in renderer and "canonical outputDir escapes" in renderer, "canonical output confinement missing")
check("evaluateRequestPolicy" in renderer and "allowPublicHttpAssets: true" in renderer, "renderer network policy missing")
check("context.route" in renderer and "serviceWorkers: 'block'" in renderer, "renderer policy must cover popups/workers")
check("context.routeWebSocket" in renderer and "WebSockets disabled in renderer" in renderer, "renderer must block WebSockets at browser-context level")
check("new Semaphore(1)" in renderer and "MAX_REMOTE_FETCHES" in renderer, "renderer concurrency controls missing")
check("runWithAbsoluteDeadline" in renderer and "AbortController" in renderer, "renderer absolute abortable deadline missing")
check("mkdtemp(" in renderer and "XDG_CONFIG_HOME" in renderer and "XDG_CACHE_HOME" in renderer, "renderer Chromium must use an ephemeral writable HOME/XDG profile")
check("--disable-web-security" not in renderer, "renderer must not disable browser web security")
for limit in ["MAX_SLIDES", "MAX_PIXELS", "MAX_OUTPUT_BYTES", "MAX_HTML_BYTES", "MAX_REMOTE_TOTAL_BYTES", "RENDER_TIMEOUT_MS"]:
    check(limit in renderer, f"renderer budget missing: {limit}")

check("startServer" in entry and "desktopSlideRenderer: renderSlides" in entry, "slide renderer injection missing")
check("desktopPdfExporter" not in entry and "exportPdf" not in entry, "misleading desktop vector PDF exporter must not be injected")
check("host = '127.0.0.1'" in entry, "OpenDesign entry must bind loopback")
check("/app/apps/daemon/dist/server.js" in entry, "entry must import the daemon by absolute path")

# ------------------------------------------------------------------- launcher
check("su-exec open-design:open-design" in launcher, "launcher must drop OpenDesign to UID/GID 1001")
check("prepare_owned_dir" in launcher and "chown -h" in launcher, "privileged data preparation must fail closed on symlinks")
check("remove_obsolete_credentials" in launcher, "launcher must safely remove obsolete credential symlinks")
check("exit 78" in launcher, "launcher must refuse to run unprivileged (exit 78)")
check(re.search(r"^exec su-exec open-design:open-design .*headless-entry\.mjs", launcher, re.M), "launcher must exec a single process; Kubernetes delivers signals")
for forbidden in ["wait -n", "nginx_pid", "terminate_children", "SHUTDOWN_GRACE_SECONDS", "/usr/sbin/nginx"]:
    check(forbidden not in launcher, f"the two-process HA watchdog must not be ported: {forbidden}")
check("OD_BIND_HOST" in launcher and "127.0.0.1" in launcher, "launcher must export the loopback bind")

# -------------------------------------------------------- nginx sidecar config
check("proxy_pass http://127.0.0.1:7456" in nginx, "nginx may only forward to loopback OpenDesign")
check("proxy_set_header Host 127.0.0.1:7456" in nginx, "nginx must normalise Host to the loopback form OD accepts")
check("listen 7457" in nginx, "sidecar must listen on the unprivileged pod-network port 7457")
check("/tmp/od-nginx" in nginx, "unprivileged nginx temp paths missing")
check("proxy_buffering off" in nginx and "proxy_request_buffering off" in nginx, "streaming hygiene missing")
check("connection_upgrade" in nginx, "WebSocket upgrade map missing")
check("client_max_body_size 256M" in nginx, "upload body limit missing")
nginx_code = layout.strip_comments(nginx)
check("auth_basic" not in nginx_code, "the sidecar must never authenticate; NPM's Access List is the auth boundary")
check("X-Ingress-Path" not in nginx_code and "safe_ingress_path" not in nginx_code and "hassio_ingress" not in nginx_code, "HA ingress path machinery must not be ported")
check(not re.search(r"proxy_set_header\s+Origin\s+\"\"", nginx_code), "Origin must be forwarded unchanged so OD's cross-site rejection still works")
sub_filters = re.findall(r"^\s*sub_filter\s+", nginx_code, re.M)
check(len(sub_filters) == 1, f"exactly one sub_filter (the <head> injection) is allowed, found {len(sub_filters)}")
check("od-export-bridge.js" in nginx_code, "the sub_filter must inject the export bridge")
check('proxy_set_header Accept-Encoding ""' in nginx_code, "sub_filter cannot see a compressed body")
check("$http_origin" in nginx_code and "403" in nginx_code, "strict-CSRF guard for mutating requests without an Origin is missing")

check("redirectPdfRequest" in export_bridge, "browser PDF export bridge missing")
check("__OD_INGRESS_PATH__" not in export_bridge, "the HA ingress install gate must be removed from the bridge")
check("__OD_EXPORT_BRIDGE_INSTALLED__" in export_bridge, "the bridge must keep an idempotence flag")

# ------------------------------------------------------------------- Pi fence
for removed_path in [
    "runtime/pi",
    "rootfs/usr/local/bin/pi",
    OPT_DIR.relative_to(ROOT) / "ha-pi-wrapper.mjs",
    OPT_DIR.relative_to(ROOT) / "ha-byok-store.mjs",
    OPT_DIR.relative_to(ROOT) / "ha-byok-profiles-bridge.js",
    OPT_DIR.relative_to(ROOT) / "ha-ingress.js",
]:
    check(not (ROOT / removed_path).exists(), f"withdrawn component remains: {removed_path}")

runtime_sources = "\n".join([
    dockerfile,
    launcher,
    entry,
    renderer,
    export_bridge,
    nginx,
    (ROOT / "runtime/package.json").read_text(encoding="utf-8"),
    (ROOT / "runtime/opencode/package.json").read_text(encoding="utf-8"),
    (ROOT / "runtime/opencode/package-lock.json").read_text(encoding="utf-8"),
])
check(not re.search(r"@earendil-works/pi-coding-agent|pi-coding-agent|pi-web", runtime_sources), "withdrawn Pi runtime package reference detected")

for pattern, label in [
    (r"(?:^|[\s=:/])docker\.sock(?:$|[\s])", "container socket"),
    (r"(?:^|\s)--privileged(?:\s|$)", "privileged mode"),
    (r"(?:^|\s)--network[= ]host(?:\s|$)", "host networking"),
    (r"(?:^|\s)(?:claude|codex|aider|gemini|cursor-agent|qwen|copilot|amp)(?:@|\s|$)", "unapproved local AI CLI package"),
    (r"(?<![\w.\-])/(?:mnt|media|share|config)(?:/|\s|$)", "host path coupling"),
]:
    check(not re.search(pattern, runtime_sources, re.I | re.M), f"forbidden runtime coupling detected: {label}")

# ------------------------------------------------------------------ CI policy
check("container-smoke.sh" in workflow_text and "load: true" in workflow_text, "real amd64 container smoke lane missing")
check("linux/amd64" in workflow_text, "CI must build linux/amd64")
check("linux/arm64" not in workflow_text, "every cluster node is amd64; the arm64 leg and QEMU are dropped")
check(GHCR_IMAGE in workflow_text, "CI GHCR image name mismatch")
check(workflow.get("permissions") == {"contents": "read"}, "top-level workflow permissions must be contents:read only")
check(UPSTREAM_IMAGE in workflow_text, "workflow build inputs must pin the approved upstream digest")
for action_ref in re.findall(r"uses:\s*[^\s]+@([^\s#]+)", workflow_text):
    check(bool(re.fullmatch(r"[0-9a-f]{40}", action_ref)), f"GitHub Action is not pinned to a full commit SHA: {action_ref}")

for required in ["README.md", "README_zh-TW.md", "DOCS.md", "CHANGELOG.md", "LICENSE"]:
    check((ROOT / required).is_file(), f"missing required file: {required}")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    print(f"\n{len(errors)} validation failure(s). {layout.describe()}", file=sys.stderr)
    sys.exit(1)
print(f"metadata/runtime validation: OK ({layout.describe()})")
