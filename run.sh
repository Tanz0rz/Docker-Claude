#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
VOLUME_NAME="claude-home"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Health check: restart podman machine if socket is unresponsive
if [ "$RUNTIME" = "podman" ]; then
  if ! timeout 5 podman info &>/dev/null; then
    echo "Podman VM unresponsive, restarting..."
    podman machine stop 2>/dev/null || true
    podman machine start
  fi
fi

# Build if image doesn't exist
if ! $RUNTIME image exists "$IMAGE_NAME" 2>/dev/null; then
  echo "Building image..."
  $RUNTIME build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
fi

# Create persistent volume for claude home if it doesn't exist
if ! $RUNTIME volume exists "$VOLUME_NAME" 2>/dev/null; then
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

# Mount host config (read-only)
HOST_MOUNTS=()
[ -f "$HOME/.gitconfig" ] && HOST_MOUNTS+=(-v "$HOME/.gitconfig:/home/claude/.gitconfig:ro")
[ -d "$HOME/.ssh" ] && HOST_MOUNTS+=(-v "$HOME/.ssh:/home/claude/.ssh:ro")

$RUNTIME run --rm -it \
  --network=bridge \
  "${RUNTIME_FLAGS[@]}" \
  ${HOST_MOUNTS[@]+"${HOST_MOUNTS[@]}"} \
  -v "$VOLUME_NAME:/home/claude" \
  -v "$(pwd):/workspace" \
  "$IMAGE_NAME" \
  "$@"
