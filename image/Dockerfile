# OpenDesign daemon image for the WOOW PaaS open-design cloud service = the PaaS shell
# around open-design-core (Dockerfile.core). Everything OpenDesign, the CLIs, the
# toolchain and the woow-patches are in the core; this file adds the runtime contract
# the chart relies on and the built-in OpenDesign MCP server (mcp-runtime/, run by the
# chart's `mcp` sidecar container from chart open-design 0.5.0). Omnigent is in the
# core and its native daemon owns host setup. build-open-design-image.yml builds the core first and
# passes its local tag as CORE; the last stage (paas) is the published image. No default
# on purpose: a build without the core fails.
ARG CORE

# --- Built-in Woow OpenDesign MCP server: admin UI assets (mcp-runtime/README.md) ---
# Built with the core image's own Node/npm from the vendored, lock-pinned UI sources; only
# dist/ is kept (the same stage as the HA add-on). --include=dev because the core
# sets NODE_ENV=production.
FROM ${CORE} AS woow-mcp-ui
USER root
WORKDIR /ui
COPY mcp-runtime/ha/vendor/packages/mcp-admin-ui/ ./
RUN /usr/local/bin/npm ci --include=dev --ignore-scripts --no-audit --no-fund \
    && /usr/local/bin/npm run build \
    && test -f dist/index.html

# --- Managed Paseo runtime (@getpaseo/cli, lock-pinned), built INTO the image (issue #448) ---
# The host package below used to run `npm ci` into the tenant data volume the first time Paseo was enabled: about
# 0.8 GB, registry TCP/443 and a 300 s budget, found out only at runtime. It is installed here instead, with the
# package's own layout module, so the release path, lock hash and receipt are exactly what the host verifies when
# it activates (src/runtime-context.mjs picks <package root>/managed-runtime). Same core = same node/npm/libc as the
# runtime that used to run npm. Nothing is written to the tenant volumes and nothing is downloaded at container start.
FROM ${CORE} AS paseo-runtime
USER root
COPY paseo-runtime/vendor/pi-paseo/ /opt/pi-paseo/
# The @getpaseo/* npm packages carry no LICENSE file; Paseo is Apache-2.0 (github.com/getpaseo/paseo, no NOTICE), so the
# text travels with the runtime now that the image redistributes it (Apache-2.0 section 4(a)).
COPY paseo-legal/getpaseo-Apache-2.0.txt /opt/opendesign-paseo/managed-runtime/LICENSES/getpaseo-Apache-2.0.txt
RUN set -eu; \
    export npm_config_cache=/tmp/npm-cache; \
    ROOT=$(node --input-type=module -e 'import {prepareRuntimeManifest} from "/opt/pi-paseo/src/runtime-layout.mjs"; console.log(prepareRuntimeManifest({runtimeDir:"/opt/opendesign-paseo/managed-runtime"}))'); \
    npm ci --prefix "$ROOT" --omit=dev --no-audit --no-fund; \
    test "$(node "$ROOT/node_modules/@getpaseo/cli/bin/paseo" --version)" = 0.11.2; \
    test -s "$ROOT/node_modules/@getpaseo/server/dist/server/web-ui/index.html"; \
    node --input-type=module -e 'import {markRuntimeReady,runtimeReady} from "/opt/pi-paseo/src/runtime-layout.mjs"; const loc={runtimeDir:"/opt/opendesign-paseo/managed-runtime"}; markRuntimeReady(loc); if(!runtimeReady(loc)) process.exit(1)'; \
    chmod -R a+rX,go-w /opt/opendesign-paseo/managed-runtime; \
    rm -rf /tmp/npm-cache /root/.npm

FROM ${CORE} AS shell-base

# --- Built-in Woow OpenDesign MCP server (mcp-runtime/README.md) ---
# The HA add-on's built-in MCP runtime, unchanged (mcp-runtime/ha/ = pinned copy of
# WOOWTECH/Woow_ha_opendesign_add_on mcp-runtime, HA_SOURCE.json: gateway, tool surface,
# defaults, protections, admin page), its hash-pinned wheels for the core's Python, user mcp
# (10001), plus the PaaS placement (paas_opendesign_mcp). Code is root-owned and read-only
# under /opt/woow; the chart runs /opt/woow/bin/paas-opendesign-mcp in its own container as
# uid 10001 with state on the od-data PVC (subPath).
USER root
COPY --from=woow-mcp-ui /ui/dist /opt/woow/packages/mcp-admin-ui/dist
COPY mcp-runtime/ /tmp/mcp-runtime/
# Same public, lock-pinned Paseo runtime as the HA shell. The native launcher and
# atomic MCP API are compiled in the shared core; the chart owns supervision.
COPY paseo-runtime/ /opt/opendesign-paseo/
RUN sh /tmp/mcp-runtime/install.sh && rm -rf /tmp/mcp-runtime \
    && cd /opt/opendesign-paseo \
    && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && node --input-type=module -e 'import {verifyBundledInstallation} from "./host/standalone.mjs"; if (!verifyBundledInstallation("/app/plugins/_official/woow/woow-paseo", process.cwd())) process.exit(1)' \
    && chmod -R a+rX,go-w /opt/opendesign-paseo
# Immutable, root-owned, read-only for uid 1001. The host package finds it from its own package root and uses it in
# place once its receipt matches the lock it ships (paseo-runtime/src/runtime-context.mjs); no environment variable.
COPY --from=paseo-runtime /opt/opendesign-paseo/managed-runtime /opt/opendesign-paseo/managed-runtime
USER open-design

WORKDIR /app
EXPOSE 7457
# The chart overrides this with --host <config.bindHost> --port <targetPort>
# (image.enforceBindHost); this default matches it for direct `docker run`.
CMD ["node", "apps/daemon/bin/od.mjs", "--host", "127.0.0.1", "--port", "7457", "--no-open"]

# The native daemon starts its bundled Omnigent host after GUI setup. Keep the
# legacy chart omnigentHost.enabled=false; never insert a second supervisor here.
FROM shell-base AS paas
ENTRYPOINT ["/sbin/tini", "--"]
# Setting ENTRYPOINT resets an inherited CMD; repeat it in the published stage.
CMD ["node", "apps/daemon/bin/od.mjs", "--host", "127.0.0.1", "--port", "7457", "--no-open"]
