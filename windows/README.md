# Windows Setup

## Prerequisites

Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) with the WSL 2 backend (the default).

If WSL 2 isn't already enabled, open CMD as Administrator:

```cmd
wsl --install
```

Reboot if prompted, then install Docker Desktop. No additional configuration is needed — `run.bat` uses Docker from a normal CMD or PowerShell prompt.

## Setup

```cmd
git clone https://github.com/Tanz0rz/Docker-Claude.git
cd Docker-Claude
```

No extra permissions step is needed on Windows.

## Usage

From any project directory:

```cmd
C:\path\to\Docker-Claude\windows\run.bat
```

On first run, the script will:
1. Build the container image (takes a few minutes)
2. Create a persistent `claude-home` volume
3. Launch Claude Code

**You must run `/login` inside the container on first launch.** Auth persists in the named volume across all future sessions.

### Pass arguments to Claude

```cmd
C:\path\to\Docker-Claude\windows\run.bat -p "fix the failing tests"
C:\path\to\Docker-Claude\windows\run.bat --resume
```

### Adding `cclaude` and `ccodex` to PATH (recommended)

Add the `Docker-Claude\windows` directory to your user PATH so you can run both
launchers from anywhere. `cclaude.cmd` starts Claude Code; `ccodex.cmd` starts
the OpenAI Codex CLI (same image, same persistent volume — it just sets
`AGENT=codex`).

**PowerShell (one-time):**
```powershell
$cur = [Environment]::GetEnvironmentVariable('Path', 'User')
$dir = 'C:\path\to\Docker-Claude\windows'
[Environment]::SetEnvironmentVariable('Path', "$cur;$dir", 'User')
```

Restart your terminal, then use from any project directory:

```cmd
cclaude
cclaude -p "fix the failing tests"
ccodex
ccodex --resume
```
