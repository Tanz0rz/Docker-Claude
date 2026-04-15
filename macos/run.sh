#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
VOLUME_NAME="claude-home"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Prefer docker, fall back to podman
if command -v docker &>/dev/null; then
  RUNTIME=docker
elif command -v podman &>/dev/null; then
  RUNTIME=podman
else
  echo "Error: neither docker nor podman found" >&2
  exit 1
fi

echo "Using container runtime: $RUNTIME"

# Check that the daemon is reachable
if [ "$RUNTIME" = "podman" ]; then
  # Podman on macOS uses a VM — try restarting it if unresponsive
  if ! timeout 5 podman info &>/dev/null; then
    echo "Podman VM unresponsive, restarting..."
    podman machine stop 2>/dev/null || true
    podman machine start
    if ! podman info &>/dev/null; then
      echo "Error: podman VM failed to start." >&2
      exit 1
    fi
  fi
else
  if ! $RUNTIME info &>/dev/null; then
    echo "Error: $RUNTIME was found but the daemon is not running." >&2
    echo "Please start Docker Desktop and try again." >&2
    exit 1
  fi
fi

# Build if image doesn't exist
if ! $RUNTIME image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Building image..."
  $RUNTIME build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
fi

# Create persistent volume for claude home if it doesn't exist
if ! $RUNTIME volume inspect "$VOLUME_NAME" &>/dev/null; then
  echo "Creating persistent volume '$VOLUME_NAME'..."
  echo "You will need to run '/login' on first launch to authenticate."
  $RUNTIME volume create "$VOLUME_NAME"
fi

# Runtime-specific flags
RUNTIME_FLAGS=()
if [ "$RUNTIME" = "podman" ]; then
  RUNTIME_FLAGS+=(--userns=keep-id)
else
  RUNTIME_FLAGS+=(--cap-drop=ALL --security-opt=no-new-privileges)
fi

# Derive a unique workspace path from the host directory name
PROJECT_NAME="$(basename "$(pwd)")"
WORKSPACE_PATH="/workspace/$PROJECT_NAME"

# Mount host config to staging paths (entrypoint copies with correct permissions)
HOST_MOUNTS=()
[ -f "$HOME/.gitconfig" ] && HOST_MOUNTS+=(-v "$HOME/.gitconfig:/tmp/.host-gitconfig:ro")
[ -d "$HOME/.ssh" ] && HOST_MOUNTS+=(-v "$HOME/.ssh:/tmp/.host-ssh:ro")
[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/gh" ] && HOST_MOUNTS+=(-v "${XDG_CONFIG_HOME:-$HOME/.config}/gh:/home/claude/.config/gh:ro")

# Ensure host credentials file exists for the shared read-write mount
mkdir -p "$HOME/.claude"
[ ! -f "$HOME/.claude/.credentials.json" ] && echo '{}' > "$HOME/.claude/.credentials.json"
HOST_MOUNTS+=(-v "$HOME/.claude/.credentials.json:/tmp/.host-credentials.json")

# Pass auth environment variables into the container
ENV_FLAGS=()
[ -n "${ANTHROPIC_API_KEY:-}" ] && ENV_FLAGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] && ENV_FLAGS+=(-e "CLAUDE_CODE_USE_BEDROCK=$CLAUDE_CODE_USE_BEDROCK")
[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] && ENV_FLAGS+=(-e "CLAUDE_CODE_USE_VERTEX=$CLAUDE_CODE_USE_VERTEX")
# Forward gh auth token so gh works even when the host stores tokens in a
# system keyring (gnome-keyring, macOS Keychain, etc.) that isn't available
# inside the container.
if [ -z "${GH_TOKEN:-}" ] && command -v gh &>/dev/null && gh auth token &>/dev/null; then
  ENV_FLAGS+=(-e "GH_TOKEN=$(gh auth token)")
elif [ -n "${GH_TOKEN:-}" ]; then
  ENV_FLAGS+=(-e "GH_TOKEN=$GH_TOKEN")
fi

$RUNTIME run --rm -it \
  --network=bridge \
  -w "$WORKSPACE_PATH" \
  "${RUNTIME_FLAGS[@]}" \
  ${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"} \
  ${HOST_MOUNTS[@]+"${HOST_MOUNTS[@]}"} \
  -v "$VOLUME_NAME:/home/claude" \
  -v "$(pwd):$WORKSPACE_PATH" \
  "$IMAGE_NAME" \
  "$@"
