#!/usr/bin/env bash
# Moves everything the Dockerfile pins to its latest stable release, in place.
set -euo pipefail

dockerfile="${1:-Dockerfile}"

set_arg() { NAME="$1" VALUE="$2" perl -pi -e 's/^ARG \Q$ENV{NAME}\E=.*/ARG $ENV{NAME}=$ENV{VALUE}/' "$dockerfile"; }
npm_latest() { npm view "$1" version; }

# T3 Code: release version + checksum of the Linux archive.
tag=$(gh release view -R pingdotgg/t3code --json tagName --jq .tagName)
t3_version=${tag#v}
t3_sha=$(gh release download "$tag" -R pingdotgg/t3code -p SHA256SUMS -O - \
  | awk -v f="t3-$t3_version-linux-x64.tar.gz" '$2 == f { print $1 }')
[ -n "$t3_sha" ] || { echo "no checksum for t3 $t3_version" >&2; exit 1; }
set_arg T3_VERSION "$t3_version"
set_arg T3_SHA256 "$t3_sha"

set_arg CLAUDE_CODE_VERSION "$(npm_latest @anthropic-ai/claude-code)"
set_arg CODEX_VERSION "$(npm_latest @openai/codex)"
set_arg OPENCODE_VERSION "$(npm_latest @opencode/cli)"

# Base image digest. A new one invalidates every layer, so it also refreshes the
# unpinned apt packages, gh, the Docker CLI and uv.
repo=library/node
image_tag=24-bookworm
token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | jq -r .token)
digest=$(curl -fsSI \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://registry-1.docker.io/v2/$repo/manifests/$image_tag" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
[[ "$digest" == sha256:* ]] || { echo "no digest for node:$image_tag" >&2; exit 1; }
DIGEST="$digest" IMAGE="node:$image_tag" \
  perl -pi -e 's/^FROM \Q$ENV{IMAGE}\E(@\S+)?$/FROM $ENV{IMAGE}\@$ENV{DIGEST}/' "$dockerfile"
