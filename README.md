# Containerized Claude Code

Run [Claude Code](https://claude.ai) in a container with `--dangerously-skip-permissions` safely isolated from your host system.

## Why

Running Claude Code with `--dangerously-skip-permissions` gives the AI agent full autonomy but also full access to your system. A container restricts it to only the mounted project directory — Claude can't touch anything else on your host.

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

## Setup

```bash
git clone https://github.com/Tanz0rz/Podman-Claude.git
cd Podman-Claude
chmod +x run.sh
```

## Usage

From any project directory:

```bash
~/path/to/Podman-Claude/run.sh
```

On first run, the script will:
1. Build the container image (takes a few minutes)
2. Create a persistent `claude-home` volume
3. Launch Claude Code

**You must run `/login` inside the container on first launch.** Auth persists in the named volume across all future sessions.

### Pass arguments to Claude

```bash
./run.sh -p "fix the failing tests"
./run.sh --resume
```

### Alias (optional)

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
alias cclaude="$HOME/path/to/Podman-Claude/run.sh"
```

Then use `cclaude` from any project directory.

## How it works

- **Containerfile** — Debian-based image with Node.js 22, Claude Code native binary, and common dev tools (git, curl, jq, python3, build-essential)
- **run.sh** — Builds the image, creates a persistent volume, and runs the container with your project mounted at `/workspace`. Auto-detects Docker or Podman.
- **Named volume** (`claude-home`) — Persists `/home/claude` across runs, including auth tokens, settings, memory, and history
- **Project mount** — `$(pwd)` is bind-mounted to `/workspace` so Claude can read and edit your code

## What's isolated

| | Host | Container |
|---|---|---|
| Filesystem | Protected | Only `/workspace` (your project) is mounted |
| Processes | Protected | No access to host processes |
| Network | Protected | Outbound web access only (bridge mode) |
| Privilege escalation | Protected | Capabilities dropped, no-new-privileges |

## What's shared

- **Git config** — `~/.gitconfig` mounted read-only so commits use your identity
- **SSH keys** — `~/.ssh` mounted read-only for private repo access
- **Project directory** — Read-write mount of your current directory

## Managing dependencies

The container comes with common dev tools (git, curl, jq, python3, build-essential). When Claude needs something else, there are three approaches:

### 1. Add to the Containerfile (permanent)

For tools you always need, add them to the `apt-get install` line in the Containerfile and rebuild:

```bash
docker rmi claude-code
cclaude  # rebuilds with new packages
```

### 2. Let Claude install at runtime (per-session)

Claude has passwordless sudo inside the container, so it can `sudo apt-get install -y <package>` during a session. These installs are lost when the session ends (`--rm` flag), so this is best for one-off experiments.

### 3. Install to the named volume (persistent, no rebuild)

Tools installed to `/home/claude` (the named volume) persist across sessions. For example, Claude could install Go without a rebuild:

```bash
curl -fsSL https://go.dev/dl/go1.24.1.linux-arm64.tar.gz | tar -C ~/.local -xz
echo 'export PATH=$HOME/.local/go/bin:$PATH' >> ~/.bashrc
```

This works for any tool that supports user-level installation (pip, cargo, npm globals, language version managers, etc.).

> **Note:** sudo inside the container is safe — `--cap-drop=ALL` and `--security-opt=no-new-privileges` prevent privilege escalation beyond the container.

## Updating Claude Code

The Claude Code binary is baked into the image. To update:

```bash
docker rmi claude-code
cclaude  # rebuilds automatically
```

## Docker vs Podman

The run script auto-detects the runtime, preferring Docker. Both work, with trade-offs:

| | Docker | Podman |
|---|---|---|
| macOS stability | Reliable | VM socket freezes (auto-recovered by script) |
| Daemon | `dockerd` runs as root | Daemonless |
| Rootless | Requires extra setup | Default |
| Security hardening | `--cap-drop=ALL --security-opt=no-new-privileges` | `--userns=keep-id` |
