#!/bin/bash

# Copy host SSH keys with correct ownership and permissions
# Remove existing keys first in case root-owned copies exist on the volume
if [ -d /tmp/.host-ssh ]; then
  rm -rf ~/.ssh
  mkdir -p ~/.ssh
  cp /tmp/.host-ssh/* ~/.ssh/
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/*
  chmod 644 ~/.ssh/*.pub 2>/dev/null || true
fi

# Copy host gitconfig (remove first in case a root-owned copy exists on the volume)
if [ -f /tmp/.host-gitconfig ]; then
  rm -f ~/.gitconfig
  cp /tmp/.host-gitconfig ~/.gitconfig
  # Disable GPG signing — the host's signing key isn't available in the container
  git config --global --unset commit.gpgsign 2>/dev/null || true
  git config --global --unset user.signingkey 2>/dev/null || true
fi

# Ensure GitHub host key is trusted for SSH operations
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true

exec claude --dangerously-skip-permissions "$@"
