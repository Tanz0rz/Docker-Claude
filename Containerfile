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

# Install the Haxe toolchain and the HaxeFlixel game framework. The native
# libraries a Flixel game needs at *play* time (SDL2, GL, vorbis, ogg, mbedtls,
# turbojpeg, plus xvfb for headless runs) are already pulled in the apt layer at
# the top of this file — this layer only adds Haxe itself and the haxelibs.
#
# Neko is a runtime dependency of haxelib and is NOT bundled in Haxe's prebuilt
# tarball, so we install it too; its prebuilt ndll modules are statically linked,
# so no extra apt packages are required. Everything lands in /opt (image-owned),
# OUTSIDE /home/claude, for the same reason Claude Code does: the persistent
# claude-home volume is mounted over /home/claude at runtime and would otherwise
# mask or freeze anything installed under the home directory. The global haxelib
# repository lives at /opt/haxelib for the same reason, which keeps it read-only
# and reproducible; to add libraries for a specific project, run `haxelib newrepo`
# in that project to create a local, writable .haxelib.
#
# Pin the versions so builds are reproducible; bump them to re-fetch, since the
# layer is otherwise cached. The Flixel stack (lime/openfl/flixel/...) is pulled
# at its latest release at build time.
#
# Notes on the RUN below: libneko is registered with the dynamic linker via
# /etc/ld.so.conf.d so `neko` (and thus `haxelib run`) resolves it without a
# global LD_LIBRARY_PATH, and `/usr/local/bin/lime` is a thin wrapper around
# `haxelib run lime`.
ARG HAXE_VERSION=4.3.7
ARG NEKO_VERSION=2.4.1
ENV NEKOPATH=/opt/neko \
    HAXE_STD_PATH=/opt/haxe/std \
    HAXELIB_PATH=/opt/haxelib
ENV PATH="/opt/haxe:/opt/neko:${PATH}"
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "$dpkgArch" in \
      amd64) haxeArch='linux64';      nekoArch='linux64' ;; \
      arm64) haxeArch='linux-arm64';  nekoArch='linux-arm64' ;; \
      *) echo "unsupported architecture: $dpkgArch" >&2; exit 1 ;; \
    esac; \
    nekoTag="v$(echo "$NEKO_VERSION" | tr . -)"; \
    mkdir -p /opt/neko /opt/haxe /opt/haxelib; \
    curl -fsSL -o /tmp/neko.tar.gz \
      "https://github.com/HaxeFoundation/neko/releases/download/${nekoTag}/neko-${NEKO_VERSION}-${nekoArch}.tar.gz"; \
    tar -xzf /tmp/neko.tar.gz -C /opt/neko --strip-components=1; \
    curl -fsSL -o /tmp/haxe.tar.gz \
      "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-${haxeArch}.tar.gz"; \
    tar -xzf /tmp/haxe.tar.gz -C /opt/haxe --strip-components=1; \
    rm -f /tmp/neko.tar.gz /tmp/haxe.tar.gz; \
    echo /opt/neko > /etc/ld.so.conf.d/neko.conf && ldconfig; \
    printf '#!/bin/sh\nexec haxelib run lime "$@"\n' > /usr/local/bin/lime; \
    chmod 755 /usr/local/bin/lime; \
    haxelib setup /opt/haxelib; \
    haxelib install lime --always --quiet; \
    haxelib install openfl --always --quiet; \
    haxelib install flixel --always --quiet; \
    haxelib install flixel-addons --always --quiet; \
    haxelib install flixel-ui --always --quiet; \
    haxelib install flixel-tools --always --quiet; \
    haxelib install hxcpp --always --quiet; \
    chmod -R a+rX /opt/neko /opt/haxe /opt/haxelib

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
