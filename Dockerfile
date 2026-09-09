ARG BUILD_FROM=ghcr.io/nexu-io/od:0.21.1@sha256:441daca881e699657bacf28e0c27b16cd6be551dfff4bd63368dd74bec581f39
FROM ${BUILD_FROM}

USER root

ENV NODE_ENV=production \
    OD_BIND_HOST=127.0.0.1 \
    OD_PORT=7456 \
    OD_DATA_DIR=/data/opendesign \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    HOME=/data/opendesign/home \
    PATH=/opt/woow-opendesign/opencode/node_modules/.bin:${PATH}

# The browser comes from Alpine rather than being downloaded on first boot.
# playwright-core is locked independently in /opt/woow-opendesign/package-lock.json.
# No reverse proxy is installed here: on k3s the proxy is a separate sidecar
# container that terminates the pod-network connection and forwards to this
# container's loopback daemon. One process per container.
RUN apk add --no-cache \
      bash \
      chromium \
      font-noto-cjk \
      font-noto-emoji \
      fontconfig \
      su-exec \
    && rm -rf /var/cache/apk/*

# OpenCode resolves the passwd-home directory when it starts as UID 1001.
RUN mkdir -p /data/opendesign /home/open-design \
    && chown -R open-design:open-design /data /home/open-design

COPY runtime/package.json runtime/package-lock.json /opt/woow-opendesign/
COPY runtime/opencode/package.json runtime/opencode/package-lock.json /opt/woow-opendesign/opencode/
# The pinned upstream image installs Node/npm under /usr/local/bin but a build
# frontend may still supply a reduced PATH. Use the absolute npm path so podman
# builds on the lab host and docker/build-push-action in CI behave identically.
RUN /usr/local/bin/npm ci --omit=dev --prefix /opt/woow-opendesign \
    && /usr/local/bin/npm ci --omit=dev --prefix /opt/woow-opendesign/opencode \
    && test "$(su-exec open-design:open-design opencode --version)" = "1.18.29" \
    && /usr/local/bin/npm cache clean --force \
    && test "$(id -u open-design)" = "1001" \
    && test -x /usr/local/bin/node \
    && test -x /usr/local/bin/npm \
    && command -v opencode \
    && command -v bash \
    && command -v chromium-browser \
    && command -v su-exec \
    && chown -R open-design:open-design /opt/woow-opendesign

COPY rootfs/ /
RUN mkdir -p /data/opendesign \
    && chown -R open-design:open-design /data \
    && chmod 0755 \
      /usr/local/bin/k3s-opendesign \
      /opt/woow-opendesign/headless-entry.mjs \
      /opt/woow-opendesign/headless-renderer.mjs \
    && chown open-design:open-design \
      /opt/woow-opendesign/headless-entry.mjs \
      /opt/woow-opendesign/headless-renderer.mjs

ARG BUILD_VERSION=2.0.0
ARG BUILD_DATE
ARG BUILD_DESCRIPTION="OpenDesign for woow-k3s"
ARG BUILD_NAME="Woow k3s OpenDesign"
ARG BUILD_REF
ARG BUILD_REPOSITORY=WOOWTECH/Woow_k3s_opendesign

LABEL org.opencontainers.image.title="${BUILD_NAME}" \
      org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
      org.opencontainers.image.vendor="WOOWTECH" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${BUILD_REF}" \
      org.opencontainers.image.version="${BUILD_VERSION}"

# The Longhorn RWO volume is attached root:root, so PID 1 starts as root only
# long enough to create and chown the owned directories under /data/opendesign;
# the launcher then drops the single application process to the upstream
# open-design UID/GID 1001 with su-exec and execs it, so tini's child is the
# Node process and the kubelet's SIGTERM reaches it directly.
# Port 7456 is loopback-only and is deliberately never published on the pod
# network, so this image declares no exposed port.
USER root
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/k3s-opendesign"]
