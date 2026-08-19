# Containerized Claude Code & Codex

Run [Claude Code](https://claude.ai) and the [OpenAI Codex CLI](https://github.com/openai/codex) in a container with their sandbox/approval gates disabled, safely isolated from your host system.

The image bundles **both** agents. Launch Claude Code with `cclaude` and Codex with `ccodex` — same container, same isolation, same persistent home.

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

This fetches the repo to a fixed location and installs the `cclaude` (Claude Code) and `ccodex` (Codex CLI) launchers. It does **not** modify your shell config — it prints the one line to add to your PATH so you can decide. (Pass `--modify-path`, or set `DOCKER_CLAUDE_MODIFY_PATH=1`, to have it edit your rc for you.) Once on PATH, from any project directory:

```bash
cclaude        # launch Claude Code
ccodex         # launch the Codex CLI
```

The first launch builds the image and prompts you to `/login`. Re-run the installer any time to update the launchers; use `cclaude --update` / `ccodex --update` to update the agents themselves.

### Prerequisites per OS

Docker or Podman must be installed before running the installer — see your OS guide (each also documents a manual clone-and-alias setup if you'd rather not use the installer):

| OS | Guide | Prerequisite |
|---|---|---|
| [macOS](macos/README.md) | [macos/README.md](macos/README.md) | Docker Desktop or Podman |
| [Linux](linux/README.md) | [linux/README.md](linux/README.md) | Docker or Podman |
| [Windows](windows/README.md) | [windows/README.md](windows/README.md) | Docker Desktop + WSL 2 |

## How it works

- **Containerfile** — Debian-based image with Node.js 22, the Claude Code CLI, the OpenAI Codex CLI, gh CLI, common dev tools (git, curl, jq, python3, build-essential), the [Go](https://go.dev) toolchain with its usual companions (golangci-lint, staticcheck, goimports, Delve, gotestsum), [Ruff](https://docs.astral.sh/ruff/), and [pytest](https://docs.pytest.org) (see [Go, Ruff & pytest](#go-ruff--pytest)), and the [Haxe](https://haxe.org) toolchain with the [HaxeFlixel](https://haxeflixel.com) game framework (see [Haxe & HaxeFlixel](#haxe--haxeflixel))
- **run.sh / run.bat** — Builds the image, creates a persistent volume, and runs the container with your project mounted at `/workspace`. Each OS directory has its own run script. The `AGENT` env var (set by the `ccodex` launcher) selects which agent runs; it defaults to `claude`.
- **Named volume** (`claude-home`) — Persists `/home/claude` across runs, including both agents' auth tokens, settings, memory, and history, plus the caches the toolchains write there (Go's module and build cache, npm's cache). Because it outlives any single image, the entrypoint repairs its ownership on every start — see [Home volume permissions](#home-volume-permissions)
- **Project mount** — Your current directory is bind-mounted to `/workspace/<project>` so the agent can read and edit your code

### Launch options

A launch is controlled by a few launcher options and two environment variables.
Run `cclaude --help` (or `ccodex --help`) to see them; the run script also prints
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
| `--update` | Rebuild the image with the latest release of the agent before launching. |
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
| `AGENT` | `claude` | Which agent to run: `claude` or `codex`. The `ccodex` launcher just sets `AGENT=codex`. |
| `GIT_ACCESS` | `1` | Whether the host's git identity and credentials (gitconfig, SSH keys, gh token/config) are shared. Set `0`/`false`/`no`/`off` to withhold them — and scrub any left in the volume by a prior run. A `--git`/`--no-git` option overrides this. |

## What's isolated

| | Host | Container |
|---|---|---|
| Filesystem | Protected | Only `/workspace` (your project) is mounted |
| Processes | Protected | No access to host processes |
| Network | Protected | Outbound web access only (bridge mode) |
| Privilege escalation | Protected | Runs as the unprivileged `claude` user; capabilities dropped bar the five the entrypoint's root stage needs, plus no-new-privileges |

## What's shared

- **Git config** — Copied from host at startup so commits use your identity (unless `GIT_ACCESS=0`)
- **SSH keys** — Copied from host at startup for private repo access (unless `GIT_ACCESS=0`)
- **Auth** — The host's `~/.claude` and `~/.codex` are shared so logins and token refreshes persist in both directions (host and container). `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are forwarded when set. (Agent auth is always shared — it is not affected by `GIT_ACCESS`.)
- **Project directory** — Read-write mount of your current directory
- **Clipboard (Linux/Wayland only)** — The Wayland compositor socket is mounted so image paste (ctrl+v) works in the TUI

## Go, Ruff & pytest

- **Go 1.26.6** — installed at `/opt/go` and on `PATH`, with everything the toolchain ships: `go build`, `go test`, `go vet`, `gofmt`
- **Go dev tooling** — installed at `/opt/gotools/bin` and on `PATH`:
  - `golangci-lint` 2.12.2 — the meta-linter (govet, staticcheck, errcheck, ineffassign, unused, … in one pass, honouring a project's `.golangci.yml`)
  - `staticcheck` 0.7.0 — the same analyzers standalone, for `staticcheck ./...`
  - `goimports` 0.49.0 — `gofmt` plus automatic import add/remove/grouping
  - `dlv` 1.27.1 — the Delve debugger
  - `gotestsum` 1.13.0 — `go test` with readable output and JUnit/JSON reports
- **Ruff 0.16.3** — the Python linter/formatter, installed at `/opt/ruff` and linked into `/usr/local/bin/ruff`
- **pytest 9.1.1** — the Python test runner, installed in its own virtualenv at `/opt/pytest` and linked into `/usr/local/bin/pytest`

All of them are pinned via build args (`GO_VERSION`, `GOLANGCI_LINT_VERSION`, `STATICCHECK_VERSION`, `GOIMPORTS_VERSION`, `DELVE_VERSION`, `GOTESTSUM_VERSION`, `RUFF_VERSION`, `PYTEST_VERSION`); bump them and rebuild (`docker rmi claude-code && cclaude`) to upgrade. They live in `/opt` rather than the home directory so the persistent `claude-home` volume can't mask or freeze them — the same reasoning as the agents themselves.

Go's writable state is pinned explicitly rather than left to the defaults, so nothing depends on `$HOME`/`$XDG_CACHE_HOME` being what Go expects:

| Variable | Value | Why |
| --- | --- | --- |
| `GOPATH` | `/home/claude/go` | On the persistent volume, so `go install`ed tools survive |
| `GOMODCACHE` | `/home/claude/go/pkg/mod` | Downloaded modules survive across sessions |
| `GOCACHE` | `/home/claude/.cache/go-build` | Build cache survives, so repeat builds are warm |
| `GOTOOLCHAIN` | `local` | `go` always means the `/opt/go` install |

`$GOPATH/bin` (`~/go/bin`) is on `PATH`, so anything installed at runtime with `go install` is runnable straight away. The entrypoint creates these directories and fixes their ownership on every start — see [Home volume permissions](#home-volume-permissions) for why that matters.

`GOTOOLCHAIN=local` also means a stale `golang.org/toolchain@*` tree in the module cache (left by a session that ran before this pin existed) is ignored rather than silently preferred over the image's Go. If a project's `go.mod` requires a newer Go than the image ships, bump `GO_VERSION` and rebuild rather than unsetting the pin.

The Go language server, `gopls`, is deliberately *not* in the image — nothing in the container speaks LSP and it is a large binary. If you want it, `go install golang.org/x/tools/gopls@latest` puts it in `~/go/bin`, which is on `PATH` and on the persistent volume, so it survives across sessions.

The bundled `pytest` runs out of its own virtualenv, so it can import the standard library and the code under test, but not third-party packages. A project whose tests need extra dependencies should make a local venv instead (`python3 -m venv .venv && .venv/bin/pip install pytest <deps>`) — `python3-venv` is in the image for exactly that.

## Home volume permissions

The `claude-home` volume outlives any single image, so it accumulates files owned by whoever wrote them — root (when the container runtime creates a mount point) or a stranger UID (from an image built when the container user was not 1000). Those directories are unwritable for the `claude` user, and the failure surfaces nowhere near the cause:

```
go: mkdir /home/claude/.cache/go-build: permission denied
```

with `~/.cache` owned by a UID that no longer exists in the image. The entrypoint therefore repairs ownership of the whole home tree on every start (`chown` to 1000:1000 for anything that isn't already), skipping the host bind mounts `~/.claude`, `~/.codex` and `~/.config/gh`, which belong to the host user. Nothing needs to be done by hand; an old volume is fixed by the next launch. The same pass also drops a `~/.haxelib` left pointing at a repository directory that no longer exists.

This runs in the entrypoint's root stage, before `gosu` drops to the `claude` user, so the container has to hold `CAP_CHOWN` (and `CAP_SETUID`/`CAP_SETGID` for the drop itself). All three run scripts grant exactly those under Docker and use `--userns=keep-id` under Podman — see [Security model](#whats-protected). If you have customized the flags and stripped them, the repair is skipped, and the manual equivalent is:

```
docker run --rm -u 0 --entrypoint chown -v claude-home:/home/claude \
  claude-code -R 1000:1000 /home/claude
```

## Haxe & HaxeFlixel

The image ships the [Haxe](https://haxe.org) toolchain and the [HaxeFlixel](https://haxeflixel.com) game framework so agents can build and run 2D games out of the box:

- **Haxe 4.3.7** and **Neko 2.4.1** — installed under `/opt/haxe` and `/opt/neko` and on `PATH` (`haxe`, `haxelib`, `neko`)
- **HaxeFlixel stack** — `lime`, `openfl`, `flixel`, `flixel-addons`, `flixel-ui`, `flixel-tools`, and `hxcpp` for native C++ builds, plus a `lime` command
- **Native runtime** — SDL2, OpenGL (Mesa), vorbis/ogg, and mbedtls are already in the image, and `xvfb` is included so a game can run headless (`xvfb-run lime test linux`)

The Haxe and Neko versions are pinned via the `HAXE_VERSION` / `NEKO_VERSION` build args (bump them and rebuild to upgrade). The haxelib repository lives at `/opt/haxelib` and is read-only so the image stays reproducible — to add or update libraries for a specific project, run `haxelib newrepo` in that project first to create a local, writable `.haxelib`.

```bash
lime create flixel:FlxTemplate MyGame   # scaffold a new game
cd MyGame
lime test neko                          # build & run (or 'linux' for native, under xvfb-run)
```

## Managing dependencies

> The `cclaude` and `ccodex` commands are the launchers installed by the [one-line installer](#quick-start) (or set up manually per the OS guide). Both wrap this repo's `run.sh` / `run.bat`, with `ccodex` setting `AGENT=codex`.

The container comes with common dev tools (git, curl, jq, python3, build-essential, Go + linters, Ruff, pytest, Haxe). When Claude needs something else, there are two approaches:

### 1. Add to the Containerfile (permanent)

For tools you always need, add them to the `apt-get install` line in the Containerfile and rebuild:

```
docker rmi claude-code
cclaude  # rebuilds with new packages
```

### 2. Install to the named volume (persistent, no rebuild)

Tools installed to `/home/claude` (the named volume) persist across sessions. For example, Claude could install Rust without a rebuild:

```bash
curl -fsSL https://sh.rustup.rs | sh -s -- -y   # installs into ~/.cargo, on the volume
```

This works for any tool that supports user-level installation (pip, cargo, npm globals, language version managers, etc.).

The conventional user-level bin directories are already on `PATH`, so a tool installed this way is runnable immediately:

| Directory | Filled by |
| --- | --- |
| `~/.local/bin` | `pip install --user`, `pipx`, most `install.sh` scripts |
| `~/.cargo/bin` | `rustup` / `cargo install` |
| `~/go/bin` | `go install` (it is `$GOPATH/bin`) |

This matters because the agent is `exec`'d directly rather than through a login shell: the `source ~/.profile` line installers like rustup append to your shell config is never read, so without those entries the binaries would be invisible despite installing fine. They are appended *after* the image's own directories, so an image-owned tool always wins over a stale copy in the volume.

## Updating the agents

Both CLIs are baked into the image, pinned via build args in the `Containerfile`
(`CLAUDE_CODE_VERSION` and `CODEX_VERSION`). The easiest way to update is:

```
cclaude --update   # rebuild with the latest Claude Code
ccodex --update    # rebuild with the latest Codex CLI
```

Each fetches the latest release of that agent, rebuilds the shared image with
it, and then launches as usual. (The `--update` flag is consumed by the
launcher; all other arguments are passed through to the agent. Because both
agents live in one image, either `--update` rebuilds the whole thing.)

To pin a specific version instead, bump the relevant build arg in the
`Containerfile`, then force a rebuild:

```
docker rmi claude-code
cclaude  # rebuilds automatically
```

The same two commands are how any *other* change to the `Containerfile` or
`entrypoint.sh` reaches a running setup — a new tool, a bumped `GO_VERSION`, a
fix to the environment. The launchers only build when the image is missing, so
an existing `claude-code` image keeps being reused, however old it is, until you
remove it or pass `--update`. If a tool this README documents appears to be
missing inside the container, an image predating it is the first thing to check:
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
- **Make network requests** — outbound network access is required for the Claude API but also means the container can reach arbitrary endpoints
- **Read and write your clipboard (Linux/Wayland)** — the Wayland socket is mounted for image paste, which also allows clipboard access and opening windows. Wayland's client isolation prevents input snooping; for this reason the X11 socket (which would allow keylogging) is never mounted. Remove the `WAYLAND_DISPLAY` block in `linux/run.sh` to opt out

### Hardening tips

- **Mount the project read-only** for review-only sessions: change the project mount in your run script to `"$(pwd):$WORKSPACE_PATH:ro"`
- **Withhold git access** if you don't need private repo access: launch with `--no-git` (e.g. `cclaude --no-git`, or the equivalent `GIT_ACCESS=0 cclaude`). No gitconfig, SSH keys, or gh token are shared, and any cached in the volume from a prior run are scrubbed. The launch banner shows whether git access is on or off.
- **Commit before launching** so you can easily revert any unwanted changes with `git checkout .`

## Migrating from native Claude Code

Switching to the containerized approach starts with a fresh `~/.claude` inside the named volume. **Your existing project memories (`MEMORY.md` files) will not carry over automatically.**

Your host memories are stored in `~/.claude/projects/` with paths like `-Users-you-projects-myapp/memory/MEMORY.md`. The container uses a different path scheme based on the mount point: `-workspace-myapp/memory/MEMORY.md`.

To preserve your memories, copy them from your host's `~/.claude/projects/` into the `claude-home` Docker volume, renaming the project directories to match the container's `-workspace-<project>` format. The `<project>` portion is the basename of the directory you run the script from.
