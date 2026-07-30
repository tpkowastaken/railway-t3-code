FROM node:24-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/data/home
ENV WORKSPACE_DIR=/data/workspaces

RUN apt-get update && apt-get install -y \
    git \
    openssh-client \
    curl \
    ca-certificates \
    bash \
    tini \
    build-essential \
    python3 \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install Codex CLI and T3 Code.
RUN npm install --global \
    @openai/codex@latest \
    t3@latest

COPY start.sh /usr/local/bin/start-t3
RUN chmod +x /usr/local/bin/start-t3

WORKDIR /data/workspaces

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-t3"]