# Containerized Claude Code, Codex & opencode

Run [Claude Code](https://claude.ai), the [OpenAI Codex CLI](https://github.com/openai/codex) and [opencode](https://opencode.ai) in a container with their sandbox/approval gates disabled, safely isolated from your host system.

The image bundles **all three** agents. Launch Claude Code with `cclaude`, Codex with `ccodex` and opencode with `copencode` — same container, same isolation, same persistent home. `copencode` picks up your host opencode config, including a model served locally (llama.cpp, Ollama) — see [opencode and local models](#opencode-and-local-models).

## Why

Running these agents with their approval gates off (`claude --dangerously-skip-permissions` / `codex --dangerously-bypass-approvals-and-sandbox`) gives the AI full autonomy but also full access to your system. A container restricts it to only the mounted project directory — the agent can't touch anything else on your host.

## Quick start

Install [Docker or Podman](#prerequisites-per-os) first, then run the one-line installer.

**macOS / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/Tanz0rz/Docker-Claude/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/Tanz0rz/Docker-Claude/main/install.ps1 | iex
```

This fetches the repo to a fixed location and installs the `cclaude` (Claude Code), `ccodex` (Codex CLI) and `copencode` (opencode) launchers. It does **not** modify your shell config — it prints the one line to add to your PATH so you can decide. (Pass `--modify-path`, or set `DOCKER_CLAUDE_MODIFY_PATH=1`, to have it edit your rc for you.) Once on PATH, from any project directory:

```bash
cclaude        # launch Claude Code
ccodex         # launch the Codex CLI
copencode      # launch opencode
```

The first launch builds the image and prompts you to `/login`. After that, `cclaude --update` / `ccodex --update` / `copencode --update` keeps everything current — it pulls the latest launcher source *and* the latest agent release, then rebuilds. Re-running the installer is only needed if the launcher shims themselves change.

### Prerequisites per OS

Docker or Podman must be installed before running the installer — see your OS guide (each also documents a manual clone-and-alias setup if you'd rather not use the installer):

| OS | Guide | Prerequisite |
|---|---|---|
| [macOS](macos/README.md) | [macos/README.md](macos/README.md) | Docker Desktop or Podman |
| [Linux](linux/README.md) | [linux/README.md](linux/README.md) | Docker or Podman |
| [Windows](windows/README.md) | [windows/README.md](windows/README.md) | Docker Desktop + WSL 2 |

## How it works

- **Containerfile** — a deliberately small Debian-based image: Node.js 22, the Claude Code CLI, the OpenAI Codex CLI, opencode, gh CLI, and the base dev tools (git, curl, jq, python3 + venv + pip, build-essential), plus the *shared libraries* that host-mounted toolchains link against (the browser/font set Playwright asks for on Debian 12, and the SDL/GL/OpenAL/mbedTLS/Vorbis stack a HashLink or Heaps build needs, with `xvfb`, `xdotool` and PulseAudio for headed and audio runs). No language toolchains, engines or browsers themselves are baked in — you bring those from the host, per machine or per project, without rebuilding (see [Bring your toolchain from the host](#4-bring-your-toolchain-from-the-host-no-rebuild) and [The shared host toolchain tree](#5-the-shared-host-toolchain-tree))
- **run.sh / run.bat** — Builds the image, creates a persistent volume, and runs the container with your project mounted at `/workspace`. Each OS directory has its own run script. The `AGENT` env var (set by the `ccodex` and `copencode` launchers) selects which agent runs; it defaults to `claude`.
- **Named volume** (`claude-home`) — Persists `/home/claude` across runs, including the agents' auth tokens, settings, memory, and history, plus whatever caches the tools you use write there (npm's cache, a Go module cache, a cargo registry). Because it outlives any single image, the entrypoint repairs its ownership on every start — see [Home volume permissions](#home-volume-permissions)
- **Project mount** — Your current directory is bind-mounted to `/workspace/<project>` so the agent can read and edit your code

### Launch options

A launch is controlled by a few launcher options and two environment variables.
Run `cclaude --help` (or `ccodex --help` / `copencode --help`) to see them; the run script also prints
the resolved config as a banner on startup.

**Launcher options** — these must come **before** the agent's arguments. They're
parsed front-anchored: the first token the launcher doesn't recognize (or a
literal `--`) ends option parsing, and everything after is forwarded to the agent
untouched. That's why the launcher's options can never clash with the agent's own
flags.

| Option | Effect |
|---|---|
| `--no-git` | Withhold git identity and credentials for this launch (same as `GIT_ACCESS=0`). |
| `--git` | Force git access on for this launch, overriding the `GIT_ACCESS` env var. |
| `--no-mounts` | Ignore every container-mounts and container-env file for this launch (same as `EXTRA_MOUNTS=0`). See [Bind a host directory in](#3-bind-a-host-directory-in-per-project-no-rebuild). |
| `--update` | Pull the latest launcher source and agent release, rebuild the image, then launch. |
| `-h`, `--help` | Show the launcher's help. |
| `--` | Stop parsing launcher options; pass everything after straight to the agent. |

```bash
ccodex --no-git                 # Codex, no access to your git credentials
ccodex --no-git exec "review"   # launcher opts first, then the agent's args
ccodex resume --last            # 'resume' ends parsing; both go to Codex
ccodex -- --help                # reach Codex's own help (see the first line of `ccodex --help`)
```

**Environment variables:**

| Variable | Default | Effect |
|---|---|---|
| `AGENT` | `claude` | Which agent to run: `claude`, `codex` or `opencode`. The `ccodex` and `copencode` launchers just set `AGENT=codex` / `AGENT=opencode`. |
| `GIT_ACCESS` | `1` | Whether the host's git identity and credentials (gitconfig, SSH keys, gh token/config) are shared. Set `0`/`false`/`no`/`off` to withhold them — and scrub any left in the volume by a prior run. A `--git`/`--no-git` option overrides this. |
| `EXTRA_MOUNTS` | `1` | Whether the container-mounts and container-env files (global and repo-local) are honored. Set `0`/`false`/`no`/`off` to launch with none of their mounts or variables. `--no-mounts` is the same thing. |

## What's isolated

| | Host | Container |
|---|---|---|
| Filesystem | Protected | Only `/workspace` (your project) is mounted, plus any directories your container-mounts files opt in |
| Processes | Protected | No access to host processes |
| Network | Protected | Outbound access only (bridge mode) — which includes host services listening beyond loopback, if the host firewall admits the bridge |
| Privilege escalation | Protected | Runs as the unprivileged `claude` user; capabilities dropped bar the five the entrypoint's root stage needs, plus no-new-privileges |

## What's shared

- **Git config** — Copied from host at startup so commits use your identity (unless `GIT_ACCESS=0`)
- **SSH keys** — Copied from host at startup for private repo access (unless `GIT_ACCESS=0`)
- **Auth** — The host's `~/.claude` and `~/.codex` are shared so logins and token refreshes persist in both directions (host and container). `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are forwarded when set. (Agent auth is always shared — it is not affected by `GIT_ACCESS`.)
- **opencode config (`copencode` only)** — The host's `~/.config/opencode` is copied in at startup, with loopback URLs pointed at the host (see [opencode and local models](#opencode-and-local-models))
- **Project directory** — Read-write mount of your current directory
- **Extra host directories** — Whatever the container-mounts files list, bind-mounted at the paths it names (see [Bind a host directory in](#3-bind-a-host-directory-in-per-project-no-rebuild)); each one is printed in the launch banner
- **Extra environment** — Whatever the container-env files list (`PATH` additions, `GOROOT`, …) so mounted toolchains are usable (see [Bring your toolchain from the host](#4-bring-your-toolchain-from-the-host-no-rebuild)); each variable is printed in the launch banner
- **Clipboard (Linux/Wayland only)** — The Wayland compositor socket is mounted so image paste (ctrl+v) works in the TUI
- **Terminal identity (Linux/macOS)** — `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `COLORTERM` are forwarded when set, so the TUI recognizes the terminal it is really talking to and enables its extended key encodings (kitty keyboard protocol, xterm modifyOtherKeys). Without them the container sees a generic `TERM=xterm` and keys that need a distinct code — ctrl+backspace word-delete, for one — arrive as ambiguous legacy codes and do nothing

## opencode and local models

`copencode` runs [opencode](https://opencode.ai) with the same isolation, git/SSH sharing, mounts and environment as the other two launchers. What differs is where its configuration comes from, because the usual reason to run it is a model served from your own machine.

- **Config is copied, not shared.** The host's `~/.config/opencode` (`opencode.json`, key files referenced as `{file:~/.config/opencode/…}`, agents, commands) is staged read-only and copied into the home volume on every `copencode` launch. The host stays the source of truth; edits made inside the container are discarded at the next launch and never reach the config your host's unsandboxed opencode runs with. It is not mounted at all for `cclaude` / `ccodex`.
- **Loopback URLs are pointed at the host.** A provider with `"baseURL": "http://127.0.0.1:8081/v1"` means "the llama.cpp server on this machine" — but inside the container, `127.0.0.1` is the container. Every `http(s)://127.0.0.1`, `localhost` or `[::1]` URL in the copied `opencode.json` / `opencode.jsonc` is rewritten to `host.docker.internal`, which the launcher maps to the host. Your host config needs no container-specific variant.
- **Permission prompts are off**, as for the other agents: the entrypoint sets `OPENCODE_PERMISSION` to allow every tool, overriding an `"ask"` in the host config for the container only.
- **Sessions and any `/connect` logins** live in the home volume (`~/.local/share/opencode`), separate from the host's.

Two things on the host have to be true for a local model server to be reachable, and neither can be fixed from inside the container:

1. **The server must listen beyond loopback** — `llama-server --host 0.0.0.0` (or the Docker bridge address), `OLLAMA_HOST=0.0.0.0` for Ollama. A server bound to `127.0.0.1` only is invisible to the container.
2. **The host firewall must let the container in.** With ufw's default deny-incoming, traffic from the Docker bridge to a host port is dropped and opencode just hangs on its first request. Allow the port from the bridge only:

   ```
   sudo ufw allow in on docker0 to any port 8081 proto tcp
   ```

To check from the host that the container can see the server:

```
docker run --rm --add-host=host.docker.internal:host-gateway --entrypoint curl \
  claude-code -s -m 5 -o /dev/null -w '%{http_code}\n' http://host.docker.internal:8081/health
```

`200` means opencode will connect; `000` after a five-second wait is the firewall (or the bind address).

## Home volume permissions

The `claude-home` volume outlives any single image, so it accumulates files owned by whoever wrote them — root (when the container runtime creates a mount point) or a stranger UID (from an image built when the container user was not 1000). Those directories are unwritable for the `claude` user, and the failure surfaces nowhere near the cause:

```
mkdir /home/claude/.cache/some-tool: permission denied
```

with `~/.cache` owned by a UID that no longer exists in the image. The entrypoint therefore repairs ownership of the whole home tree on every start (`chown` to 1000:1000 for anything that isn't already), skipping the host bind mounts `~/.claude`, `~/.codex` and `~/.config/gh`, which belong to the host user. Nothing needs to be done by hand; an old volume is fixed by the next launch.

This runs in the entrypoint's root stage, before `gosu` drops to the `claude` user, so the container has to hold `CAP_CHOWN` (and `CAP_SETUID`/`CAP_SETGID` for the drop itself). All three run scripts grant exactly those under Docker and use `--userns=keep-id` under Podman — see [Security model](#whats-protected). If you have customized the flags and stripped them, the repair is skipped, and the manual equivalent is:

```
docker run --rm -u 0 --entrypoint chown -v claude-home:/home/claude \
  claude-code -R 1000:1000 /home/claude
```

## Managing dependencies

> The `cclaude`, `ccodex` and `copencode` commands are the launchers installed by the [one-line installer](#quick-start) (or set up manually per the OS guide). All wrap this repo's `run.sh` / `run.bat`, with `ccodex` and `copencode` setting `AGENT=codex` / `AGENT=opencode`.

The image ships the base dev tools (git, curl, jq, python3 + venv + pip, build-essential) on top of Node.js and the three agents, plus the shared libraries that host-mounted toolchains link against. Everything else — a language toolchain, a game engine, a browser — comes in one of the ways below. For anything you already have on the host, reach for the fourth first; the fifth is the ready-made tree this repo ships a script for, and is what most of these options are in service of:

### 1. Add to the Containerfile (permanent)

For things every project of yours needs *and* that can't come from the host — chiefly Debian packages: shared libraries a mounted toolchain links against (SDL2, OpenGL, ALSA…), `cmake`, `xvfb` — add them to the Containerfile's `apt-get install` line. A self-contained toolchain can also be given its own `/opt` layer, but consider [mounting it from the host](#4-bring-your-toolchain-from-the-host-no-rebuild) instead: no rebuild, no version pin to maintain, and the container uses exactly what you use.

The step that trips people up: **the launchers build from their own checkout, not from whichever clone you edited.** Under the installer that is `~/.local/share/docker-claude` (`%LOCALAPPDATA%\docker-claude` on Windows). An edit anywhere else is invisible to the build. So the normal loop is to push the change and let `--update` fetch it back:

```
git commit -am "Add <tool> to the image"
git push
cclaude --update   # pulls the change, rebuilds, launches
```

That is also the path every other machine takes to get the tool, which is reason enough to use it yourself rather than building by hand.

To iterate without pushing, build the image straight from your working copy and launch *without* `--update` — which would otherwise rebuild from the managed checkout and throw your build away:

```
docker build -t claude-code -f Containerfile .
cclaude   # no --update; reuses the image you just built
```

### 2. Install to the named volume (persistent, no rebuild)

Tools installed to `/home/claude` (the named volume) persist across sessions. For example, Claude could install [uv](https://docs.astral.sh/uv/) without a rebuild:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh   # installs into ~/.local/bin, on the volume
```

This works for any tool that supports user-level installation (pip, cargo, npm globals, language version managers, etc.).

The conventional user-level bin directories are already on `PATH`, so a tool installed this way is runnable immediately:

| Directory | Filled by |
| --- | --- |
| `~/.local/bin` | `pip install --user`, `pipx`, most `install.sh` scripts |
| `~/.cargo/bin` | `cargo install`, and rustup itself if you install it here |

This matters because the agent is `exec`'d directly rather than through a login shell: the `source ~/.profile` line installers like rustup append to your shell config is never read, so without those entries the binaries would be invisible despite installing fine. They are appended *after* the image's own directories, so an image-owned tool always wins over a stale copy in the volume — and *after* anything a container-env file prepends, so a toolchain mounted from the host wins over both.

### 3. Bind a host directory in (per project, no rebuild)

Some dependencies are too big for either of the above: a multi-gigabyte engine checkout, a dataset, an asset tree shared between projects. Baking one into the image makes every rebuild download it again; cloning it into the volume or the workspace repeats that per machine and bloats the project. Instead, keep one copy on the host and bind it into the container per project.

Mounts are declared in up to two files, read in this order (each optional, same format):

| File | Applies to |
|---|---|
| `~/.config/docker-claude/container-mounts` | Every launch, any project. The place for your own big dependencies — nothing in any repo or `.gitignore` changes |
| `<project>/.container-mounts` | That project, committed alongside it |

(`XDG_CONFIG_HOME` is honored on Linux/macOS; on Windows the directory is `%APPDATA%\docker-claude`.)

One mount per line, whitespace-separated:

```
# host_path        [container_path]   [ro]
~/src/Kha          /opt/Kha           ro     # a pinned Kode/Kha checkout, ~1.2 GB
../shared-assets                             # -> /mnt/shared-assets, read-write
```

- The host path may be absolute, `~/…`, or relative to the project directory (whichever file it comes from). On Windows, `~` expands to `%USERPROFILE%` and forward slashes work.
- The container path defaults to `/mnt/<basename>` when omitted. It must be absolute; the launcher refuses anything under `/home/claude` or the workspace, since that would shadow the volume or the project.
- `ro` mounts read-only; the default is read-write. Bind mounts are free at runtime, so a long global list costs nothing — but every session sees all of them, so prefer `ro` for anything a project only needs to read.
- Blank lines and `#` comments are ignored. Paths with spaces are not supported.
- A host path that doesn't exist is skipped with a warning rather than aborting the launch, so a committed file still works on a machine that lacks one of the paths. Prefer `~/…` and relative paths over absolute ones for the same reason.

The banner lists every mount that was applied, from both files. Since the repo-local file lives inside whatever repo you just cloned, check it before the first launch on unfamiliar code, or launch with `--no-mounts` (or `EXTRA_MOUNTS=0`) to ignore all of them. See [Security model](#security-model).

The agent is told what was mounted: the entrypoint writes `/workspace/CLAUDE.md` (and `AGENTS.md` for Codex) listing every mounted path, and `$CONTAINER_MOUNTS` carries the same list as `/path:ro;/other:rw`. So an agent asked for Kha finds `/opt/Kha` listed there instead of cloning it. If it reports a path missing, look at the launch banner's `Mounts:` line — a warning there (host path absent, launcher not yet updated) is the usual cause.

For the Kha example above, the project's build then references the mount directly (`node /opt/Kha/make html5`), and a fresh container starts with the engine already present.

### 4. Bring your toolchain from the host (no rebuild)

A bind mount gets a toolchain's files into the container, but a mounted `/opt/go` is inert until `/opt/go/bin` is on `PATH`, and Haxe or rustup need a variable or two besides. The **container-env** files cover that half. They follow the same two-file scheme as the mounts, read in the same order, disabled by the same `--no-mounts`:

| File | Applies to |
|---|---|
| `~/.config/docker-claude/container-env` | Every launch, any project |
| `<project>/.container-env` | That project, committed alongside it |

One `KEY=VALUE` per line, with *container-side* values — Linux paths, no quoting, no `$VAR` expansion, no `;`. `PATH` is the one special case: its value is **prepended** to the image's `PATH` by the entrypoint, so you list what to add without knowing what's already there. Blank lines and `#` comments are ignored; names the launcher owns (`HOME`, `GIT_ACCESS`, `CONTAINER_*`, the agents' auth variables) are refused with a warning. The banner's `Env:` line shows every variable applied.

Pair the two files and a host install of any Linux toolchain works unchanged inside the container. The pattern is always the same — mount the install read-only, put its `bin` first on `PATH`, keep its writable state on the persistent volume — so a few worked examples cover most of it. Each pair is `container-mounts` on top, `container-env` below:

**Go** (a `go.dev` tarball unpacked to `~/sdk/go`, or your distro's `/usr/lib/go`):

```
~/sdk/go            /opt/go            ro
```
```
PATH=/opt/go/bin:/home/claude/go/bin
GOROOT=/opt/go
GOTOOLCHAIN=local          # never download a different Go behind your back
```

Modules, the build cache and `go install`ed tools land under `~/go` and `~/.cache` by default — on the volume, where they survive across sessions. Mount `~/go/bin` from the host too if you want your host-installed `gopls`/`golangci-lint`.

**Rust** (a host rustup install):

```
~/.rustup           /opt/rustup        ro
~/.cargo/bin        /opt/cargo-bin     ro
```
```
PATH=/opt/cargo-bin
RUSTUP_HOME=/opt/rustup
```

`CARGO_HOME` stays at its default `~/.cargo` in the container, so the registry cache and `cargo install`ed binaries go on the volume. `rustup toolchain install` won't work against the read-only mount; run it on the host and the container sees the result next launch.

**Haxe + HashLink** (host installs of Haxe, Neko and a HashLink build):

```
~/opt/haxe          /opt/haxe          ro
~/opt/neko          /opt/neko          ro
~/opt/hashlink      /opt/hashlink      ro
~/haxelib           /opt/haxelib              # read-write: haxelib install works
```
```
PATH=/opt/haxe:/opt/neko:/opt/hashlink/bin
HAXE_STD_PATH=/opt/haxe/std
HAXELIB_PATH=/opt/haxelib
NEKOPATH=/opt/neko
LD_LIBRARY_PATH=/opt/neko:/opt/hashlink/lib
```

**Kha** — a plain source checkout needs only the mount (`~/src/Kha /opt/Kha ro`, from the section above); the project's build refers to it directly.

What *doesn't* mount cleanly is a toolchain's system-level dependencies: the shared libraries a HashLink or SDL game links against, the apt packages a browser build needs, `xvfb` for headed runs. Those are Debian packages and belong in the Containerfile ([option 1](#1-add-to-the-containerfile-permanent)) — a one-line `apt-get` addition per project type, which is a far smaller thing to maintain than the toolchain itself. Prefer a distro-neutral install (an official tarball, rustup, a `~/opt` build) over your package manager's for anything you plan to mount: Debian in the container can't run a binary that links against a library it doesn't have.

The agent is told about the environment the same way it's told about mounts: the generated `/workspace/CLAUDE.md` lists each variable, so it knows `go` is at `/opt/go/bin` before it tries to install one.

### 5. The shared host toolchain tree

Sections 3 and 4 describe the mechanism; this is the concrete tree this repo ships a script for. [`shared-tree.sh`](shared-tree.sh) builds `~/opt/docker-claude` — one directory holding every toolchain that used to be baked into the image — and the two global config files mount it at `/opt/dc` and put it on `PATH`.

Run it once per machine:

```
./shared-tree.sh          # ~3 GB and a good few minutes; over half of it is browsers
```

**The constraint that shapes it.** The image is Debian 12 (glibc 2.36); your host almost certainly isn't — this was written on Arch with glibc 2.44. A binary bind-mounted from the host's `/usr/bin` therefore *cannot run in the container*: it is linked against a newer glibc and libraries Debian 12 doesn't ship. The failure is a bare `version 'GLIBC_2.38' not found`, or a missing `.so`, well away from anything that names the cause. So nothing in the tree is copied from the host's package manager. Every piece is one of:

| Kind | Why it works in Debian 12 | Examples |
|---|---|---|
| Statically linked | no runtime linking at all | `ffmpeg`, `ffprobe` |
| Official distro-neutral tarball | upstream builds against an old glibc | Go, Haxe, Neko, the Playwright/Puppeteer browsers |
| Built *inside* a Debian 12 container | linked against the image's own libraries | HashLink, the Go dev tools |
| Host rustup | rustup's toolchains are already distro-neutral | `rustc`, `cargo`, clippy, rustfmt |

**What's in it.**

| Path (host) | Mounted at | Holds |
|---|---|---|
| `~/opt/docker-claude/bin` | `/opt/dc/bin` | stable names: `ffmpeg`, `ffprobe`, `chromium`, `chrome`, `chromedriver`, `firefox` |
| `~/opt/docker-claude/ffmpeg` | `/opt/dc/ffmpeg` | static ffmpeg 7.x |
| `~/opt/docker-claude/browsers` | `/opt/dc/browsers` | Playwright's Chromium + Firefox, Puppeteer's Chrome + chromedriver |
| `~/opt/docker-claude/node` | `/opt/dc/node` | `playwright`, `@playwright/test`, `puppeteer` |
| `~/opt/docker-claude/python` | `/opt/dc/python` | `playwright`, `selenium`, `pytest`, `ruff` (cp311, matching the image's python3) |
| `~/opt/docker-claude/go`, `gotools` | `/opt/dc/go`, `/opt/dc/gotools` | Go toolchain; golangci-lint, staticcheck, goimports, dlv, gotestsum |
| `~/opt/docker-claude/haxe`, `neko`, `hashlink` | `/opt/dc/…` | Haxe, Neko, a HashLink build with its hdlls |
| `~/opt/docker-claude/haxelib` | `/opt/dc/haxelib` | the HaxeFlixel and Heaps stacks — **read-write**, so `haxelib install` works |
| `~/opt/docker-claude/innoextract` | `/opt/dc/innoextract` | `innoextract` (git master, static) for Inno Setup installers |
| `~/opt/docker-claude/sevenzip` | `/opt/dc/sevenzip` | 7-Zip 26.03 — `7z`/`7zz` for zip, 7z, cab, msi, NSIS |
| `~/.rustup`, `~/.cargo/bin` | `/opt/rustup`, `/opt/cargo-bin` | your host Rust, used directly |

The tree is mounted as a **single read-only mount**, with `haxelib` layered back over it read-write. That is deliberate: `bin/` holds relative symlinks into version-bearing directories (`browsers/chromium-1234/…`), which only resolve if the whole tree arrives at one path. The runtime sorts bind mounts by target depth, so `/opt/dc` lands before `/opt/dc/haxelib`.

**The image's half of the bargain.** A mounted Chromium or HashLink is still a dynamically linked ELF, so Debian has to supply the `.so` files it was linked against — that part cannot be mounted and lives in two `apt-get` layers in the Containerfile. The browser half of that list is not hand-maintained: it is Playwright's own `debian12-x64` table for chromium + firefox + tools, and the Containerfile carries the one-liner that regenerates it after a Playwright upgrade.

**Extracting Windows installers.** `innoextract` is built from a pinned git master commit, not the 1.9 release: the release dates from 2020 and stops at Inno Setup 6.0.5, refusing 6.3.x outright. Master reaches **6.3.3**. Inno Setup **6.5+ changed its setup loader and no build of innoextract handles it yet** — those fail with `Unexpected setup loader revision: 2`, and there is currently no Linux-native tool for them. `7z` is not a fallback for that: on an Inno installer it only reports the PE wrapper. The 1.9 binary stays available as `innoextract-1.9` for comparing behaviour on a file that misbehaves.

**Version pins** all live at the top of `shared-tree.sh`. Bump one and re-run; each section replaces only its own directory. After a Playwright upgrade, also regenerate the Containerfile's browser dependency list and rebuild, or the new browser build may want an `.so` the image lacks.

**Adding to it.** Put the toolchain under `~/opt/docker-claude/<name>` (a tarball, or built in a `debian:12-slim` container if it links against anything), add a line to `~/.config/docker-claude/container-env` for its `bin` and variables, and — if it is dynamically linked — add its runtime libraries to the Containerfile's native apt layer. No `container-mounts` change is needed: the whole tree is already mounted.


## Updating

All three CLIs are baked into the image, pinned via build args in the `Containerfile`
(`CLAUDE_CODE_VERSION`, `CODEX_VERSION` and `OPENCODE_VERSION`). One command updates everything:

```
cclaude --update   # rebuild with the latest Claude Code
ccodex --update    # rebuild with the latest Codex CLI
copencode --update # rebuild with the latest opencode
```

`--update` does two things before rebuilding, and the first one is easy to miss:

1. **Fast-forwards the launcher's own checkout** — the directory the run script
   lives in, which is also the build context. Under the installer that is
   `~/.local/share/docker-claude` (`%LOCALAPPDATA%\docker-claude` on Windows),
   *not* any clone you happen to be editing elsewhere. This is what carries
   changes to the `Containerfile` and `entrypoint.sh` — new tools, bumped
   versions, environment fixes — into the image.
2. **Fetches the latest release of that agent** and pins it into the build.

Then it rebuilds and launches as usual. (The `--update` flag is consumed by the
launcher; all other arguments are passed through to the agent. Because all the
agents live in one image, any `--update` rebuilds the whole thing.)

Only the flagged agent's version is bumped, though: `cclaude --update` moves
`CLAUDE_CODE_VERSION` to the latest release and leaves the others at whatever the
`Containerfile` pins, and likewise for `ccodex --update` and
`copencode --update`. Run each to move each.

If the build fails, the launcher stops there rather than starting the image that
is still tagged. A failed rebuild would otherwise hand you the *previous* image
with the build error already scrolled off screen — an agent missing the tool you
just added, and nothing on screen connecting the two.

The checkout is only ever *fast-forwarded*, and only when it is clean and tracks
an upstream branch — a working clone with local commits or uncommitted edits is
built as it stands, never rewound. Whichever happens is printed at launch, so
"did not update" is never silent.

To pin a specific version instead, bump the relevant build arg in the
`Containerfile`, then force a rebuild:

```
docker rmi claude-code
cclaude  # rebuilds automatically
```

That pair is also the escape hatch when you are developing against a checkout
`--update` won't touch: the launchers otherwise build only when the image is
missing, so an existing `claude-code` image keeps being reused, however old it
is. If a tool this README documents appears to be missing inside the container,
an image predating it is the first thing to check:
`docker image inspect claude-code --format '{{.Created}}'`.

## Security model

The container significantly reduces the blast radius of running these agents with their approval gates off, but it is not a perfect sandbox. Understand what is and isn't protected:

### What's protected

- **Host filesystem** — only your project directory is mounted; the rest of your filesystem is inaccessible
- **Privilege escalation** — the agent runs as the unprivileged `claude` user, never root: the entrypoint does its root-only setup (volume ownership, credential permissions) and then `exec`s the agent through `gosu`, so no root process remains. The root account is locked and setuid/setgid bits are stripped from every binary but `gosu` itself. Under Docker every capability is dropped (`--cap-drop=ALL`) and only the five that root stage needs are added back — `CHOWN`, `FOWNER` and `DAC_OVERRIDE` for the volume ownership pass, `SETUID` and `SETGID` for the `gosu` drop itself — together with `--security-opt=no-new-privileges`, which stops `execve` from ever *granting* privilege (setuid bits, file capabilities) and so sits happily alongside those five: `gosu` uses a capability the process already holds rather than gaining one. All three run scripts pass the same set. Under Podman the container is run with `--userns=keep-id` instead
- **Host processes** — the container has no visibility into host processes
- **Docker socket** — not mounted, so the container cannot spawn sibling containers

### What a rogue agent could do

- **Modify or delete your project files** — the project directory is mounted read-write, so anything in the directory you launch from is fully accessible
- **Read your SSH keys and Git config** — these are mounted read-only, but a rogue agent could still read them and exfiltrate them over the network
- **Read your GitHub CLI tokens** — the `gh` config directory is mounted read-only for the same reason
- **Reach whatever `.container-mounts` grants** — a repo can ship that file, and it can name any host directory, including a sensitive one. The launcher prints each mount in the banner and refuses targets that would shadow the home volume or workspace, but it does not judge the host side; read the file before launching on untrusted code, or use `--no-mounts`
- **Set environment through `.container-env`** — the repo-local file can put a directory first on `PATH` or point a tool at a config of the repo's choosing. Values only reach the container (never the host), the launcher's own variables are refused, and every one is printed in the banner; the same `--no-mounts` skips it
- **Read your opencode config and its keys (`copencode` only)** — the copy includes any key file the config references
- **Make network requests** — outbound network access is required for the Claude API but also means the container can reach arbitrary endpoints
- **Read and write your clipboard (Linux/Wayland)** — the Wayland socket is mounted for image paste, which also allows clipboard access and opening windows. Wayland's client isolation prevents input snooping; for this reason the X11 socket (which would allow keylogging) is never mounted. Remove the `WAYLAND_DISPLAY` block in `linux/run.sh` to opt out

### Hardening tips

- **Mount the project read-only** for review-only sessions: change the project mount in your run script to `"$(pwd):$WORKSPACE_PATH:ro"`
- **Ignore the project's mounts and env** on code you haven't read yet: `cclaude --no-mounts` skips every container-mounts and container-env file. The banner shows whether each is on, off, or none.
- **Withhold git access** if you don't need private repo access: launch with `--no-git` (e.g. `cclaude --no-git`, or the equivalent `GIT_ACCESS=0 cclaude`). No gitconfig, SSH keys, or gh token are shared, and any cached in the volume from a prior run are scrubbed. The launch banner shows whether git access is on or off.
- **Commit before launching** so you can easily revert any unwanted changes with `git checkout .`

## Migrating from native Claude Code

Switching to the containerized approach starts with a fresh `~/.claude` inside the named volume. **Your existing project memories (`MEMORY.md` files) will not carry over automatically.**

Your host memories are stored in `~/.claude/projects/` with paths like `-Users-you-projects-myapp/memory/MEMORY.md`. The container uses a different path scheme based on the mount point: `-workspace-myapp/memory/MEMORY.md`.

To preserve your memories, copy them from your host's `~/.claude/projects/` into the `claude-home` Docker volume, renaming the project directories to match the container's `-workspace-<project>` format. The `<project>` portion is the basename of the directory you run the script from.
