# macOS Setup

## Prerequisites

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (recommended) or Podman.

**Docker:**
```bash
brew install --cask docker
```

**Podman (alternative):**
```bash
brew install podman
podman machine init --memory 8192
podman machine start
```

> **Note on Podman:** Podman's VM on macOS has known issues with socket freezes, requiring periodic `podman machine stop && podman machine start`. The run script includes an automatic health check for this, but Docker is more reliable on macOS. Podman's default 2GB VM memory is also insufficient — 8GB minimum is required.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Tanz0rz/Docker-Claude/main/install.sh | bash
```

This clones the repo to `~/.local/share/docker-claude` and installs `cclaude`
and `ccodex` launchers in `~/.local/bin`. It won't touch your shell config — it
prints the exact line to add `~/.local/bin` to your PATH so you can add it
yourself. (Prefer it automated? Re-run with `--modify-path`, or set
`DOCKER_CLAUDE_MODIFY_PATH=1`.) Re-run the command any time to update.

## Usage

From any project directory:

```bash
cclaude        # launch Claude Code
ccodex         # launch the OpenAI Codex CLI
```

Both use the same image and persistent volume; `ccodex` just sets `AGENT=codex`
so the run script starts Codex instead.

On first run, the script will:
1. Build the container image (takes a few minutes)
2. Create a persistent `claude-home` volume
3. Launch the agent

**You must run `/login` inside the container on first launch.** Auth persists in the named volume across all future sessions.

### Pass arguments to the agent

```bash
cclaude -p "fix the failing tests"
ccodex --resume
```

### Manual setup (without the installer)

Prefer to wire it up yourself? Clone the repo and point aliases at the run script:

```bash
git clone https://github.com/Tanz0rz/Docker-Claude.git
cd Docker-Claude
chmod +x macos/run.sh

# in ~/.zshrc or ~/.bashrc
alias cclaude="$HOME/path/to/Docker-Claude/macos/run.sh"
alias ccodex="AGENT=codex $HOME/path/to/Docker-Claude/macos/run.sh"
```

## Docker vs Podman

The run script auto-detects the runtime, preferring Docker. Both work, with trade-offs:

| | Docker | Podman |
|---|---|---|
| macOS stability | Reliable | VM socket freezes (auto-recovered by script) |
| Daemon | `dockerd` runs as root | Daemonless |
| Rootless | Requires extra setup | Default |
| Security hardening | `--cap-drop=ALL --security-opt=no-new-privileges`, plus the five capabilities the entrypoint's root stage needs (`CHOWN`, `FOWNER`, `SETUID`, `SETGID`, `DAC_OVERRIDE`) | `--userns=keep-id` |

> The entrypoint has a root-only setup stage — it repairs ownership on the
> persistent `claude-home` volume, then `exec`s the agent as the unprivileged
> `claude` user through `gosu` — so the Docker flags drop all capabilities and
> add back the five that stage needs (`CHOWN`, `FOWNER`, `SETUID`, `SETGID`,
> `DAC_OVERRIDE`). See
> [Home volume permissions](../README.md#home-volume-permissions) in the main
> README.
