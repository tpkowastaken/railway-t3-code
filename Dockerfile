FROM node:24-bookworm@sha256:e7add2a490bb17d97b485b8641bd88455fff7839ade0f5eba493c3508124d413

# Pinned versions: every deploy is the same build. .github/workflows/bump-versions.yml
# moves these (and the base image above) to the latest stable releases daily.
# T3: version + sha256 of t3-<v>-linux-x64.tar.gz from the release's SHA256SUMS.
ARG T3_VERSION=0.1.7
ARG T3_SHA256=c089892bf7922e2e73c6f44a5d1ea125c99f70e378c18361cbbed2fba1920e6c
ARG CLAUDE_CODE_VERSION=2.1.318
ARG CODEX_VERSION=0.166.0
ARG OPENCODE_VERSION=2.2.5

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV PORT=8080
ENV HOME=/data/home
ENV WORKSPACE_DIR=/data/workspaces
# Global npm installs live in /opt/npm, owned by the t3 user, so T3's in-app
# "Update" button for Claude/Codex works without root (a redeploy restores the pins).
ENV NPM_CONFIG_PREFIX=/opt/npm
# Tools agents install into $HOME (on the volume) persist; see "default global agent.md".
ENV PATH=/data/home/.local/bin:/data/home/.cargo/bin:/data/home/go/bin:/data/home/.bun/bin:/opt/npm/bin:$PATH
ENV DISABLE_AUTOUPDATER=1
ENV OPENCODE_DISABLE_AUTOUPDATE=1
# T3's built-in headless browser: Chrome's own sandbox needs kernel features
# Railway containers don't offer, so run it unsandboxed (the container is the
# isolation boundary).
ENV T3CODE_SERVER_BROWSER_SANDBOX=0
# glibc gives each thread its own malloc arena; capping them trims ~15 MB off
# T3's idle memory.
ENV MALLOC_ARENA_MAX=2

# docker-ce-cli and plugins: the CLI only. Railway can't run a Docker daemon, so
# it talks to a remote one (DOCKER_HOST, see start.sh).
# libnss3..fonts-*: libraries and fonts for T3's built-in headless browser
# (chrome-headless-shell, which T3 downloads into ~/.t3 on first use).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    wget \
    gnupg \
    ca-certificates \
    bash \
    tini \
    sudo \
    nginx \
    qrencode \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    tmux \
    vim \
    nano \
    less \
    htop \
    ripgrep \
    fd-find \
    jq \
    unzip \
    zip \
    tree \
    procps \
    locales \
    libnss3 \
    libglib2.0-0 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libatspi2.0-0 \
    libdbus-1-3 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libxkbcommon0 \
    libgbm1 \
    libasound2 \
    libexpat1 \
    fonts-liberation \
    fonts-noto-color-emoji \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod go+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
      docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# T3 Code from its checksum-verified release binary (the npm `t3` package would
# download it into the volume at boot), then the agents. Fail the build if any
# of them doesn't run.
RUN curl -fsSL -o /tmp/t3.tgz "https://github.com/pingdotgg/t3code/releases/download/v${T3_VERSION}/t3-${T3_VERSION}-linux-x64.tar.gz" \
    && echo "${T3_SHA256}  /tmp/t3.tgz" | sha256sum -c - \
    && mkdir -p /opt/t3 && tar xzf /tmp/t3.tgz -C /opt/t3 --strip-components=1 && rm /tmp/t3.tgz \
    && ln -s /opt/t3/t3 /usr/local/bin/t3 \
    && npm install --global \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "@opencode/cli@${OPENCODE_VERSION}" \
    && npm cache clean --force \
    && t3 --version && claude --version && codex --version && opencode --version

# Agents run as a normal user: Claude Code refuses its full-access mode as root.
# Passwordless sudo lets them still apt-get what a repo needs (`apt-persist`
# to keep it across restarts).
# nginx: `auto` sizes from the host's cores on Railway, not the container's limit.
RUN userdel -r node \
    && useradd -u 1000 -U -d /data/home -M -s /bin/bash t3 \
    && chown -R t3:t3 /opt/npm \
    && echo 't3 ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/t3 \
    && chmod 440 /etc/sudoers.d/t3 \
    && echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.bun/bin:/opt/npm/bin:$PATH"' > /etc/profile.d/local-bin.sh \
    && sed -i 's/^worker_processes .*/worker_processes 2;/' /etc/nginx/nginx.conf \
    && rm -f /etc/nginx/sites-enabled/default

# apt keeps its package lists and downloaded .debs on the volume, so start.sh can
# reinstall the packages from `apt-persist` on every boot quickly and mostly
# offline. The lock timeout makes an agent's apt-get wait for that restore.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && printf '%s\n' \
      'Dir::Cache::Archives "/data/system/apt/archives/";' \
      'Dir::State::Lists "/data/system/apt/lists/";' \
      'DPkg::Lock::Timeout "300";' \
      > /etc/apt/apt.conf.d/90persist-on-volume

COPY railway-pair.mjs railway-pair-password.jpg /opt/
COPY ["default global agent.md", "/opt/default-global-agent.md"]
COPY drop-file-cache apt-persist install-agent-instructions docker-forward /usr/local/bin/
COPY start.sh /usr/local/bin/start-t3
RUN chmod +x /usr/local/bin/start-t3 /usr/local/bin/drop-file-cache \
      /usr/local/bin/apt-persist /usr/local/bin/install-agent-instructions \
      /usr/local/bin/docker-forward

WORKDIR /data/workspaces
EXPOSE 8080

# Railway sends SIGTERM when replacing a deployment. Treat its conventional
# exit status (128 + 15) as a clean stop; preserve all other failure statuses.
ENTRYPOINT ["/usr/bin/tini", "-e", "143", "--"]
CMD ["/usr/local/bin/start-t3"]
