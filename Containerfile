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

USER claude

RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

USER root
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
