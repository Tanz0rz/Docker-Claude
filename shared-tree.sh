#!/usr/bin/env bash
# Provision the shared host toolchain tree that the container mounts.
#
# Why this exists at all: the container is Debian 12 (glibc 2.36), and a host is
# very often something newer or simply different (this was written on Arch,
# glibc 2.44). A binary from the host's own /usr/bin therefore cannot be
# bind-mounted in and run — it is linked against libraries and a glibc the image
# does not have. So everything here is either
#
#   * statically linked (ffmpeg), or
#   * an official distro-neutral tarball built against an old glibc (Go, Haxe,
#     Neko, the Playwright/Puppeteer browser builds, rustup's toolchains), or
#   * compiled *inside* a Debian 12 container against the very libraries the
#     image installs (HashLink, and the Go dev tools).
#
# The result is one tree, ~/opt/docker-claude, mounted read-only at /opt/dc by
# the container-mounts file and put on PATH by container-env. Nothing here is
# baked into the image except the shared-library floor those binaries link
# against (see the two apt layers in the Containerfile).
#
# Re-running is safe: each section replaces its own directory. Run it after
# bumping a version below, or to rebuild the tree on a new machine.
set -euo pipefail

SHARED="${SHARED_TREE:-$HOME/opt/docker-claude}"
BUILDER_NODE=node:22-slim      # matches the image's base
BUILDER_DEB=debian:12-slim     # same Debian as the image
BUILDER_PY=python:3.11-slim    # matches the image's python3 (Debian 12 => 3.11)

GO_VERSION=1.26.6
GOLANGCI_LINT_VERSION=2.12.2
STATICCHECK_VERSION=v0.7.0
GOIMPORTS_VERSION=v0.49.0
DELVE_VERSION=v1.27.1
GOTESTSUM_VERSION=v1.13.0
HAXE_VERSION=4.3.7
NEKO_VERSION=2.4.1
HASHLINK_COMMIT=781960a5daca32ad6d5cea87b255fe8b5872551e
INNOEXTRACT_COMMIT=6e9e34ed0876014fdb46e684103ef8c3605e382e
SEVENZIP_VERSION=26.03
SEVENZIP_TARBALL=7z2603-linux-x64.tar.xz

# The -dev/runtime packages HashLink is compiled against here. They must also be
# installed in the image, or the resulting `hl` fails with a missing .so at run
# time — keep this list and the Containerfile's native apt layer in step.
# Continued with backslashes rather than wrapped as a plain multi-line string:
# this is interpolated into the builder's script text, where a literal newline
# would end the apt-get command and turn the rest of the list into commands of
# its own ("libpng-dev: command not found").
HL_BUILD_DEPS="build-essential cmake pkg-config git ca-certificates \
libpng-dev libturbojpeg0-dev libsdl2-dev libgl1-mesa-dev libopenal-dev \
libmbedtls-dev libuv1-dev libvorbis-dev libsqlite3-dev zlib1g-dev"

UID_GID="$(id -u):$(id -g)"
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Run a builder container as root (so it can apt-get), with the tree mounted at
# /shared; ownership is handed back at the end of each caller's script.
#
# HOME points at /tmp inside the container, NOT at /shared. That matters: these
# run as root, and anything they drop in $HOME by habit — npm's _cacache, Go's
# telemetry directory, pip's cache — lands in the tree owned by root, where the
# unprivileged cleanup at the end of this script cannot delete it and the next
# run cannot overwrite it. Every tool that needs to write *into* the tree is
# told exactly where via an explicit variable instead.
builder() {
  local image="$1"; shift
  docker run --rm -u root -v "$SHARED:/shared" \
    -e HOME=/tmp -e npm_config_cache=/tmp/.npm -e PIP_CACHE_DIR=/tmp/.pip \
    -e GOTELEMETRY=off \
    "$image" bash -euc "$*"
}

mkdir -p "$SHARED"

say "ffmpeg (static build — runs on any glibc)"
rm -rf "$SHARED/ffmpeg"; mkdir -p "$SHARED/ffmpeg/bin"
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/ffmpeg.tar.xz" \
  https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar -xJf "$tmp/ffmpeg.tar.xz" -C "$SHARED/ffmpeg" --strip-components=1
mv "$SHARED/ffmpeg/ffmpeg" "$SHARED/ffmpeg/ffprobe" "$SHARED/ffmpeg/bin/"
rm -rf "$tmp"

say "Playwright + Puppeteer + their browsers"
# Installed from inside the image's own base so Playwright picks the debian12
# browser builds and npm resolves the same optional deps the container will.
# unzip is needed because @puppeteer/browsers shells out to it for its zips.
rm -rf "$SHARED/node" "$SHARED/browsers"; mkdir -p "$SHARED/node" "$SHARED/browsers"
builder "$BUILDER_NODE" '
  apt-get update -qq >/dev/null
  apt-get install -y -qq unzip ca-certificates >/dev/null 2>&1
  export PLAYWRIGHT_BROWSERS_PATH=/shared/browsers
  export PUPPETEER_CACHE_DIR=/shared/browsers/puppeteer
  cd /shared/node
  npm init -y >/dev/null
  npm install --no-fund --no-audit playwright @playwright/test puppeteer
  npx playwright install chromium firefox ffmpeg
  npx puppeteer browsers install chrome
  npx puppeteer browsers install chrome-headless-shell
  npx puppeteer browsers install chromedriver@stable
  chown -R '"$UID_GID"' /shared/node /shared/browsers
'

say "Python: playwright, selenium, pytest, ruff"
# Built against cp311 to match the image's Debian python3. pip --target writes
# console scripts whose shebang is the *builder's* interpreter path
# (/usr/local/bin/python3.11), which does not exist in the image — rewrite them
# to env python3 or every one of them fails with "bad interpreter".
rm -rf "$SHARED/python"; mkdir -p "$SHARED/python"
builder "$BUILDER_PY" '
  pip install --quiet --target /shared/python playwright selenium pytest pytest-asyncio ruff
  # Text console scripts only: ruff ships a native binary in bin/, which sed
  # would happily corrupt if its first bytes ever matched.
  for f in /shared/python/bin/*; do
    head -c2 "$f" | grep -q "^#!" || continue
    sed -i "1s|^#!/usr/local/bin/python3\.11$|#!/usr/bin/env python3|" "$f"
  done
  chown -R '"$UID_GID"' /shared/python
'

say "Go $GO_VERSION"
rm -rf "$SHARED/go"
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/go.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
tar -xzf "$tmp/go.tar.gz" -C "$SHARED"
rm -rf "$tmp"

say "Go developer tools"
# CGO_ENABLED=0 so these come out static and portable. The module/build caches
# are pointed at /tmp inside the builder so they never land in the shared tree
# (Go marks the module cache read-only, which makes it a nuisance to clean).
rm -rf "$SHARED/gotools"; mkdir -p "$SHARED/gotools/bin"
builder "$BUILDER_NODE" '
  apt-get update -qq >/dev/null
  apt-get install -y -qq ca-certificates >/dev/null 2>&1
  export PATH=/shared/go/bin:$PATH CGO_ENABLED=0 GOTOOLCHAIN=local
  export GOBIN=/shared/gotools/bin GOPATH=/tmp/gp GOMODCACHE=/tmp/gp/pkg/mod GOCACHE=/tmp/gc
  go install honnef.co/go/tools/cmd/staticcheck@'"$STATICCHECK_VERSION"'
  go install golang.org/x/tools/cmd/goimports@'"$GOIMPORTS_VERSION"'
  go install github.com/go-delve/delve/cmd/dlv@'"$DELVE_VERSION"'
  go install gotest.tools/gotestsum@'"$GOTESTSUM_VERSION"'
  chown -R '"$UID_GID"' /shared/gotools
'
# golangci-lint ships a release binary rather than `go install`, which upstream
# discourages: the linter must be built against the Go version it analyses with.
tmp="$(mktemp -d)"
gcl="golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64"
curl -fsSL -o "$tmp/gcl.tar.gz" \
  "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/${gcl}.tar.gz"
tar -xzf "$tmp/gcl.tar.gz" -C "$SHARED/gotools/bin" --strip-components=1 "${gcl}/golangci-lint"
rm -rf "$tmp"

say "Haxe $HAXE_VERSION + Neko $NEKO_VERSION"
rm -rf "$SHARED/haxe" "$SHARED/neko"; mkdir -p "$SHARED/haxe" "$SHARED/neko"
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/haxe.tar.gz" \
  "https://github.com/HaxeFoundation/haxe/releases/download/${HAXE_VERSION}/haxe-${HAXE_VERSION}-linux64.tar.gz"
curl -fsSL -o "$tmp/neko.tar.gz" \
  "https://github.com/HaxeFoundation/neko/releases/download/v$(echo "$NEKO_VERSION" | tr . -)/neko-${NEKO_VERSION}-linux64.tar.gz"
tar -xzf "$tmp/haxe.tar.gz" -C "$SHARED/haxe" --strip-components=1
tar -xzf "$tmp/neko.tar.gz" -C "$SHARED/neko" --strip-components=1
rm -rf "$tmp"

say "haxelibs (HaxeFlixel + Heaps stacks)"
# Left read-write when mounted, so `haxelib install` works inside the container
# and the result persists here.
mkdir -p "$SHARED/haxelib"
builder "$BUILDER_NODE" '
  apt-get update -qq >/dev/null
  apt-get install -y -qq ca-certificates >/dev/null 2>&1
  export PATH=/shared/haxe:/shared/neko:$PATH LD_LIBRARY_PATH=/shared/neko
  export HAXE_STD_PATH=/shared/haxe/std NEKOPATH=/shared/neko HAXELIB_PATH=/shared/haxelib
  haxelib setup /shared/haxelib >/dev/null
  for l in lime openfl flixel flixel-addons flixel-ui flixel-tools hxcpp \
           heaps hlsdl hlopenal hashlink format; do
    haxelib install "$l" --always --quiet || echo "WARNING: haxelib $l failed"
  done
  haxelib list
  chown -R '"$UID_GID"' /shared/haxelib
'

say "HashLink (built in Debian 12 against the image's libraries)"
rm -rf "$SHARED/hashlink"
builder "$BUILDER_DEB" '
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends '"$HL_BUILD_DEPS"' >/dev/null 2>&1
  mkdir -p /tmp/hl && cd /tmp/hl
  git init -q
  git remote add origin https://github.com/HaxeFoundation/hashlink.git
  git fetch -q --depth 1 origin '"$HASHLINK_COMMIT"'
  git checkout -q FETCH_HEAD
  make -j"$(nproc)" >/dev/null 2>&1
  # `make install` hardcodes /usr/local regardless of INSTALL_DIR/PREFIX, so
  # place the artifacts by hand.
  mkdir -p /shared/hashlink/bin /shared/hashlink/lib /shared/hashlink/include
  cp hl /shared/hashlink/bin/
  cp libhl.so *.hdll /shared/hashlink/lib/
  cp src/hl.h src/hl_ffi.h src/hlc.h src/hlc_main.c /shared/hashlink/include/
  chown -R '"$UID_GID"' /shared/hashlink
'

say "innoextract + 7-Zip (installer extraction)"
# innoextract reads Inno Setup installers (.exe) — the format a lot of Windows
# game and app installers use.
#
# Built from a pinned master commit rather than the 1.9 release, because the
# release is from 2020 and stops at Inno Setup 6.0.5: it refuses 6.3.x with
# "Unexpected setup data version", which is most of what you meet in practice.
# Master reaches 6.3.3. Verified here: on a 6.3.3 installer the release build
# fails and this one extracts 94 files.
#
# Ceiling worth knowing: Inno Setup 6.5+ changed the setup loader, and NO build
# of innoextract handles it yet — those fail with "Unexpected setup loader
# revision: 2". There is no Linux-native tool for them at the time of writing.
#
# Linked fully static (-static plus USE_STATIC_LIBS, which covers boost, lzma
# and bz2) so the binary carries no runtime dependency on the image at all —
# it works whether or not the Containerfile's library layers are present.
rm -rf "$SHARED/innoextract"; mkdir -p "$SHARED/innoextract"
tmp="$(mktemp -d)"
# The 1.9 release tarball is kept for its man page and licenses, and its binary
# stays reachable as `innoextract-1.9` for comparing behaviour on a bad file.
curl -fsSL -o "$tmp/innoextract.tar.xz" \
  https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-linux.tar.xz
tar -xJf "$tmp/innoextract.tar.xz" -C "$SHARED/innoextract" --strip-components=1
rm -rf "$tmp"
builder "$BUILDER_DEB" '
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends build-essential cmake git \
    ca-certificates pkg-config binutils libboost-all-dev liblzma-dev \
    libbz2-dev zlib1g-dev >/dev/null 2>&1
  mkdir -p /tmp/ie && cd /tmp/ie
  git init -q
  git remote add origin https://github.com/dscharrer/innoextract.git
  git fetch -q --depth 1 origin '"$INNOEXTRACT_COMMIT"'
  git checkout -q FETCH_HEAD
  mkdir build && cd build
  cmake .. -DCMAKE_BUILD_TYPE=Release -DUSE_STATIC_LIBS=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-static" >/dev/null 2>&1
  make -j"$(nproc)" >/dev/null 2>&1
  strip innoextract
  mkdir -p /shared/innoextract/bin/master
  cp innoextract /shared/innoextract/bin/master/innoextract
  ./innoextract --version | head -2
  chown -R '"$UID_GID"' /shared/innoextract
'

# 7-Zip, for everything that is not Inno: zip, 7z, cab, msi, NSIS installers,
# and listing a PE. It does NOT read Inno payloads — on an Inno installer it
# only reports the PE wrapper — so it complements innoextract rather than
# replacing it. 7zzs is upstream's fully static build; 7zz is the dynamic one.
rm -rf "$SHARED/sevenzip"; mkdir -p "$SHARED/sevenzip"
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/7z.tar.xz" \
  "https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION}/${SEVENZIP_TARBALL}"
tar -xJf "$tmp/7z.tar.xz" -C "$SHARED/sevenzip"
rm -rf "$tmp"

say "stable bin/ names"
# The browser directories carry build numbers (chromium-1234, linux-152.0.x)
# that change on every upgrade. bin/ gives them fixed names so container-env's
# PATH never has to know a version. Symlinks are relative so they resolve
# through whatever single path the tree is mounted at.
rm -rf "$SHARED/bin"; mkdir -p "$SHARED/bin"
( cd "$SHARED/bin"
  ln -sfn ../ffmpeg/bin/ffmpeg  ffmpeg
  ln -sfn ../ffmpeg/bin/ffprobe ffprobe
  ln -sfn "../$(cd "$SHARED" && ls -d browsers/firefox-*/firefox/firefox)" firefox
  ln -sfn "../$(cd "$SHARED" && ls -d browsers/puppeteer/chromedriver/linux-*/chromedriver-linux64/chromedriver)" chromedriver
  ln -sfn ../innoextract/bin/master/innoextract innoextract
  ln -sfn ../innoextract/bin/amd64/innoextract  innoextract-1.9
  # 7zzs is the static build; expose it under both the names scripts look for.
  ln -sfn ../sevenzip/7zzs 7z
  ln -sfn ../sevenzip/7zzs 7zz
)
# Chromium's own sandbox needs unprivileged user namespaces, which the default
# container seccomp profile blocks, and it outgrows the 64 MB /dev/shm a
# container gets. Playwright passes both flags itself; these wrappers make the
# standalone browsers behave the same. The path is globbed at run time so an
# upgrade's new build number doesn't leave a dangling wrapper.
cat > "$SHARED/bin/chromium" <<'EOF'
#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
set -- --no-sandbox --disable-dev-shm-usage "$@"
exec $(ls "$dir"/../browsers/chromium-*/chrome-linux64/chrome | head -1) "$@"
EOF
cat > "$SHARED/bin/chrome" <<'EOF'
#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
set -- --no-sandbox --disable-dev-shm-usage "$@"
exec $(ls "$dir"/../browsers/puppeteer/chrome/linux-*/chrome-linux64/chrome | head -1) "$@"
EOF
chmod 755 "$SHARED/bin/chromium" "$SHARED/bin/chrome"

# Belt and braces: the builders keep their caches in /tmp (see builder()), but
# an older tree may still carry them, and npm leaves a package.json behind at
# the root when it runs there. Failures are ignored so a stray root-owned
# leftover cannot abort an otherwise good run.
rm -rf "$SHARED/.npm" "$SHARED/.cache" "$SHARED/.config" "$SHARED/.local" \
       "$SHARED/.bash_history" "$SHARED/package.json" 2>/dev/null || true

say "done — $SHARED ($(du -sh "$SHARED" | cut -f1))"
echo "Mounted at /opt/dc by ~/.config/docker-claude/container-mounts;"
echo "put on PATH by ~/.config/docker-claude/container-env."
