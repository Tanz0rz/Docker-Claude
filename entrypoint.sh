#!/bin/bash
# Entrypoint runs as root to fix volume permissions, then drops to claude
# using gosu (which execs directly, unlike su, so no root process remains).

CLAUDE_HOME=/home/claude
CLAUDE_USER=claude
CLAUDE_UID=1000
CLAUDE_GID=1000

# Fix ownership of the home directory in case the volume has root-owned files
# from a previous run.
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME"

# ...and of everything inside it. The persistent volume outlives any single
# image, so it accumulates files owned by whoever wrote them: root (from the
# runtime creating mount points) or a stranger UID (from an image whose user was
# not 1000). Every such directory is unwritable for the claude user, and the
# failures land far from the cause — a compiler dying with
# "mkdir /home/claude/.cache/...: permission denied", npm refusing to touch
# ~/.npm — so repair the whole tree on every start rather than one directory at
# a time.
#
# The host bind mounts are pruned: .claude and .codex belong to the host user
# and are handled individually below, .config/gh is mounted read-only, and
# recursing into any of them would be slow and would rewrite host-side
# ownership. -exec chown -h keeps symlinks from being followed out of the home
# directory.
find "$CLAUDE_HOME" -mindepth 1 \
  \( -path "$CLAUDE_HOME/.claude" -o -path "$CLAUDE_HOME/.codex" \
     -o -path "$CLAUDE_HOME/.config/gh" \) -prune -o \
  \( ! -user "$CLAUDE_UID" -o ! -group "$CLAUDE_GID" \) \
  -exec chown -h "$CLAUDE_UID:$CLAUDE_GID" {} + 2>/dev/null || true

# Git identity and credentials. GIT_ACCESS (set by the run script) gates whether
# the host's SSH keys and gitconfig reach the container. When it's off we also
# purge any copies a previous run left in the persistent home volume, so
# "no git access" really means none — not just "nothing new mounted this time".
GIT_ACCESS="${GIT_ACCESS:-true}"
if [ "$GIT_ACCESS" = true ]; then
  # Copy host SSH keys with correct ownership and permissions
  if [ -d /tmp/.host-ssh ] && ls /tmp/.host-ssh/* &>/dev/null; then
    rm -rf "$CLAUDE_HOME/.ssh"
    mkdir -p "$CLAUDE_HOME/.ssh"
    cp -r /tmp/.host-ssh/* "$CLAUDE_HOME/.ssh/" 2>/dev/null || true
    # Remove socket files (e.g. agent sockets) that don't belong in the copy
    find "$CLAUDE_HOME/.ssh" -type s -delete 2>/dev/null || true
    chmod 700 "$CLAUDE_HOME/.ssh"
    chmod 600 "$CLAUDE_HOME/.ssh"/* 2>/dev/null || true
    chmod 644 "$CLAUDE_HOME/.ssh"/*.pub 2>/dev/null || true
    chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh"
  fi

  # Copy host gitconfig
  if [ -f /tmp/.host-gitconfig ]; then
    rm -f "$CLAUDE_HOME/.gitconfig"
    cp /tmp/.host-gitconfig "$CLAUDE_HOME/.gitconfig"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.gitconfig"
  fi
else
  # Git access withheld: scrub any git identity/credentials cached in the volume.
  rm -rf "$CLAUDE_HOME/.ssh" "$CLAUDE_HOME/.gitconfig" "$CLAUDE_HOME/.config/gh"
fi

# Share OAuth credentials with the host so logins and token refreshes
# persist across all sessions (host and container).
mkdir -p "$CLAUDE_HOME/.claude"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.claude"
if [ -f /tmp/.host-credentials.json ]; then
  # Legacy per-file mount (macOS/Windows): symlink to the bind-mounted file.
  chown "$CLAUDE_UID:$CLAUDE_GID" /tmp/.host-credentials.json 2>/dev/null || true
  ln -sf /tmp/.host-credentials.json "$CLAUDE_HOME/.claude/.credentials.json"
elif [ -f "$CLAUDE_HOME/.claude/.credentials.json" ]; then
  # Directory-level mount (Linux): the host's ~/.claude is mounted directly,
  # so just fix ownership.
  chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.claude/.credentials.json" 2>/dev/null || true
fi

# Share Codex credentials with the host the same way as Claude's, so ChatGPT
# logins and token refreshes persist across all sessions (host and container).
mkdir -p "$CLAUDE_HOME/.codex"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.codex"
if [ -f /tmp/.host-codex-auth.json ]; then
  # Legacy per-file mount (macOS/Windows): symlink to the bind-mounted file.
  chown "$CLAUDE_UID:$CLAUDE_GID" /tmp/.host-codex-auth.json 2>/dev/null || true
  ln -sf /tmp/.host-codex-auth.json "$CLAUDE_HOME/.codex/auth.json"
elif [ -f "$CLAUDE_HOME/.codex/auth.json" ]; then
  # Directory-level mount (Linux): the host's ~/.codex is mounted directly,
  # so just fix ownership.
  chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.codex/auth.json" 2>/dev/null || true
fi

# Ensure GitHub host key is trusted for SSH operations (only when git access is on)
if [ "$GIT_ACCESS" = true ]; then
  gosu "$CLAUDE_USER" ssh-keyscan github.com >> "$CLAUDE_HOME/.ssh/known_hosts" 2>/dev/null || true
  chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# Apply the user's container-env files. The run scripts pass their contents in
# CONTAINER_ENV as KEY=VALUE;KEY2=VALUE2 (so a value cannot contain ';'), already
# filtered to plain identifiers.
# PATH is the one variable treated specially: its value is PREPENDED to the
# image's PATH rather than replacing it, so a mounted toolchain wins over
# anything the volume holds while the agents and base tools stay reachable. The
# variables are exported here, in the root shell, and inherited by the gosu exec
# at the bottom — no login shell is involved, so ~/.profile would not do.
_env_lines=""
if [ -n "${CONTAINER_ENV:-}" ]; then
  IFS=';' read -ra _entries <<<"$CONTAINER_ENV"
  for _line in "${_entries[@]}"; do
    [ -n "$_line" ] || continue
    _key="${_line%%=*}"
    _val="${_line#*=}"
    case "$_key" in
      PATH) export PATH="$_val:$PATH" ;;
      *)    export "$_key=$_val" ;;
    esac
    _env_lines="${_env_lines}- \`${_line}\`"$'\n'
  done
fi
unset CONTAINER_ENV

# Tell the agent which extra host directories the launcher bind-mounted, so it
# looks there before downloading a dependency the host already has. Claude Code
# reads CLAUDE.md from every ancestor of its cwd, and /workspace is the parent
# of every project mount, so a file there reaches any project without touching
# the project itself. AGENTS.md is the same text for Codex. CONTAINER_MOUNTS is
# set by the run scripts as /path:ro;/other:rw (empty when nothing was mounted).
{
  echo "# Container mounts"
  echo
  if [ -n "${CONTAINER_MOUNTS:-}" ]; then
    echo "The launcher bind-mounted these host directories into this container (from the"
    echo "user's container-mounts files). Check them before cloning or downloading a"
    echo "dependency — the host copy is meant to be used from here:"
    echo
    IFS=';' read -ra _mounts <<<"$CONTAINER_MOUNTS"
    for m in "${_mounts[@]}"; do
      echo "- \`${m%:*}\` (${m##*:})"
    done
  else
    echo "No extra host directories are bind-mounted into this container. If a large"
    echo "dependency (engine checkout, dataset, asset tree) would be better shared from"
    echo "the host than downloaded here, tell the user: they can list it in"
    echo "~/.config/docker-claude/container-mounts (or the project's .container-mounts)"
    echo "and it will appear at the path they choose on the next launch. The same goes"
    echo "for toolchains (Go, Rust, Haxe, ...): nothing beyond git, python3, node and"
    echo "build-essential is in the image. A host install can be mounted in, with its"
    echo "PATH and environment set through ~/.config/docker-claude/container-env."
  fi
  if [ -n "$_env_lines" ]; then
    echo
    echo "The launcher also set these environment variables for the session (from the"
    echo "user's container-env files; PATH entries are prepended to the image's PATH):"
    echo
    printf '%s' "$_env_lines"
  fi
  echo
  echo "\$CONTAINER_MOUNTS holds the same list as \`/path:mode;...\`."
} > /workspace/CLAUDE.md
cp /workspace/CLAUDE.md /workspace/AGENTS.md
chmod 644 /workspace/CLAUDE.md /workspace/AGENTS.md

# Disable GPG signing — the host's signing key isn't available in the container
gosu "$CLAUDE_USER" git config --global --unset commit.gpgsign 2>/dev/null || true
gosu "$CLAUDE_USER" git config --global --unset user.signingkey 2>/dev/null || true

# Harden: lock root account and strip setuid/setgid bits from all binaries
# except gosu itself (needed for the final exec). After gosu execs as claude,
# no root process remains, and the claude user has no path to escalate.
usermod -s /usr/sbin/nologin root
passwd -l root 2>/dev/null
find / -path /proc -prune -o -path /sys -prune -o \( -perm -4000 -o -perm -2000 \) -type f ! -name gosu -exec chmod a-s {} + 2>/dev/null || true

# Launch the requested agent. The run scripts set CONTAINER_AGENT to select
# which CLI to exec; both run with their sandbox/approval gates disabled since
# the container itself is the sandbox.
case "${CONTAINER_AGENT:-claude}" in
  codex)
    exec gosu "$CLAUDE_USER" codex --dangerously-bypass-approvals-and-sandbox "$@"
    ;;
  *)
    exec gosu "$CLAUDE_USER" claude --dangerously-skip-permissions "$@"
    ;;
esac
