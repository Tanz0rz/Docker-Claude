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

# System libraries for the toolchains mounted from the host. These are the one
# category that genuinely cannot come in over a bind mount (see the README's
# "Bring your toolchain from the host"): a mounted Chromium, HashLink build or
# SDL game is a dynamically linked ELF, and Debian in here has to supply the
# .so files it was linked against. The toolchains themselves still live on the
# host and arrive via container-mounts — only their shared-library floor is
# baked in.
#
# Keep this layer in sync with what the host tree actually ships. The browser
# half is not hand-written: it is Playwright's own `debian12-x64` dependency
# table for chromium + firefox + tools, which is the list `playwright
# install --with-deps` would install. Regenerate it after a Playwright upgrade
# with:
#
#   node -e 'const s=require("fs").readFileSync(
#     "node_modules/playwright-core/lib/coreBundle.js","utf8");
#     const i=s.indexOf("\"debian12-x64\":"); let j=s.indexOf("{",i),d=0,e=j;
#     for(;j<s.length;j++){if(s[j]==="{")d++;else if(s[j]==="}"&&--d===0){e=j+1;break}}
#     const o=eval("("+s.slice(s.indexOf("{",i),e)+")");
#     console.log([...new Set([...o.tools,...o.chromium,...o.firefox])].sort().join(" "))'
#
# webkit is deliberately not covered — the host tree installs chromium and
# firefox only. Add o.webkit to that union (and `playwright install webkit` on
# the host) if you ever want it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-freefont-ttf \
    fonts-ipafont-gothic \
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-tlwg-loma-otf \
    fonts-unifont \
    fonts-wqy-zenhei \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libatspi2.0-0 \
    libavcodec59 \
    libcairo-gobject2 \
    libcairo2 \
    libcups2 \
    libdbus-1-3 \
    libdbus-glib-1-2 \
    libdrm2 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libglib2.0-0 \
    libgtk-3-0 \
    libharfbuzz0b \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb-shm0 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxshmfence1 \
    libxtst6 \
    xfonts-scalable \
    xvfb \
  && rm -rf /var/lib/apt/lists/*

# The native half: the runtime .so files a host-built HashLink, Heaps/Kha game
# or SDL binary links against, the -dev headers and build tools those projects
# compile with, audio capture, and xdotool for driving a headed run under Xvfb.
#
# The runtime and -dev packages must stay matched to the host tree: the
# HashLink in ~/opt/docker-claude/hashlink is compiled *in this Debian* against
# exactly these libraries (see the README's "Refreshing the shared tree"), so
# dropping one here breaks `hl` with a missing-.so error rather than anything
# that names the real cause.
#
# unzip is here for Puppeteer: its browser downloads are zip archives and
# @puppeteer/browsers shells out to unzip, failing with "no zip archiver is
# available" without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    cmake \
    libasound2-dev \
    libasound2-plugins \
    libgl1-mesa-dev \
    libgl1-mesa-dri \
    libmbedcrypto7 \
    libmbedtls-dev \
    libmbedtls14 \
    libmbedx509-1 \
    libogg0 \
    libopenal-dev \
    libpng-dev \
    libpng16-16 \
    libsdl2-2.0-0 \
    libsdl2-dev \
    libsqlite3-dev \
    libturbojpeg0 \
    libturbojpeg0-dev \
    libudev-dev \
    libuv1 \
    libuv1-dev \
    libvorbis-dev \
    libvorbis0a \
    libvorbisfile3 \
    libvulkan-dev \
    libwayland-dev \
    libx11-dev \
    libxcursor-dev \
    libxi-dev \
    libxinerama-dev \
    libxkbcommon-dev \
    libxrandr-dev \
    pkg-config \
    pulseaudio \
    pulseaudio-utils \
    unzip \
    wayland-protocols \
    xdotool \
    zlib1g-dev \
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

# Install opencode the same way, for the same reason: /usr/local is in the
# image, so the binary is never masked by the home volume. The package pulls a
# prebuilt binary for the build platform via optionalDependencies.
#
# Pin the version so builds are reproducible; bump it (or use
# `copencode --update`) to re-fetch, since the layer is otherwise cached.
ARG OPENCODE_VERSION=1.18.34
RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" \
  && chmod -R a+rX /usr/local/lib/node_modules/opencode-ai \
  && npm cache clean --force
# As with Claude Code: the image owns the version, so opencode must not
# self-upgrade into the persistent home volume.
ENV OPENCODE_DISABLE_AUTOUPDATE=1

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
