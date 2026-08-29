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
NO_MOUNTS=false
SHOW_HELP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --update)  FORCE_UPDATE=true ;;
    --git)     GIT_FLAG=true ;;
    --no-git)  GIT_FLAG=false ;;
    --no-mounts) NO_MOUNTS=true ;;
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
  --no-mounts  Ignore all container-mounts and container-env files for this launch
  --update     Pull the latest launcher source and agent release, then rebuild
  -h, --help   Show this help
  --           Stop parsing launcher options; pass the rest to $AGENT_LABEL

Anything the launcher doesn't recognize is forwarded to $AGENT_LABEL.
Env equivalents:  GIT_ACCESS=0|1 (git access)   AGENT=claude|codex (which agent)
                  EXTRA_MOUNTS=0|1 (container-mounts / container-env files)
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

# EXTRA_MOUNTS controls whether the container-mounts and container-env files
# are honored (see the mounts block below). Default on; --no-mounts or EXTRA_MOUNTS=0 off.
if [ "$NO_MOUNTS" = true ]; then
  EXTRA_MOUNTS=false
else
  case "${EXTRA_MOUNTS:-1}" in
    0|false|no|off|FALSE|NO|OFF) EXTRA_MOUNTS=false ;;
    *) EXTRA_MOUNTS=true ;;
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

# --update refreshes two things before rebuilding: the launcher's own source
# tree, and the agent release pinned into the image.
#
# The source half is the non-obvious one. The build context is $SCRIPT_DIR — the
# checkout this script lives in, which under the installer is
# ~/.local/share/docker-claude and is *not* whatever clone you may be editing
# elsewhere. Without this step, --update faithfully rebuilds a months-old
# Containerfile with a newer agent pinned into it: the agent moves, every
# toolchain in the image stays frozen, and nothing on screen says why.
#
# It only ever fast-forwards, and only a clean checkout that tracks an upstream:
# this may well be someone's working clone, and an update flag must never discard
# their commits or edits. Every reason for skipping is printed, because "did not
# update" is precisely the state that must not pass silently.
update_source() {
  local upstream before after
  if ! command -v git &>/dev/null; then
    echo "Source: git not found — building $SCRIPT_DIR as it stands."
    return
  fi
  if [ ! -e "$SCRIPT_DIR/.git" ]; then
    echo "Source: $SCRIPT_DIR is not a git checkout — building it as it stands."
    return
  fi
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
    echo "Source: $SCRIPT_DIR has uncommitted changes — building those, not pulling."
    return
  fi
  upstream="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  if [ -z "$upstream" ]; then
    echo "Source: $SCRIPT_DIR tracks no upstream branch — building it as it stands."
    return
  fi
  echo "Updating launcher source in $SCRIPT_DIR ($upstream)..."
  before="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  # GIT_TERMINAL_PROMPT=0 so a repo that has become private (or a token that has
  # expired) fails immediately instead of hanging the launcher on a credential
  # prompt nobody expects from `cclaude --update`.
  if ! GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" pull --ff-only --quiet; then
    echo "Warning: $SCRIPT_DIR could not be fast-forwarded onto $upstream." >&2
    echo "         Building the checkout as it stands — reconcile it with git to pick up newer changes." >&2
    return
  fi
  after="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  if [ "$before" = "$after" ]; then
    echo "Source: already current ($after)."
  else
    echo "Source: updated $before -> $after."
  fi
}

# --update: refresh the source, fetch the latest agent release, then rebuild.
# The changed build-arg busts the agent layer; any source change busts whichever
# layer it belongs to, further up.
if [ "$FORCE_UPDATE" = true ]; then
  update_source
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

# Runtime-specific flags.
#
# Under Docker every capability is dropped and only the five the entrypoint's
# root stage needs are added back: it repairs ownership on the persistent home
# volume (CHOWN, FOWNER, DAC_OVERRIDE) and then execs the agent as the
# unprivileged claude user via gosu (SETUID, SETGID). A bare --cap-drop=ALL
# leaves root unable to do either, and the launch dies at the gosu step. The
# agent itself still ends up unprivileged — see the Security model in the README.
#
# no-new-privileges is orthogonal: it stops execve from ever *granting* privilege
# (setuid bits, file capabilities), which is why it can sit alongside the added
# capabilities. gosu's setuid() uses the capability the process already holds
# rather than gaining one, so the drop still works.
RUNTIME_FLAGS=()
if [ "$RUNTIME" = "podman" ]; then
  RUNTIME_FLAGS+=(--userns=keep-id)
else
  RUNTIME_FLAGS+=(--cap-drop=ALL --cap-add=CHOWN --cap-add=FOWNER --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE --security-opt=no-new-privileges)
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

# Ensure host credentials file exists for the shared read-write mount
mkdir -p "$HOME/.claude"
[ ! -f "$HOME/.claude/.credentials.json" ] && echo '{}' > "$HOME/.claude/.credentials.json"
HOST_MOUNTS+=(-v "$HOME/.claude/.credentials.json:/tmp/.host-credentials.json")

# Share Codex auth the same way. Docker Desktop can't bind-mount a file that
# doesn't exist yet, so seed an empty one. Mounted for both agents so the image
# serves either regardless of which one you launched to log in.
mkdir -p "$HOME/.codex"
[ ! -f "$HOME/.codex/auth.json" ] && echo '{}' > "$HOME/.codex/auth.json"
HOST_MOUNTS+=(-v "$HOME/.codex/auth.json:/tmp/.host-codex-auth.json")

# Extra bind mounts. Large one-off dependencies (a 1 GB engine checkout, a
# dataset, a shared asset tree) don't belong in the image, and re-cloning them
# into every fresh container is exactly the slow, network-bound step this
# exists to skip: keep one copy on the host and bind it in.
#
# Two files are read, in this order, each optional:
#   $CONFIG_DIR/container-mounts     every launch, any project — keeps repos clean
#   ./.container-mounts              this project, inside its repo
# where CONFIG_DIR is ${XDG_CONFIG_HOME:-~/.config}/docker-claude.
#
# One mount per line, whitespace-separated:  host_path [container_path] [ro]
#   ~/src/Kha        /opt/Kha   ro     # tilde, absolute, or project-relative
#   ../shared-assets                   # -> /mnt/shared-assets, read-write
# Relative host paths resolve against the project directory whichever file they
# come from. Blank lines and # comments are ignored. A missing host path is
# skipped with a warning rather than failing the launch, so a committed file
# still works on a machine that lacks one of the paths.
#
# The repo-local file lives inside whatever repo you just cloned, so every
# mount from any source is printed in the banner, targets that would shadow the
# home volume or the workspace are refused, and --no-mounts (or EXTRA_MOUNTS=0)
# skips both files for sessions on untrusted code.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/docker-claude"
EXTRA_MOUNT_LINES=()
EXTRA_MOUNT_SPECS=""
add_mounts_from() {
  local file="$1" line host cont mode _
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    read -r host cont mode _ <<<"$line"
    [ -n "${host:-}" ] || continue
    case "$host" in
      '~')   host="$HOME" ;;
      '~/'*) host="$HOME/${host#\~/}" ;;
      /*)    ;;
      *)     host="$(pwd)/$host" ;;
    esac
    if [ ! -e "$host" ]; then
      echo "Warning: $file: $host does not exist — skipped." >&2
      continue
    fi
    # Normalize to an absolute, symlink-free path: the runtime wants one, and
    # it's what the banner should show.
    if [ -d "$host" ]; then
      host="$(cd "$host" && pwd -P)"
    else
      host="$(cd "$(dirname "$host")" && pwd -P)/$(basename "$host")"
    fi
    # "host ro" — mode given without a container path.
    if [ "${cont:-}" = ro ] || [ "${cont:-}" = rw ]; then mode="$cont"; cont=""; fi
    [ -n "${cont:-}" ] || cont="/mnt/$(basename "$host")"
    case "$cont" in
      /*) ;;
      *)  echo "Warning: $file: container path '$cont' is not absolute — skipped." >&2; continue ;;
    esac
    case "$cont" in
      /|/home/claude|/home/claude/*|/workspace|"$WORKSPACE_PATH"|"$WORKSPACE_PATH"/*)
        echo "Warning: $file: refusing to mount over '$cont' (home volume or workspace) — skipped." >&2; continue ;;
    esac
    case "${mode:-}" in
      ''|rw) mode="" ;;
      ro)    ;;
      *)     echo "Warning: $file: unknown mode '$mode' (expected ro or rw) — skipped." >&2; continue ;;
    esac
    HOST_MOUNTS+=(-v "$host:$cont${mode:+:$mode}")
    EXTRA_MOUNT_LINES+=("$host -> $cont${mode:+ ($mode)}")
    EXTRA_MOUNT_SPECS="${EXTRA_MOUNT_SPECS:+$EXTRA_MOUNT_SPECS;}$cont:${mode:-rw}"
  done < "$file"
}
if [ "$EXTRA_MOUNTS" = true ]; then
  add_mounts_from "$CONFIG_DIR/container-mounts"
  add_mounts_from ".container-mounts"
fi

# Environment for the mounted toolchains. A bind-mounted /opt/go is inert until
# something puts /opt/go/bin on PATH; the same files-and-precedence scheme as
# the mounts covers that:
#   $CONFIG_DIR/container-env        every launch, any project
#   ./.container-env                 this project, inside its repo
#
# One KEY=VALUE per line, container-side values (no host paths, no quoting, no
# expansion, no ';' — what you write is what the container sees). Blank lines and #
# comments are ignored. PATH is special: its value is PREPENDED to the image's
# PATH by the entrypoint, so `PATH=/opt/go/bin:/opt/haxe` adds those in front
# without knowing what the image already has. Names reserved by the launcher
# (HOME, CONTAINER_*, GIT_ACCESS, the agents' own auth variables) are refused.
# The whole set is printed in the banner and disabled by --no-mounts, for the
# same reason the mounts are: the repo-local file arrives with the repo.
EXTRA_ENV_LINES=()
CONTAINER_ENV=""
add_env_from() {
  local file="$1" line key
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    key="${line%%=*}"
    case "$line" in
      *=*) ;;
      *) echo "Warning: $file: '$line' is not KEY=VALUE — skipped." >&2; continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*|[0-9]*|'')
        echo "Warning: $file: '$key' is not a valid variable name — skipped." >&2; continue ;;
      HOME|USER|LOGNAME|SHELL|GIT_ACCESS|CONTAINER_*|ANTHROPIC_API_KEY|OPENAI_API_KEY|GH_TOKEN|CLAUDE_CODE_USE_*)
        echo "Warning: $file: refusing to set '$key' (reserved by the launcher) — skipped." >&2; continue ;;
    esac
    case "$line" in *';'*)
      echo "Warning: $file: '$key' contains ';' (the separator) — skipped." >&2; continue ;;
    esac
    EXTRA_ENV_LINES+=("$line")
    CONTAINER_ENV="${CONTAINER_ENV:+$CONTAINER_ENV;}$line"
  done < "$file"
}
if [ "$EXTRA_MOUNTS" = true ]; then
  add_env_from "$CONFIG_DIR/container-env"
  add_env_from ".container-env"
fi

# Pass auth environment variables into the container
ENV_FLAGS=(-e "CONTAINER_AGENT=$AGENT" -e "GIT_ACCESS=$GIT_ACCESS")
# Tell the agent what was mounted: the entrypoint turns this into a
# /workspace/CLAUDE.md (and AGENTS.md) so it checks these paths before
# downloading a dependency the host already has. Container path only — the
# host side is irrelevant inside. Format: /path:ro;/other:rw
ENV_FLAGS+=(-e "CONTAINER_MOUNTS=$EXTRA_MOUNT_SPECS")
# ...and the container-env lines as KEY=V;KEY2=V, applied by the entrypoint
# (PATH prepended).
ENV_FLAGS+=(-e "CONTAINER_ENV=$CONTAINER_ENV")
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
echo "               (toggle with --git/--no-git)"
echo "──────────────────────────────────────────────────────────────"
echo "  Agent:       $AGENT_LABEL   (switch with AGENT=claude|codex)"
echo "  Auth:        $AUTH_STATUS"
echo "  Workspace:   $(pwd) -> $WORKSPACE_PATH"
echo "  Home volume: $VOLUME_NAME (persistent)"
if [ "$EXTRA_MOUNTS" != true ]; then
  echo "  Mounts:      off (container-mounts files ignored)"
  echo "  Env:         off (container-env files ignored)"
elif [ ${#EXTRA_MOUNT_LINES[@]} -eq 0 ]; then
  echo "  Mounts:      none (.container-mounts or $CONFIG_DIR/container-mounts)"
else
  echo "  Mounts:      ${EXTRA_MOUNT_LINES[0]}"
  for m in "${EXTRA_MOUNT_LINES[@]:1}"; do echo "               $m"; done
fi
if [ "$EXTRA_MOUNTS" = true ]; then
  if [ ${#EXTRA_ENV_LINES[@]} -eq 0 ]; then
    echo "  Env:         none (.container-env or $CONFIG_DIR/container-env)"
  else
    echo "  Env:         ${EXTRA_ENV_LINES[0]}"
    for e in "${EXTRA_ENV_LINES[@]:1}"; do echo "               $e"; done
  fi
fi
echo "  Update:      $LAUNCHER --update   pulls the latest source + release, rebuilds"
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
