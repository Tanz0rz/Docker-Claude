# Docker-Claude installer for Windows.
#
#   irm https://raw.githubusercontent.com/Tanz0rz/Docker-Claude/main/install.ps1 | iex
#
# Fetches the repo to a fixed location and drops cclaude / ccodex launchers onto
# your user PATH, so you can run either agent from any project directory without
# cloning by hand or editing PATH. Re-run any time to update.
$ErrorActionPreference = 'Stop'

$Repo   = if ($env:DOCKER_CLAUDE_REPO)   { $env:DOCKER_CLAUDE_REPO }   else { 'https://github.com/Tanz0rz/Docker-Claude.git' }
$Branch = if ($env:DOCKER_CLAUDE_BRANCH) { $env:DOCKER_CLAUDE_BRANCH } else { 'main' }
$InstallDir = if ($env:DOCKER_CLAUDE_HOME) { $env:DOCKER_CLAUDE_HOME } else { Join-Path $env:LOCALAPPDATA 'docker-claude' }
$BinDir = if ($env:DOCKER_CLAUDE_BIN) { $env:DOCKER_CLAUDE_BIN } else { Join-Path $InstallDir 'bin' }

Write-Host "Installing Docker-Claude..."

# Fetch or update the repo into a fixed, managed location.
if (Test-Path (Join-Path $InstallDir '.git')) {
    Write-Host "  Updating existing install in $InstallDir"
    git -C $InstallDir fetch --quiet origin $Branch
    git -C $InstallDir reset --hard --quiet "origin/$Branch"
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "  Cloning into $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    git clone --quiet --branch $Branch $Repo $InstallDir
} else {
    # No git: fall back to a zip download (GitHub URLs only).
    Write-Host "  git not found - downloading zip into $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $zipUrl = "$($Repo -replace '\.git$','')/archive/refs/heads/$Branch.zip"
    $tmpZip = Join-Path $env:TEMP 'docker-claude.zip'
    $tmpDir = Join-Path $env:TEMP "docker-claude-extract"
    Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $extracted = Get-ChildItem -Directory $tmpDir | Select-Object -First 1
    Copy-Item -Recurse -Force (Join-Path $extracted.FullName '*') $InstallDir
    Remove-Item -Recurse -Force $tmpZip, $tmpDir
}

$RunBat = Join-Path $InstallDir 'windows\run.bat'
if (-not (Test-Path $RunBat)) { throw "run.bat not found at $RunBat" }

# Write the launcher shims. setlocal keeps AGENT scoped to the launch so it
# doesn't leak into the calling shell.
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
"@echo off`r`nsetlocal`r`n`"$RunBat`" %*`r`n" |
    Set-Content -Encoding ASCII (Join-Path $BinDir 'cclaude.cmd')
"@echo off`r`nsetlocal`r`nset AGENT=codex`r`n`"$RunBat`" %*`r`n" |
    Set-Content -Encoding ASCII (Join-Path $BinDir 'ccodex.cmd')
Write-Host "  Installed launchers -> $BinDir\cclaude.cmd, $BinDir\ccodex.cmd"

# PATH handling. By default we never modify your PATH — we just explain how.
# Opt in with DOCKER_CLAUDE_MODIFY_PATH=1 to have the installer set your user PATH.
$ModifyPath = $env:DOCKER_CLAUDE_MODIFY_PATH -eq '1'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($env:Path -split ';') -contains $BinDir -or ($userPath -split ';') -contains $BinDir
$PathCmd = "[Environment]::SetEnvironmentVariable('Path','$BinDir;' + [Environment]::GetEnvironmentVariable('Path','User'),'User')"

$didModify = $false
if (-not $onPath -and $ModifyPath) {
    [Environment]::SetEnvironmentVariable('Path', "$BinDir;$userPath", 'User')
    $env:Path = "$BinDir;$env:Path"
    Write-Host "  Added $BinDir to your user PATH (DOCKER_CLAUDE_MODIFY_PATH=1)"
    $didModify = $true
}

Write-Host ""
Write-Host "Done - cclaude launches Claude Code, ccodex launches the Codex CLI."
Write-Host ""
if ($onPath) {
    Write-Host "You're all set. From any project directory, run:"
    Write-Host "    cclaude"
} elseif ($didModify) {
    Write-Host "$BinDir was added to your user PATH. Open a new terminal, then run:"
    Write-Host "    cclaude"
} else {
    Write-Host "Last step - add the launchers to your PATH ($BinDir isn't on it yet)."
    Write-Host ""
    Write-Host "  Add it permanently (for new terminals) by running:"
    Write-Host "      $PathCmd"
    Write-Host ""
    Write-Host "  (Prefer the installer to do this? Set DOCKER_CLAUDE_MODIFY_PATH=1 and re-run.)"
    Write-Host ""
    Write-Host "Then, from any project directory, run:  cclaude"
}
Write-Host ""
Write-Host "The first launch builds the image and prompts you to /login."
