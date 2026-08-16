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

- **Containerfile** — Debian-based image with Node.js 22, the Claude Code CLI, the OpenAI Codex CLI, gh CLI, common dev tools (git, curl, jq, python3, build-essential), and the [Haxe](https://haxe.org) toolchain with the [HaxeFlixel](https://haxeflixel.com) game framework (see [Haxe & HaxeFlixel](#haxe--haxeflixel))
- **run.sh / run.bat** — Builds the image, creates a persistent volume, and runs the container with your project mounted at `/workspace`. Each OS directory has its own run script. The `AGENT` env var (set by the `ccodex` launcher) selects which agent runs; it defaults to `claude`.
- **Named volume** (`claude-home`) — Persists `/home/claude` across runs, including both agents' auth tokens, settings, memory, and history
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
| Privilege escalation | Protected | Capabilities dropped, no-new-privileges |

## What's shared

- **Git config** — Copied from host at startup so commits use your identity (unless `GIT_ACCESS=0`)
- **SSH keys** — Copied from host at startup for private repo access (unless `GIT_ACCESS=0`)
- **Auth** — The host's `~/.claude` and `~/.codex` are shared so logins and token refreshes persist in both directions (host and container). `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are forwarded when set. (Agent auth is always shared — it is not affected by `GIT_ACCESS`.)
- **Project directory** — Read-write mount of your current directory
- **Clipboard (Linux/Wayland only)** — The Wayland compositor socket is mounted so image paste (ctrl+v) works in the TUI

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

The container comes with common dev tools (git, curl, jq, python3, build-essential). When Claude needs something else, there are two approaches:

### 1. Add to the Containerfile (permanent)

For tools you always need, add them to the `apt-get install` line in the Containerfile and rebuild:

```
docker rmi claude-code
cclaude  # rebuilds with new packages
```

### 2. Install to the named volume (persistent, no rebuild)

Tools installed to `/home/claude` (the named volume) persist across sessions. For example, Claude could install Go without a rebuild:

```bash
curl -fsSL https://go.dev/dl/go1.24.1.linux-arm64.tar.gz | tar -C ~/.local -xz
echo 'export PATH=$HOME/.local/go/bin:$PATH' >> ~/.bashrc
```

This works for any tool that supports user-level installation (pip, cargo, npm globals, language version managers, etc.).

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

## Security model

The container significantly reduces the blast radius of running these agents with their approval gates off, but it is not a perfect sandbox. Understand what is and isn't protected:

### What's protected

- **Host filesystem** — only your project directory is mounted; the rest of your filesystem is inaccessible
- **Privilege escalation** — all Linux capabilities are dropped (`--cap-drop=ALL`, `--security-opt=no-new-privileges`)
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
