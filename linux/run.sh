#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-code"
VOLUME_NAME="claude-home"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Which agent to launch: "claude" (default) or "codex". Set by the ccodex alias
# (AGENT=codex). The image bundles both CLIs; AGENT only picks which one runs.
AGENT="${AGENT:-claude}"
case "$AGENT" in
  claude) AGENT_LABEL="Claude Code"; LAUNCHER="cclaude" ;;
  codex)  AGENT_LABEL="Codex CLI";   LAUNCHER="ccodex"  ;;
  *) echo "Error: unknown AGENT '$AGENT' (expected 'claude' or 'codex')" >&2; exit 1 ;;
esac

# Launcher options are parsed front-anchored: only leading --update/--git/
# --no-git/--help flags are consumed. The first token we don't recognize (or a
# literal --) ends parsing, and everything after is forwarded to the agent
# untouched — so the agent's own flags never clash with the launcher's.
FORCE_UPDATE=false
GIT_FLAG=""
SHOW_HELP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --update)  FORCE_UPDATE=true ;;
    --git)     GIT_FLAG=true ;;
    --no-git)  GIT_FLAG=false ;;
    -h|--help) SHOW_HELP=true ;;
    --)        shift; break ;;
    *)         break ;;
  esac
  shift
done

# Wrapper help. First line is the passthrough to the agent's own help, so you
# can always reach it; the rest documents the launcher's own options.
if [ "$SHOW_HELP" = true ]; then
  cat <<EOF
For $AGENT_LABEL's own help, run:  $LAUNCHER -- --help

$LAUNCHER runs $AGENT_LABEL in an isolated container (see README for details).
Launcher options — must come before the agent's arguments:
  --no-git     Don't share git identity/credentials for this launch
  --git        Force git access on (overrides the GIT_ACCESS env var)
  --update     Rebuild the image with the agent's latest release, then launch
  -h, --help   Show this help
  --           Stop parsing launcher options; pass the rest to $AGENT_LABEL

Anything the launcher doesn't recognize is forwarded to $AGENT_LABEL.
Env equivalents:  GIT_ACCESS=0|1 (git access)   AGENT=claude|codex (which agent)
EOF
  exit 0
fi

# GIT_ACCESS controls whether the host's git identity and credentials (gitconfig,
# SSH keys, gh token/config) are shared with the container. Default on; use
# --no-git (or GIT_ACCESS=0/false/no/off) for review-only sessions on untrusted
# code. A --git/--no-git flag takes precedence over the GIT_ACCESS env var.
if [ -n "$GIT_FLAG" ]; then
  GIT_ACCESS="$GIT_FLAG"
else
  case "${GIT_ACCESS:-1}" in
    0|false|no|off|FALSE|NO|OFF) GIT_ACCESS=false ;;
    *) GIT_ACCESS=true ;;
  esac
fi

# Colorize the banner when stdout is a terminal (plain text when piped/redirected).
if [ -t 1 ]; then
  _B=$'\033[1m'; _R=$'\033[0m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'
else
  _B=; _R=; _GRN=; _YEL=
fi
# Git access is the security-critical toggle, so render it boldest: a colored
# ON/OFF badge. ON (credentials live in the container) draws the eye in yellow;
# OFF (isolated) reads green.
if [ "$GIT_ACCESS" = true ]; then
  GIT_STATUS="${_B}${_YEL}ON${_R}  — gitconfig, SSH keys, gh token shared"
else
  GIT_STATUS="${_B}${_GRN}OFF${_R} — no git identity or credentials"
fi

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
  if [ "$AGENT" = "codex" ]; then
    echo "Fetching latest Codex CLI version..."
    LATEST_VERSION="$(curl -fsSL https://registry.npmjs.org/@openai/codex/latest \
      | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)" \
      || { echo "Error: could not fetch the latest Codex CLI version." >&2; exit 1; }
    [ -n "$LATEST_VERSION" ] || { echo "Error: could not parse the latest Codex CLI version." >&2; exit 1; }
    echo "Rebuilding image with Codex CLI $LATEST_VERSION..."
    $RUNTIME build --pull --build-arg "CODEX_VERSION=$LATEST_VERSION" \
      -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
  else
    echo "Fetching latest Claude Code version..."
    LATEST_VERSION="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)" \
      || { echo "Error: could not fetch the latest Claude Code version." >&2; exit 1; }
    echo "Rebuilding image with Claude Code $LATEST_VERSION..."
    $RUNTIME build --pull --build-arg "CLAUDE_CODE_VERSION=$LATEST_VERSION" \
      -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
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
  RUNTIME_FLAGS+=(--cap-drop=ALL --cap-add=CHOWN --cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE)
fi

# Derive a unique workspace path from the host directory name
PROJECT_NAME="$(basename "$(pwd)")"
WORKSPACE_PATH="/workspace/$PROJECT_NAME"

# Mount host config to staging paths (entrypoint copies with correct permissions)
HOST_MOUNTS=()
# Git identity and credentials — only when GIT_ACCESS is on.
if [ "$GIT_ACCESS" = true ]; then
  [ -f "$HOME/.gitconfig" ] && HOST_MOUNTS+=(-v "$HOME/.gitconfig:/tmp/.host-gitconfig:ro")
  [ -d "$HOME/.ssh" ] && HOST_MOUNTS+=(-v "$HOME/.ssh:/tmp/.host-ssh:ro")
  [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/gh" ] && HOST_MOUNTS+=(-v "${XDG_CONFIG_HOME:-$HOME/.config}/gh:/home/claude/.config/gh:ro")
fi
# Share the host's .claude directory so OAuth token refreshes (which use atomic
# writes) persist correctly in both directions.  A directory-level bind mount
# handles rename() atomicity — file-level mounts and symlinks do not. Agent auth
# is not gated by GIT_ACCESS.
mkdir -p "$HOME/.claude"
HOST_MOUNTS+=(-v "$HOME/.claude:/home/claude/.claude")
# Share the host's .codex directory the same way, so Codex logins and token
# refreshes persist in both directions. Mounted for both agents so the image
# serves either regardless of which one you launched to log in.
mkdir -p "$HOME/.codex"
HOST_MOUNTS+=(-v "$HOME/.codex:/home/claude/.codex")

# Pass auth environment variables into the container
ENV_FLAGS=(-e "CONTAINER_AGENT=$AGENT" -e "GIT_ACCESS=$GIT_ACCESS")
[ -n "${ANTHROPIC_API_KEY:-}" ] && ENV_FLAGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[ -n "${OPENAI_API_KEY:-}" ] && ENV_FLAGS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] && ENV_FLAGS+=(-e "CLAUDE_CODE_USE_BEDROCK=$CLAUDE_CODE_USE_BEDROCK")
[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] && ENV_FLAGS+=(-e "CLAUDE_CODE_USE_VERTEX=$CLAUDE_CODE_USE_VERTEX")
# Forward gh auth token so gh works even when the host stores tokens in a
# system keyring (gnome-keyring, macOS Keychain, etc.) that isn't available
# inside the container. Withheld when GIT_ACCESS is off.
if [ "$GIT_ACCESS" = true ]; then
  if [ -z "${GH_TOKEN:-}" ] && command -v gh &>/dev/null && gh auth token &>/dev/null; then
    ENV_FLAGS+=(-e "GH_TOKEN=$(gh auth token)")
  elif [ -n "${GH_TOKEN:-}" ]; then
    ENV_FLAGS+=(-e "GH_TOKEN=$GH_TOKEN")
  fi
fi

# Share the host's Wayland socket so clipboard image paste (ctrl+v) works.
# Claude Code reads clipboard images via wl-paste, which needs the compositor
# socket. X11 hosts are intentionally not wired up: sharing the X11 socket
# would let the container snoop keystrokes and windows, unlike Wayland where
# clients are isolated from each other.
# Skipped entirely on X11-only or headless hosts: the socket must exist or
# nothing is mounted and no env vars are set.
CLIPBOARD_STATUS="off (no Wayland socket shared)"
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
    CLIPBOARD_STATUS="on (Wayland image paste)"
  fi
fi

# Summarize the active auth source for the banner. Env-var credentials take
# precedence over the persisted subscription/OAuth login in the mounted home.
if [ "$AGENT" = codex ]; then
  [ -n "${OPENAI_API_KEY:-}" ] && AUTH_STATUS="OPENAI_API_KEY" || AUTH_STATUS="ChatGPT login (~/.codex)"
elif [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]; then
  AUTH_STATUS="AWS Bedrock"
elif [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; then
  AUTH_STATUS="Google Vertex"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  AUTH_STATUS="ANTHROPIC_API_KEY"
else
  AUTH_STATUS="subscription login (~/.claude)"
fi

echo "──────────────────────────────────────────────────────────────"
echo "  ${_B}Git access:  $GIT_STATUS${_R}"
echo "               (toggle with GIT_ACCESS=1|0)"
echo "──────────────────────────────────────────────────────────────"
echo "  Agent:       $AGENT_LABEL   (switch with AGENT=claude|codex)"
echo "  Auth:        $AUTH_STATUS"
echo "  Clipboard:   $CLIPBOARD_STATUS"
echo "  Workspace:   $(pwd) -> $WORKSPACE_PATH"
echo "  Home volume: $VOLUME_NAME (persistent)"
echo "  Update:      $LAUNCHER --update   rebuilds with the latest release"
echo "──────────────────────────────────────────────────────────────"

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
