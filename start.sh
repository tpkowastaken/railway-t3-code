#!/usr/bin/env bash
set -euo pipefail

# Runs as root just long enough to fix the volume and start nginx, then T3 and
# the pairing page run as the t3 user.
export HOME="${HOME:-/data/home}"
export WORKSPACE_DIR="${WORKSPACE_DIR:-/data/workspaces}"
PORT="${PORT:-8080}"

mkdir -p "$HOME" "$WORKSPACE_DIR"
[ -f "$HOME/.bashrc" ] || cp -an /etc/skel/. "$HOME/"
mkdir -p "$HOME/.config" "$HOME/.local/bin" "$HOME/.t3"
# The volume is root-owned on first boot (and on deploys from before the t3 user).
for d in "$HOME" "$WORKSPACE_DIR"; do
  [ "$(stat -c %u "$d")" = 1000 ] || chown -R t3:t3 "$d"
done

as_t3() {
  setpriv --reuid=1000 --regid=1000 --init-groups \
    env HOME="$HOME" USER=t3 LOGNAME=t3 SHELL=/bin/bash "$@"
}

# Tell every agent how this container persists things ("default global agent.md").
as_t3 install-agent-instructions /opt/default-global-agent.md || echo "agent instructions: install failed"

# Everything outside /data is rebuilt from the image, so system changes agents
# want to keep are replayed from the volume: root's boot.sh, then the packages
# `apt-persist` recorded (from apt's lists and .debs, also kept on the volume).
SYSTEM_DIR=/data/system
mkdir -p "$SYSTEM_DIR/apt/archives/partial" "$SYSTEM_DIR/apt/lists/partial"
chown _apt:root "$SYSTEM_DIR/apt/archives/partial" "$SYSTEM_DIR/apt/lists/partial"
[ -e "$SYSTEM_DIR/apt-packages" ] || install -o t3 -g t3 -m 644 /dev/null "$SYSTEM_DIR/apt-packages"
[ -e "$SYSTEM_DIR/boot.sh" ] || install -o t3 -g t3 -m 644 /dev/stdin "$SYSTEM_DIR/boot.sh" <<'BOOT'
# Runs as root on every boot, before the apt-persist packages are reinstalled.
# Put system changes here that must survive restarts, e.g. an apt repository:
#   curl -fsSL https://example.com/key.gpg | gpg --dearmor -o /usr/share/keyrings/example.gpg
#   echo "deb [signed-by=/usr/share/keyrings/example.gpg] https://example.com/apt stable main" > /etc/apt/sources.list.d/example.list
BOOT

restore_system() {
  set +e
  echo "restore started $(date -Is)"
  bash "$SYSTEM_DIR/boot.sh" || echo "boot.sh failed"
  local pkgs
  mapfile -t pkgs < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$SYSTEM_DIR/apt-packages")
  if [ ${#pkgs[@]} -gt 0 ]; then
    # Stale lists or one bad name shouldn't cost the rest: refresh, then go one by one.
    apt-get install -y "${pkgs[@]}" || {
      apt-get update
      apt-get install -y "${pkgs[@]}" || for p in "${pkgs[@]}"; do apt-get install -y "$p" || echo "FAILED: $p"; done
    }
    apt-get autoclean
  fi
  echo "restore finished $(date -Is)"
}
# In the background so T3 is up within the healthcheck; apt's lock timeout
# makes an agent's apt-get wait for it.
restore_system > "$SYSTEM_DIR/restore.log" 2>&1 &

# Password for /railway-pair. Set T3_SETUP_PASSWORD in Railway's Variables tab;
# deploys without it get one generated once and printed below, and the page
# asks the user to set the variable.
T3_SETUP_PASSWORD_GENERATED=0
if [ -z "${T3_SETUP_PASSWORD:-}" ]; then
  T3_SETUP_PASSWORD_GENERATED=1
  pw_file="$HOME/.config/railway-pair-password"
  [ -s "$pw_file" ] || { head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$pw_file"; chown t3:t3 "$pw_file"; chmod 600 "$pw_file"; }
  T3_SETUP_PASSWORD="$(cat "$pw_file")"
  echo "T3_SETUP_PASSWORD is not set; using generated password: $T3_SETUP_PASSWORD"
  echo "Set T3_SETUP_PASSWORD in the service's Variables to choose your own."
fi

# Optional keys, applied once so a login done in the app is never overwritten.
if [ -n "${OPENAI_API_KEY:-}" ] && ! as_t3 codex login status >/dev/null 2>&1; then
  printenv OPENAI_API_KEY | as_t3 codex login --with-api-key >/dev/null 2>&1 || echo "codex: API-key login failed"
fi
if [ -n "${GH_TOKEN:-}" ]; then
  as_t3 gh auth setup-git >/dev/null 2>&1 || true
fi

# Remote Docker: Railway can't run a Docker daemon, so the docker CLI talks to
# one on another machine over SSH. Variables (Railway's Variables tab):
#   DOCKER_HOST             ssh://user@host[:port]
#   DOCKER_SSH_KEY          private key for that user (multi-line, or base64)
#   DOCKER_SSH_KNOWN_HOSTS  optional: `ssh-keyscan host` output; without it the
#                           first key seen is trusted and remembered
if [[ "${DOCKER_HOST:-}" == ssh://* ]]; then
  dest="${DOCKER_HOST#ssh://}"; dest="${dest%%/*}"
  hostport="${dest#*@}"; docker_host="${hostport%%:*}"
  docker_user=""; [[ "$dest" == *@* ]] && docker_user="${dest%@*}"
  docker_port=""; [[ "$hostport" == *:* ]] && docker_port="${hostport##*:}"

  # The key stays off the volume: it's rewritten from the variable every boot.
  run_dir=/run/docker-host
  install -d -o t3 -g t3 -m 700 "$run_dir" "$HOME/.ssh"
  if [ -n "${DOCKER_SSH_KEY:-}" ]; then
    key="$DOCKER_SSH_KEY"
    [[ "$key" == *$'\n'* ]] || key="${key//\\n/$'\n'}"
    [[ "$key" == *"PRIVATE KEY"* ]] || key="$(printf '%s' "$key" | base64 -d 2>/dev/null)"
    [[ "$key" == *"PRIVATE KEY"* ]] || echo "DOCKER_SSH_KEY: not a private key (paste the whole file, or base64 of it)"
    install -o t3 -g t3 -m 600 /dev/null "$run_dir/id"
    printf '%s\n' "$key" > "$run_dir/id"
  fi
  if [ -n "${DOCKER_SSH_KNOWN_HOSTS:-}" ]; then
    printf '%s\n' "$DOCKER_SSH_KNOWN_HOSTS" > "$run_dir/known_hosts"
    known_hosts="$run_dir/known_hosts" strict=yes
  else
    known_hosts="$HOME/.ssh/known_hosts_docker" strict=accept-new
  fi

  # The connection is shared (ControlMaster): docker opens one per command.
  {
    echo "Host $docker_host"
    [ -n "$docker_user" ] && echo "  User $docker_user"
    [ -n "$docker_port" ] && echo "  Port $docker_port"
    [ -s "$run_dir/id" ] && printf '  IdentityFile %s\n  IdentitiesOnly yes\n' "$run_dir/id"
    echo "  UserKnownHostsFile $known_hosts"
    echo "  StrictHostKeyChecking $strict"
    echo "  ServerAliveInterval 30"
    echo "  ControlMaster auto"
    echo "  ControlPath $run_dir/cm-%C"
    echo "  ControlPersist 10m"
  } > /etc/ssh/ssh_config.d/docker-host.conf

  # Ports containers publish on the Docker host show up at 127.0.0.1 here.
  ( as_t3 docker-forward supervise 2>&1 | sed -u 's/^/docker-forward: /' ) &
  # Testcontainers connects to the Docker host's address; here that's the forward.
  export TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1
  echo "Docker: using $DOCKER_HOST"
fi
unset DOCKER_SSH_KEY DOCKER_SSH_KNOWN_HOSTS

# nginx on $PORT: /railway-pair is the password-gated pairing page, everything
# else is T3, which authenticates every API call, WebSocket and terminal itself.
# A browser without T3's session cookie (t3_session_<hash>, or the legacy
# t3_session) opening / is sent to the pairing page instead of T3's sign-in.
cat > /etc/nginx/conf.d/t3.conf <<CFG
map \$http_cookie \$t3_has_session {
  default 0;
  "~(^|;)\\s*t3_session(_[0-9a-f]+)?=" 1;
}
server {
  listen ${PORT} default_server;
  listen [::]:${PORT} default_server;
  client_max_body_size 200m;
  # Relative Location headers: nginx would otherwise add its internal :${PORT}.
  absolute_redirect off;
  location = /healthcheck { proxy_pass http://127.0.0.1:3773/.well-known/t3/environment; }
  location ~ ^/railway-pair(/password\.jpg)?\$ {
    proxy_pass http://127.0.0.1:3774;
    proxy_set_header Host \$http_host;
  }
  location = / {
    if (\$t3_has_session = 0) { return 302 /railway-pair; }
    proxy_pass http://127.0.0.1:3773;
    proxy_set_header Host \$http_host;
  }
  location / {
    proxy_pass http://127.0.0.1:3773;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
    proxy_set_header Host \$http_host;
    proxy_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
  }
}
CFG
nginx

T3_SETUP_PASSWORD="$T3_SETUP_PASSWORD" T3_SETUP_PASSWORD_GENERATED="$T3_SETUP_PASSWORD_GENERATED" \
  as_t3 node /opt/railway-pair.mjs &
unset T3_SETUP_PASSWORD

# Railway counts the kernel's cache of files this container touched as its
# memory and never frees it without pressure (one npm install = hundreds of MB).
# /opt and /usr too: the agent binaries in /opt/npm stay cached after a session ends.
( while sleep 900; do nice -n 19 drop-file-cache /data /tmp /opt /usr || true; done ) &

cd "$WORKSPACE_DIR"

echo "Starting T3 Code $(t3 --version 2>/dev/null)"
echo "Workspace: $WORKSPACE_DIR"
echo "Pair a device at https://<your-domain>/railway-pair"

# `t3 serve` prints a one-time admin token + QR at boot. Pairing goes through
# /railway-pair instead, so keep the token out of the deploy logs.
setpriv --reuid=1000 --regid=1000 --init-groups \
  env HOME="$HOME" USER=t3 LOGNAME=t3 SHELL=/bin/bash \
  t3 serve --host 0.0.0.0 --port 3773 "$WORKSPACE_DIR" \
  > >(sed -u -e '/^Token: /d' -e 's/token=[^ "&]*/token=<redacted>/g' -e '/^[ █▀▄]*$/d') 2>&1 &
t3_pid=$!

# Railway stops a replaced deployment with SIGTERM (tini forwards it here). T3
# shuts down gracefully but exits non-zero, which Railway reports as a crash, so
# pass the signal on, let T3 finish, and report a requested stop as clean.
stopping=0
trap 'stopping=1; kill -TERM "$t3_pid" 2>/dev/null || true' TERM INT
status=0
wait "$t3_pid" || status=$?
# A trapped signal interrupts `wait`; wait again for T3 to actually exit.
while kill -0 "$t3_pid" 2>/dev/null; do wait "$t3_pid" || status=$?; done
if [ "$stopping" = 1 ]; then
  echo "T3 Code stopped (exit status $status after SIGTERM)"
  exit 0
fi
exit "$status"
