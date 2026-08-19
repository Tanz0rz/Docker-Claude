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
# failures land far from the cause — `go build` dying with
# "mkdir /home/claude/.cache/go-build: permission denied", npm refusing to touch
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

# Cache and GOPATH directories the image's ENV points at. Creating them here
# means a volume that predates those settings still gets them, and the tools
# never have to create them as a side effect of the first build.
gosu "$CLAUDE_USER" mkdir -p \
  "$CLAUDE_HOME/.cache/go-build" \
  "$CLAUDE_HOME/go/bin" \
  "$CLAUDE_HOME/go/pkg/mod" 2>/dev/null || true

# haxelib keeps its repository path in ~/.haxelib, which lives on the persistent
# volume and so can outlive the directory it names — a session that ran
# `haxelib newrepo` under /tmp leaves a pointer to a path that no longer exists,
# and every later session sees an empty library repo instead of the image's
# Flixel stack. HAXELIB_PATH (set in the image) currently takes priority, so
# this is belt and braces: drop the file only when it points somewhere gone.
if [ -f "$CLAUDE_HOME/.haxelib" ]; then
  haxelib_repo="$(head -n1 "$CLAUDE_HOME/.haxelib" | tr -d '\r')"
  if [ -n "$haxelib_repo" ] && [ ! -d "$haxelib_repo" ]; then
    rm -f "$CLAUDE_HOME/.haxelib"
  fi
fi

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
