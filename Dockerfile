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