FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    python3 \
    python3-venv \
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

# Install the Go toolchain and Ruff (the Python linter/formatter). Both are
# single self-contained trees, so they land in /opt — image-owned and OUTSIDE
# /home/claude — for the same reason everything else above does: the persistent
# claude-home volume is mounted over /home/claude at runtime and would mask or
# freeze anything installed under the home directory.
#
# Pin the versions so builds are reproducible; bump them and rebuild to upgrade,
# since the layer is otherwise cached.
#
# GOPATH, the module cache and the build cache live under /home/claude — on the
# persistent volume — so downloaded modules and compiled packages survive across
# runs while the toolchain itself stays owned by the image. They are set
# explicitly rather than left implicit: the defaults are derived from $HOME and
# $XDG_CACHE_HOME, and when either is unset or points somewhere unwritable the
# failure surfaces far from its cause ("mkdir /home/claude/.cache/go-build:
# permission denied" in the middle of an unrelated `go vet`). The entrypoint
# guarantees both directories exist and belong to the claude user on every start,
# and the `install -d` below seeds them with the right ownership for a fresh
# volume.
#
# $GOPATH/bin is on PATH so anything installed at runtime with `go install`
# (gopls, mockgen, a project's own codegen tool) is immediately runnable.
#
# GOTOOLCHAIN=local keeps a project's go.mod from silently downloading a
# different toolchain behind our back — including from a stale
# golang.org/toolchain@* tree left in the module cache by an earlier session —
# so `go` always means the /opt/go install below. Drop it if you want the
# Go 1.21+ auto-upgrade behavior.
ARG GO_VERSION=1.26.6
ARG RUFF_VERSION=0.16.3
ENV GOTOOLCHAIN=local \
    GOPATH=/home/claude/go \
    GOMODCACHE=/home/claude/go/pkg/mod \
    GOCACHE=/home/claude/.cache/go-build
ENV PATH="/opt/go/bin:/home/claude/go/bin:${PATH}"
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "$dpkgArch" in \
      amd64) goArch='amd64'; ruffArch='x86_64-unknown-linux-gnu' ;; \
      arm64) goArch='arm64'; ruffArch='aarch64-unknown-linux-gnu' ;; \
      *) echo "unsupported architecture: $dpkgArch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/go.tar.gz \
      "https://go.dev/dl/go${GO_VERSION}.linux-${goArch}.tar.gz"; \
    tar -xzf /tmp/go.tar.gz -C /opt; \
    mkdir -p /opt/ruff; \
    curl -fsSL -o /tmp/ruff.tar.gz \
      "https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}/ruff-${ruffArch}.tar.gz"; \
    tar -xzf /tmp/ruff.tar.gz -C /opt/ruff --strip-components=1; \
    ln -s /opt/ruff/ruff /usr/local/bin/ruff; \
    rm -f /tmp/go.tar.gz /tmp/ruff.tar.gz; \
    chmod -R a+rX /opt/go /opt/ruff; \
    install -d -o claude -g claude \
      /home/claude/.cache /home/claude/.cache/go-build \
      /home/claude/go /home/claude/go/bin /home/claude/go/pkg/mod; \
    go version; \
    ruff --version

# Install the Go developer tooling that daily Go work wants on top of the
# toolchain itself. `go build`, `go test`, `go vet` and `gofmt` already come with
# the Go install above; this layer adds the linters, import-fixer, debugger and
# test runner that are not part of the distribution:
#
#   golangci-lint  the standard meta-linter (runs govet, staticcheck, errcheck,
#                  ineffassign, unused, ... in one pass, honouring a project's
#                  .golangci.yml)
#   staticcheck    the same analyzers standalone, for `staticcheck ./...`
#   goimports      gofmt plus automatic import add/remove/grouping
#   dlv            the Delve debugger
#   gotestsum      `go test` with readable output and JUnit/JSON reports
#
# `go install` writes to $GOBIN, whose default (~/go/bin) sits on the persistent
# claude-home volume and would mask or freeze these binaries — the same trap the
# rest of this file avoids — so GOBIN points at /opt/gotools/bin, which is
# image-owned and goes on PATH. GOPATH/GOCACHE are redirected to /tmp for the
# duration of the build and deleted afterwards so the module downloads don't
# bloat the layer; at runtime they are back at their ~/go defaults (see above),
# where the persistent volume is exactly what you want.
#
# golangci-lint is installed from its release tarball rather than `go install`,
# which upstream discourages because the linter must be built against the same
# Go version it analyses with.
#
# gopls, the Go language server, is deliberately left out: nothing in this
# container speaks LSP and it is a large binary. Add it per project or per
# session with `go install golang.org/x/tools/gopls@latest` (it lands in
# ~/go/bin, which is on the persistent volume, so it survives).
#
# Pin the versions so builds are reproducible; bump them and rebuild to upgrade,
# since the layer is otherwise cached.
ARG GOLANGCI_LINT_VERSION=2.12.2
ARG STATICCHECK_VERSION=v0.7.0
ARG GOIMPORTS_VERSION=v0.49.0
ARG DELVE_VERSION=v1.27.1
ARG GOTESTSUM_VERSION=v1.13.0
ENV PATH="/opt/gotools/bin:${PATH}"
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "$dpkgArch" in \
      amd64) lintArch='linux-amd64' ;; \
      arm64) lintArch='linux-arm64' ;; \
      *) echo "unsupported architecture: $dpkgArch" >&2; exit 1 ;; \
    esac; \
    lintDir="golangci-lint-${GOLANGCI_LINT_VERSION}-${lintArch}"; \
    mkdir -p /opt/gotools/bin; \
    curl -fsSL -o /tmp/golangci-lint.tar.gz \
      "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/${lintDir}.tar.gz"; \
    tar -xzf /tmp/golangci-lint.tar.gz -C /opt/gotools/bin --strip-components=1 \
      "${lintDir}/golangci-lint"; \
    rm -f /tmp/golangci-lint.tar.gz; \
    export GOBIN=/opt/gotools/bin GOPATH=/tmp/gopath GOMODCACHE=/tmp/gopath/pkg/mod GOCACHE=/tmp/gocache; \
    go install "honnef.co/go/tools/cmd/staticcheck@${STATICCHECK_VERSION}"; \
    go install "golang.org/x/tools/cmd/goimports@${GOIMPORTS_VERSION}"; \
    go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}"; \
    go install "gotest.tools/gotestsum@${GOTESTSUM_VERSION}"; \
    go clean -modcache; \
    rm -rf /tmp/gopath /tmp/gocache; \
    chmod -R a+rX /opt/gotools; \
    golangci-lint --version; \
    staticcheck --version; \
    command -v goimports; \
    dlv version; \
    gotestsum --version

# Install pytest into its own virtualenv at /opt/pytest and put the runner on
# PATH. It lands in /opt — image-owned and OUTSIDE /home/claude — for the same
# reason everything else above does: the persistent claude-home volume is mounted
# over /home/claude at runtime and would mask or freeze anything installed under
# the home directory.
#
# A dedicated venv (rather than pip-installing into the system interpreter) is
# what Debian's PEP 668 "externally managed" python3 wants. The python3-venv
# package it needs is pulled in the apt layer at the top of this file, which also
# means projects can create their own venvs with `python3 -m venv .venv`.
#
# Note the scope: this pytest can only import what lives in its own venv, so it
# covers tests that need nothing beyond the standard library and the code under
# test. A project with third-party test dependencies should create its own venv
# and install pytest there (`python3 -m venv .venv && .venv/bin/pip install pytest`).
#
# Pin the version so builds are reproducible; bump it and rebuild to upgrade,
# since the layer is otherwise cached.
ARG PYTEST_VERSION=9.1.1
RUN set -eux; \
    python3 -m venv /opt/pytest; \
    /opt/pytest/bin/pip install --no-cache-dir --upgrade pip; \
    /opt/pytest/bin/pip install --no-cache-dir "pytest==${PYTEST_VERSION}"; \
    ln -s /opt/pytest/bin/pytest /usr/local/bin/pytest; \
    chmod -R a+rX /opt/pytest; \
    pytest --version

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
