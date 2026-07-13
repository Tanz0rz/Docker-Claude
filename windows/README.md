# Windows Setup

## Prerequisites

Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) with the WSL 2 backend (the default).

If WSL 2 isn't already enabled, open CMD as Administrator:

```cmd
wsl --install
```

Reboot if prompted, then install Docker Desktop. No additional configuration is needed — `run.bat` uses Docker from a normal CMD or PowerShell prompt.

## Install

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/Tanz0rz/Docker-Claude/main/install.ps1 | iex
```

This clones the repo to `%LOCALAPPDATA%\docker-claude` and installs `cclaude.cmd`
and `ccodex.cmd` launchers under `%LOCALAPPDATA%\docker-claude\bin`. It won't
modify your PATH — it prints the exact command to add that directory to your
user PATH so you can run it yourself. (Prefer it automated? Set
`DOCKER_CLAUDE_MODIFY_PATH=1` before running the installer.) Re-run the command
any time to update.

## Usage

From any project directory (CMD or PowerShell):

```cmd
cclaude        REM launch Claude Code
ccodex         REM launch the OpenAI Codex CLI
```

Both use the same image and persistent volume; `ccodex` just sets `AGENT=codex`
so the run script starts Codex instead.

On first run, the script will:
1. Build the container image (takes a few minutes)
2. Create a persistent `claude-home` volume
3. Launch the agent

**You must run `/login` inside the container on first launch.** Auth persists in the named volume across all future sessions.

### Pass arguments to the agent

```cmd
cclaude -p "fix the failing tests"
ccodex --resume
```

### Manual setup (without the installer)

Prefer to wire it up yourself? Clone the repo and add its `windows` directory to
your user PATH — it already contains `cclaude.cmd` and `ccodex.cmd`:

```powershell
git clone https://github.com/Tanz0rz/Docker-Claude.git
$cur = [Environment]::GetEnvironmentVariable('Path', 'User')
$dir = 'C:\path\to\Docker-Claude\windows'
[Environment]::SetEnvironmentVariable('Path', "$cur;$dir", 'User')
```

Restart your terminal, then run `cclaude` or `ccodex` from any project directory.
