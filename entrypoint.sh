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

# Ensure GitHub host key is trusted for SSH operations
gosu "$CLAUDE_USER" ssh-keyscan github.com >> "$CLAUDE_HOME/.ssh/known_hosts" 2>/dev/null || true
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/known_hosts" 2>/dev/null || true

# Disable GPG signing — the host's signing key isn't available in the container
gosu "$CLAUDE_USER" git config --global --unset commit.gpgsign 2>/dev/null || true
gosu "$CLAUDE_USER" git config --global --unset user.signingkey 2>/dev/null || true

# Harden: lock root account and strip setuid/setgid bits from all binaries
# except gosu itself (needed for the final exec). After gosu execs as claude,
# no root process remains, and the claude user has no path to escalate.
usermod -s /usr/sbin/nologin root
passwd -l root 2>/dev/null
find / -path /proc -prune -o -path /sys -prune -o \( -perm -4000 -o -perm -2000 \) -type f ! -name gosu -exec chmod a-s {} + 2>/dev/null || true

exec gosu "$CLAUDE_USER" claude --dangerously-skip-permissions "$@"
