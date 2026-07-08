FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    python3 \
    build-essential \
    ca-certificates \
    openssh-client \
    gpg \
    gosu \
    libpng16-16 \
    libturbojpeg0 \
    libvorbisfile3 \
    libvorbis0a \
    libogg0 \
    libmbedtls14 \
    libmbedx509-1 \
    libmbedcrypto7 \
    libsdl2-2.0-0 \
    libgl1-mesa-dri \
    libuv1 \
    xvfb \
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

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
