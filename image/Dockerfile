# OpenDesign daemon image for the WOOW PaaS open-design cloud service.
#
# Base = the upstream prebuilt image (nexu-io/open-design deploy/Dockerfile,
# node:24-alpine, WORKDIR /app, daemon at apps/daemon, data dir /app/.od,
# user open-design uid/gid 1001). Building on it instead of cloning + pnpm
# building the app here keeps the daemon byte-identical to upstream's release
# and drops the old best-effort `|| true` source build.
#
# Pinned by INDEX digest (multi-arch); the platform is amd64-only.
# Bump = change the tag AND the digest together, then re-pin the platform seed.
ARG OD_BASE=ghcr.io/nexu-io/od:0.24.1@sha256:587a992857d0f8b71011e4bc55c5851e33ef9fc4c169fc17e6447700ac428f22
FROM ${OD_BASE}

ARG CLAUDE_CODE_VERSION=2.1.284
ARG OPENCODE_VERSION=1.18.33
ARG SVGO_VERSION=4.1.0
ARG MERMAID_CLI_VERSION=12.0.0
ARG SHARP_CLI_VERSION=6.1.0
ARG UV_VERSION=0.12.20

USER root

# Puppeteer (pulled in by mermaid-cli) must not download its own Chrome:
# there is no glibc Chrome for Alpine. It uses the Alpine chromium below.
ENV PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Toolchain the agents (Claude Code / OpenCode) and design skills call out to.
# libgcc/libstdc++ + ripgrep are Claude Code's documented Alpine prerequisites.
# poppler-utils, tini, git and bash already come from the base image.
RUN apk add --no-cache \
      bash curl ca-certificates git jq ripgrep unzip wget tmux \
      libgcc libstdc++ \
      chromium font-noto-cjk font-noto-emoji fontconfig ttf-dejavu \
      ffmpeg sox pngquant ghostscript vips-tools \
      python3 py3-pip \
    && fc-cache -f

# Agent CLIs + design npm tools, all pinned. Every version is asserted below:
# a mismatch or a missing binary FAILS the build instead of shipping silently
# (the previous image swallowed install failures with `|| echo`).
RUN npm install -g --omit=dev \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
      "svgo@${SVGO_VERSION}" \
      "@mermaid-js/mermaid-cli@${MERMAID_CLI_VERSION}" \
      "sharp-cli@${SHARP_CLI_VERSION}" \
    && npm cache clean --force

# uv / uvx (musl build; the platform is amd64-only).
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
      | tar xz -C /tmp \
    && install -m 0755 /tmp/uv-x86_64-unknown-linux-musl/uv /tmp/uv-x86_64-unknown-linux-musl/uvx /usr/local/bin/ \
    && rm -rf /tmp/uv-*

# Python helpers used by design skills (search, HTTP, imaging, templating).
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir \
         ddgs anthropic openai httpx requests aiohttp websockets \
         pillow lxml rich Jinja2 Markdown PyYAML click

# Home directory. The chart mounts the od-home PVC at /home/opendesign, which
# hides whatever the image puts there, so the dotfiles live in /etc/skel and
# the chart's seed-home init container copies them in (seed-if-absent).
# The upstream user is a system user with no home and /sbin/nologin; point its
# passwd entry at the real home and bash, since tools that read the passwd
# home (OpenCode among them) would otherwise resolve a missing directory.
RUN mkdir -p /home/opendesign /etc/skel \
    && printf '%s\n' \
         '# ~/.bashrc — seeded once by the chart; yours to edit.' \
         'export PATH="/opt/venv/bin:$PATH"' \
         'PS1='"'"'\u@opendesign:\w\$ '"'"'' \
         > /etc/skel/.bashrc \
    && printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > /etc/skel/.profile \
    && printf '%s\n' '# ~/.bash_logout' > /etc/skel/.bash_logout \
    && cp /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout /home/opendesign/ \
    && awk -F: 'BEGIN{OFS=":"} $1=="open-design"{$6="/home/opendesign";$7="/bin/bash"} {print}' /etc/passwd > /tmp/passwd \
    && cat /tmp/passwd > /etc/passwd && rm /tmp/passwd \
    && chown -R open-design:open-design /home/opendesign /app/.od

ENV HOME=/home/opendesign \
    PATH=/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    USE_BUILTIN_RIPGREP=0 \
    NODE_OPTIONS=--max-old-space-size=4096 \
    OD_BIND_HOST=127.0.0.1 \
    OD_PORT=7457

# Build-time contract. Runs as the runtime user so a binary that only works
# for root fails here, not in a tenant pod.
USER open-design
RUN set -e; \
    test "$(id -u)" = "1001"; \
    test "$(getent passwd open-design | cut -d: -f6)" = "/home/opendesign"; \
    test -f /app/apps/daemon/bin/od.mjs; \
    test -f /app/apps/daemon/dist/cli.js; \
    v=$(claude --version | awk '{print $1}');   test "$v" = "${CLAUDE_CODE_VERSION}" || { echo "claude $v != ${CLAUDE_CODE_VERSION}"; exit 1; }; \
    v=$(opencode --version | tr -d '[:space:]'); test "$v" = "${OPENCODE_VERSION}"   || { echo "opencode $v != ${OPENCODE_VERSION}"; exit 1; }; \
    for b in node npm git bash rg jq curl chromium-browser ffmpeg pdftotext svgo mmdc sharp uv uvx python3; do \
      command -v "$b" >/dev/null || { echo "missing: $b"; exit 1; }; \
    done; \
    /opt/venv/bin/python -c 'import ddgs, anthropic, openai, httpx, PIL, lxml, jinja2, yaml'; \
    echo "contract OK: claude ${CLAUDE_CODE_VERSION}, opencode ${OPENCODE_VERSION}"

WORKDIR /app
EXPOSE 7457
ENTRYPOINT ["/sbin/tini", "--"]
# The chart overrides this with --host <config.bindHost> --port <targetPort>
# (image.enforceBindHost); this default matches it for direct `docker run`.
CMD ["node", "apps/daemon/bin/od.mjs", "--host", "127.0.0.1", "--port", "7457", "--no-open"]
