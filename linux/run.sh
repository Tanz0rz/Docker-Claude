#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
VOLUME_NAME="claude-home"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --update rebuilds the image with the latest Claude Code release before launching
FORCE_UPDATE=false
FILTERED_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--update" ]; then
    FORCE_UPDATE=true
  else
    FILTERED_ARGS+=("$arg")
  fi
done
set -- ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}

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
if ! $RUNTIME info &>/dev/null; then
  echo "Error: $RUNTIME was found but the daemon is not running." >&2
  echo "Please start the $RUNTIME service and try again." >&2
  exit 1
fi

# --update: fetch the latest release and rebuild (the changed build-arg busts the layer cache)
if [ "$FORCE_UPDATE" = true ]; then
  echo "Fetching latest Claude Code version..."
  LATEST_VERSION="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)" \
    || { echo "Error: could not fetch the latest Claude Code version." >&2; exit 1; }
  echo "Rebuilding image with Claude Code $LATEST_VERSION..."
  $RUNTIME build --pull --build-arg "CLAUDE_CODE_VERSION=$LATEST_VERSION" \
    -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
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
  RUNTIME_FLAGS+=(--cap-drop=ALL --cap-add=CHOWN --cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE)
fi

# Derive a unique workspace path from the host directory name
PROJECT_NAME="$(basename "$(pwd)")"
WORKSPACE_PATH="/workspace/$PROJECT_NAME"

# Mount host config to staging paths (entrypoint copies with correct permissions)
HOST_MOUNTS=()
[ -f "$HOME/.gitconfig" ] && HOST_MOUNTS+=(-v "$HOME/.gitconfig:/tmp/.host-gitconfig:ro")
[ -d "$HOME/.ssh" ] && HOST_MOUNTS+=(-v "$HOME/.ssh:/tmp/.host-ssh:ro")
# Share the host's .claude directory so OAuth token refreshes (which use atomic
# writes) persist correctly in both directions.  A directory-level bind mount
# handles rename() atomicity — file-level mounts and symlinks do not.
mkdir -p "$HOME/.claude"
HOST_MOUNTS+=(-v "$HOME/.claude:/home/claude/.claude")
[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/gh" ] && HOST_MOUNTS+=(-v "${XDG_CONFIG_HOME:-$HOME/.config}/gh:/home/claude/.config/gh:ro")

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

# Share the host's Wayland socket so clipboard image paste (ctrl+v) works.
# Claude Code reads clipboard images via wl-paste, which needs the compositor
# socket. X11 hosts are intentionally not wired up: sharing the X11 socket
# would let the container snoop keystrokes and windows, unlike Wayland where
# clients are isolated from each other.
# Skipped entirely on X11-only or headless hosts: the socket must exist or
# nothing is mounted and no env vars are set.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  case "$WAYLAND_DISPLAY" in
    # WAYLAND_DISPLAY may be an absolute path per the Wayland spec
    /*) WAYLAND_SOCKET="$WAYLAND_DISPLAY" ;;
    *)  WAYLAND_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ;;
  esac
  WAYLAND_NAME="$(basename "$WAYLAND_SOCKET")"
  if [ -S "$WAYLAND_SOCKET" ]; then
    HOST_MOUNTS+=(-v "$WAYLAND_SOCKET:/run/user/1000/$WAYLAND_NAME")
    ENV_FLAGS+=(-e "WAYLAND_DISPLAY=$WAYLAND_NAME" -e "XDG_RUNTIME_DIR=/run/user/1000")
  fi
fi

echo "Tip: run 'cclaude --update' to rebuild this image with the latest Claude Code."

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
