#!/bin/sh
# Build-time install of the built-in OpenDesign MCP server (run as root from open-design/Dockerfile).
#
#   COPY --from=woow-mcp-ui /ui/dist /opt/woow/packages/mcp-admin-ui/dist
#   COPY mcp-runtime/ /tmp/mcp-runtime/
#   RUN sh /tmp/mcp-runtime/install.sh && rm -rf /tmp/mcp-runtime
#
# Installs the HA add-on's runtime (ha/, a pinned copy of WOOWTECH/Woow_ha_opendesign_add_on mcp-runtime, see
# HA_SOURCE.json) exactly as the add-on's own install.sh lays it out — /opt/woow = the vendored Woow_ha_mcp_addons
# tree + ha_opendesign_mcp, venvs on the core image's /usr/bin/python3 with ONLY the add-on's hash-pinned wheels —
# plus the PaaS placement (paas_opendesign_mcp, bin/paas-opendesign-mcp).
#
# Principal: mcp (uid/gid 10001), the user of the chart's `mcp` container. The daemon user (open-design, 1001) never
# belongs to its group. Unlike the add-on there is no ha-ingress user (nginx runs in its own container) and no root
# bootstrap (Kubernetes starts the container as uid 10001).
set -eu
export HOME=/root PIP_NO_CACHE_DIR=1

src=$(cd "$(dirname "$0")" && pwd)
ha=$src/ha
py=/usr/bin/python3
root=/opt/woow

test -x "$py"
test -f "$root/packages/mcp-admin-ui/dist/index.html"  # built by the woow-mcp-ui stage
"$py" -I "$src/tests/verify_ha_copy.py"

getent group mcp >/dev/null || addgroup -S -g 10001 mcp
getent passwd mcp >/dev/null || adduser -S -D -H -u 10001 -G mcp -h /data/mcp -s /sbin/nologin mcp
test "$(id -u mcp):$(id -g mcp)" = "10001:10001"
if id -nG open-design | tr ' ' '\n' | grep -qx mcp; then
  echo "open-design must not belong to group mcp" >&2
  exit 1
fi

mkdir -p "$root/bin"
cp -R "$ha/vendor/." "$root/"
rm -rf "$root/packages/mcp-admin-ui/src" "$root/packages/mcp-admin-ui/scripts" \
  "$root/packages/mcp-admin-ui/package.json" "$root/packages/mcp-admin-ui/package-lock.json"
cp -R "$ha/ha_opendesign_mcp" "$root/ha_opendesign_mcp"
cp -R "$src/paas_opendesign_mcp" "$root/paas_opendesign_mcp"
cp "$src/bin/paas-opendesign-mcp" "$root/bin/paas-opendesign-mcp"
cp "$ha/VENDOR.json" "$root/VENDOR.json"
cp "$src/HA_SOURCE.json" "$root/HA_SOURCE.json"

"$py" -m venv "$root/.venv"
"$root/.venv/bin/pip" install --no-cache-dir --disable-pip-version-check --no-deps --only-binary=:all: \
  --require-hashes -r "$ha/requirements/management.txt"
"$py" -m venv "$root/apps/opendesign/.venv"
"$root/apps/opendesign/.venv/bin/pip" install --no-cache-dir --disable-pip-version-check --no-deps \
  --only-binary=:all: --require-hashes -r "$ha/requirements/child.txt"
"$root/.venv/bin/pip" uninstall -y -q pip
"$root/apps/opendesign/.venv/bin/pip" uninstall -y -q pip

# Root-owned, read-only code; byte-code compiled now (the runtime sets PYTHONDONTWRITEBYTECODE).
"$root/.venv/bin/python" -m compileall -q "$root/packages" "$root/apps" "$root/packaging" \
  "$root/ha_opendesign_mcp" "$root/paas_opendesign_mcp" >/dev/null
chown -R root:root "$root"
chmod -R u=rwX,go=rX "$root"
chmod 0755 "$root/bin/paas-opendesign-mcp"

# Import-time checks. Management: the add-on's runtime imports, the PaaS placement replaces every add-on path
# (nothing under /run/ha-opendesign-mcp or the add-on's /data/mcp state, no 0.0.0.0 listener, no :7456 backend is
# left in any loaded ha_opendesign_mcp module; /data/mcp itself is only the PaaS mount root). Child: backend_policy.check_sources() (pinned httpx/httpcore
# sources), launch.py's FastMCP server and BoundedTools (pinned MCP SDK sources), as in the add-on.
PYTHONPATH="$root/packages/mcp-admin-core:$root" "$root/.venv/bin/python" -c '
import sys
from pathlib import Path
import mcp_admin_core.run_product
from paas_opendesign_mcp import launch, settings
runtime = launch.place(settings({}))
left = []
for name, module in list(sys.modules.items()):
    if name == "ha_opendesign_mcp" or name.startswith("ha_opendesign_mcp."):
        for key, value in vars(module).items():
            text = str(value)
            if (isinstance(value, (str, Path)) and (text.startswith("/run/ha-opendesign-mcp") or text == "0.0.0.0"
                    or ":7456" in text or (text.startswith("/data/mcp") and not text.startswith("/data/mcp/state")))):
                left.append("%s.%s=%s" % (name, key, text))
assert not left, left
from mcp_admin_core.products import TOOLS
print("HA runtime allowlist: %d OpenDesign tools: %s" % (len(TOOLS["opendesign"]), " ".join(sorted(TOOLS["opendesign"]))))
assert len(TOOLS["opendesign"]) == 15, sorted(TOOLS["opendesign"])
'
# The child as the add-on's install.sh checks it: the add-on's four bounded handlers (od_tools.install) replace the
# vendored ones before BoundedTools wraps them; 15 tools registered.
OD_API_BASE=http://127.0.0.1:7457 PYTHONPATH="$root/apps/opendesign/vendor:$root/apps/runtime:$root/apps/opendesign" \
  "$root/apps/opendesign/.venv/bin/python" -c '
import sys
sys.path.append("/opt/woow")
import launch
from bounded_tools import BoundedTools
from ha_opendesign_mcp import od_tools
od_tools.install(launch.mcp, launch.od)
workers = BoundedTools(launch.mcp, capacity=1)
workers.close()
assert len(launch.mcp._tool_manager.list_tools()) == 15
'
# The add-on's own unit tests of its tool overlay (rules, bounded handlers, surface), with this image's interpreters
# and pinned packages (loopback fake daemon, no network) — the same run the add-on's install.sh does.
HA_OD_MCP_CODE="$root" HA_OD_MCP_VENDOR="$root" sh "$ha/tests/unit/run.sh" "$root/.venv/bin/python" \
  "$root/apps/opendesign/.venv/bin/python"
echo "built-in MCP installed: HA runtime $(sed -n 's/.*"source_commit": "\([0-9a-f]*\)".*/\1/p' "$src/HA_SOURCE.json" | head -n1), vendored Woow_ha_mcp_addons $(sed -n 's/.*"source_commit": "\([0-9a-f]*\)".*/\1/p' "$ha/VENDOR.json")"
