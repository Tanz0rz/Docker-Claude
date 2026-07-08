@echo off
setlocal enabledelayedexpansion

set IMAGE_NAME=claude-code
set VOLUME_NAME=claude-home
set SCRIPT_DIR=%~dp0..

REM --update rebuilds the image with the latest Claude Code release before launching
set RUN_ARGS=%*
set FORCE_UPDATE=
if not "%RUN_ARGS%"=="%RUN_ARGS:--update=%" (
    set FORCE_UPDATE=1
    set RUN_ARGS=%RUN_ARGS:--update=%
)

REM Prefer docker, fall back to podman
set RUNTIME=
where docker >nul 2>nul && set RUNTIME=docker
if not defined RUNTIME (
    where podman >nul 2>nul && set RUNTIME=podman
)
if not defined RUNTIME (
    echo Error: neither docker nor podman found >&2
    exit /b 1
)
echo Using container runtime: %RUNTIME%

REM Check that the daemon is actually reachable
%RUNTIME% info >nul 2>nul || (
    echo Error: %RUNTIME% was found but the daemon is not running. >&2
    echo Please start Docker Desktop and try again. >&2
    exit /b 1
)

REM --update: fetch the latest release and rebuild (the changed build-arg busts the layer cache)
if defined FORCE_UPDATE (
    echo Fetching latest Claude Code version...
    set LATEST_VERSION=
    for /f "delims=" %%V in ('curl -fsSL https://downloads.claude.ai/claude-code-releases/latest') do set LATEST_VERSION=%%V
    if not defined LATEST_VERSION (
        echo Error: could not fetch the latest Claude Code version. >&2
        exit /b 1
    )
    echo Rebuilding image with Claude Code !LATEST_VERSION!...
    %RUNTIME% build --pull --build-arg CLAUDE_CODE_VERSION=!LATEST_VERSION! -t %IMAGE_NAME% -f "%SCRIPT_DIR%\Containerfile" "%SCRIPT_DIR%"
)

REM Build if image doesn't exist
%RUNTIME% image inspect %IMAGE_NAME% >nul 2>nul || (
    echo Building image...
    %RUNTIME% build -t %IMAGE_NAME% -f "%SCRIPT_DIR%\Containerfile" "%SCRIPT_DIR%"
)

REM Create persistent volume if it doesn't exist
%RUNTIME% volume inspect %VOLUME_NAME% >nul 2>nul || (
    echo Creating persistent volume '%VOLUME_NAME%'...
    echo You will need to run '/login' on first launch to authenticate.
    %RUNTIME% volume create %VOLUME_NAME%
)

REM Derive workspace path from current directory name
for %%I in ("%cd%") do set PROJECT_NAME=%%~nxI
set WORKSPACE_PATH=/workspace/%PROJECT_NAME%

REM Mount host config to staging paths (entrypoint copies with correct permissions)
set HOST_MOUNTS=
if exist "%USERPROFILE%\.gitconfig" set HOST_MOUNTS=-v %USERPROFILE%\.gitconfig:/tmp/.host-gitconfig:ro
if exist "%USERPROFILE%\.ssh" set HOST_MOUNTS=!HOST_MOUNTS! -v %USERPROFILE%\.ssh:/tmp/.host-ssh:ro
if exist "%APPDATA%\GitHub CLI" set HOST_MOUNTS=!HOST_MOUNTS! -v "%APPDATA%\GitHub CLI:/home/claude/.config/gh:ro"

REM Ensure credentials file exists for the shared read-write mount
if not exist "%USERPROFILE%\.claude" mkdir "%USERPROFILE%\.claude"
if not exist "%USERPROFILE%\.claude\.credentials.json" echo {}> "%USERPROFILE%\.claude\.credentials.json"
set HOST_MOUNTS=!HOST_MOUNTS! -v "%USERPROFILE%\.claude\.credentials.json:/tmp/.host-credentials.json"

REM Runtime-specific flags
if "%RUNTIME%"=="podman" (
    set RUNTIME_FLAGS=--userns=keep-id
) else (
    set RUNTIME_FLAGS=--cap-drop=ALL --security-opt=no-new-privileges
)

echo Tip: run 'cclaude --update' to rebuild this image with the latest Claude Code.

%RUNTIME% run --rm -it --network=bridge -w "%WORKSPACE_PATH%" %RUNTIME_FLAGS% %HOST_MOUNTS% -v %VOLUME_NAME%:/home/claude -v "%cd%:%WORKSPACE_PATH%" %IMAGE_NAME% !RUN_ARGS!
