FROM node:22-slim

# Base tooling only. Language toolchains, engines, browsers and the like are
# deliberately NOT baked in: bring them from the host with the container-mounts
# and container-env files (see README "Bring your toolchain from the host"), or
# add a layer here for something every project of yours needs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    python3 \
    python3-venv \
    python3-pip \
    build-essential \
    ca-certificates \
    openssh-client \
    gpg \
    gosu \
    wl-clipboard \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

RUN userdel -r node && useradd -m -s /bin/bash -u 1000 claude

# Trust all /workspace paths so mounted repos work regardless of UID mismatch
# Use gh CLI as git credential helper (host gh config is mounted read-only)
RUN git config --system --add safe.directory '*' \
  && git config --system credential.helper '!gh auth git-credential'

# Install Claude Code into /opt, OUTSIDE /home/claude. The persistent
# claude-home volume is mounted over /home/claude at runtime, so anything
# installed under the home directory is masked by the volume and frozen at
# whatever version first seeded it — which is why plain rebuilds never updated
# the binary. Installing into /opt keeps the binary in the image, so
# `cclaude --update` rebuilds actually take effect.
#
# Pin the version so builds are reproducible; bump it (or use `--update`) to
# re-fetch, since the layer is otherwise cached.
ARG CLAUDE_CODE_VERSION=2.1.205
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh \
  && HOME=/opt/claude bash /tmp/claude-install.sh "${CLAUDE_CODE_VERSION}" \
  && rm /tmp/claude-install.sh \
  && chmod -R a+rX /opt/claude
ENV PATH="/opt/claude/.local/bin:${PATH}"
# The image owns the version; disable the native auto-updater so the running
# binary can't drift into the (persistent) home volume behind our back.
ENV DISABLE_AUTOUPDATER=1

# Install the OpenAI Codex CLI globally via npm. npm's global prefix is
# /usr/local (in the image), NOT under /home/claude, so the binary is never
# masked by the persistent claude-home volume — same reasoning as Claude Code
# living in /opt. The package pulls a prebuilt native binary for the build
# platform via optionalDependencies.
#
# Pin the version so builds are reproducible; bump it (or use `ccodex --update`)
# to re-fetch, since the layer is otherwise cached.
ARG CODEX_VERSION=0.144.1
RUN npm install -g "@openai/codex@${CODEX_VERSION}" \
  && chmod -R a+rX /usr/local/lib/node_modules/@openai \
  && npm cache clean --force

# Put the conventional user-level bin directories on PATH. Tools installed at
# runtime into the persistent home volume — the documented way to add something
# without a rebuild (rustup into ~/.cargo, pipx/pip --user into ~/.local) — drop
# their binaries here, but the agent is exec'd directly rather than through a
# login shell, so the `source ~/.profile` line those installers append is never
# read and their binaries would stay invisible.
#
# They are APPENDED, not prepended: the image's own copies of a tool must keep
# winning over anything the volume happens to hold (an old claude binary in
# ~/.local/bin from a pre-/opt volume is exactly the drift this file exists to
# prevent). The directories need not exist — PATH entries that don't resolve are
# ignored.
ENV PATH="${PATH}:/home/claude/.local/bin:/home/claude/.cargo/bin"

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
