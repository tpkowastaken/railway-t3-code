#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/data/home}"
export WORKSPACE_DIR="${WORKSPACE_DIR:-/data/workspaces}"

mkdir -p \
  "$HOME" \
  "$HOME/.codex" \
  "$HOME/.config" \
  "$HOME/.t3" \
  "$WORKSPACE_DIR"

# Authenticate Codex from the Railway secret on first startup.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  if ! codex login status >/dev/null 2>&1; then
    printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key
  fi
fi

cd "$WORKSPACE_DIR"

echo "Starting T3 Code"
echo "Workspace: $WORKSPACE_DIR"
echo "Railway port: ${PORT:-8080}"

exec t3 serve \
  --host 0.0.0.0 \
  --port "${PORT:-8080}"