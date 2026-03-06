#!/bin/bash

# Copy host SSH keys with correct ownership and permissions
# Using cp (not cp -a) so copies are owned by current user
if [ -d /tmp/.host-ssh ]; then
  mkdir -p ~/.ssh
  cp /tmp/.host-ssh/* ~/.ssh/
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/*
  chmod 644 ~/.ssh/*.pub 2>/dev/null || true
fi

# Copy host gitconfig
if [ -f /tmp/.host-gitconfig ]; then
  cp /tmp/.host-gitconfig ~/.gitconfig
fi

exec claude --dangerously-skip-permissions "$@"
