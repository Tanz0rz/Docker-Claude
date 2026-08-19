# Linux Setup

## Prerequisites

Install Docker or Podman using your distro's package manager.

**Docker (Debian/Ubuntu):**
```bash
sudo apt-get update
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
```

Log out and back in for the group change to take effect, then verify:

```bash
docker run hello-world
```

**Docker (Fedora/RHEL):**
```bash
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

**Podman (any distro):**
```bash
# Debian/Ubuntu
sudo apt-get install -y podman

# Fedora/RHEL
sudo dnf install -y podman
```

Podman runs natively on Linux (no VM) and is rootless by default.

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
chmod +x linux/run.sh

# in ~/.bashrc
alias cclaude="$HOME/path/to/Docker-Claude/linux/run.sh"
alias ccodex="AGENT=codex $HOME/path/to/Docker-Claude/linux/run.sh"
```

## Docker vs Podman

The run script auto-detects the runtime, preferring Docker.

| | Docker | Podman |
|---|---|---|
| Linux stability | Reliable | Reliable (native, no VM) |
| Daemon | `dockerd` runs as root | Daemonless |
| Rootless | Requires `usermod -aG docker` | Default |
| Security hardening | `--cap-drop=ALL --security-opt=no-new-privileges`, plus the five capabilities the entrypoint's root stage needs (`CHOWN`, `FOWNER`, `SETUID`, `SETGID`, `DAC_OVERRIDE`) | `--userns=keep-id` |

Under either runtime the agent itself runs as the unprivileged `claude` user: the
entrypoint does its root-only setup — repairing ownership on the persistent
`claude-home` volume, fixing credential permissions — and then `exec`s the agent
through `gosu`, leaving no root process behind. That root stage is why the Docker
flags drop all capabilities and add back a specific five rather than none at all;
see [Home volume permissions](../README.md#home-volume-permissions) for what the
ownership pass fixes and why it exists.
