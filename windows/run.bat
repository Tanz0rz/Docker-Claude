@echo off
setlocal enabledelayedexpansion

set IMAGE_NAME=claude-code
set VOLUME_NAME=claude-home
set SCRIPT_DIR=%~dp0..

REM Which agent to launch: "claude" (default) or "codex". Set by ccodex.cmd.
REM The image bundles both CLIs; AGENT only picks which one runs.
if not defined AGENT set AGENT=claude
if /i "%AGENT%"=="claude" (
    set AGENT_LABEL=Claude Code
    set LAUNCHER=cclaude
) else if /i "%AGENT%"=="codex" (
    set AGENT_LABEL=Codex CLI
    set LAUNCHER=ccodex
) else (
    echo Error: unknown AGENT '%AGENT%' ^(expected 'claude' or 'codex'^) >&2
    exit /b 1
)

REM GIT_ACCESS controls whether host git identity/credentials (gitconfig, SSH
REM keys, gh config) are shared with the container. Default on; set GIT_ACCESS=0
REM (or false/no/off) for review-only sessions on untrusted code.
if not defined GIT_ACCESS set GIT_ACCESS=1
set GIT_ACCESS_ON=1
if /i "%GIT_ACCESS%"=="0" set GIT_ACCESS_ON=
if /i "%GIT_ACCESS%"=="false" set GIT_ACCESS_ON=
if /i "%GIT_ACCESS%"=="no" set GIT_ACCESS_ON=
if /i "%GIT_ACCESS%"=="off" set GIT_ACCESS_ON=
if defined GIT_ACCESS_ON (
    set GIT_ACCESS_VALUE=true
    set GIT_STATUS=ON  - gitconfig, SSH keys, gh token shared
) else (
    set GIT_ACCESS_VALUE=false
    set GIT_STATUS=OFF - no git identity or credentials
)

REM --update rebuilds the image with the selected agent's latest release before launching
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
    if /i "%AGENT%"=="codex" (
        echo Fetching latest Codex CLI version...
        set LATEST_VERSION=
        for /f "delims=" %%V in ('powershell -NoProfile -Command "(Invoke-RestMethod https://registry.npmjs.org/@openai/codex/latest).version"') do set LATEST_VERSION=%%V
        if not defined LATEST_VERSION (
            echo Error: could not fetch the latest Codex CLI version. >&2
            exit /b 1
        )
        echo Rebuilding image with Codex CLI !LATEST_VERSION!...
        %RUNTIME% build --pull --build-arg CODEX_VERSION=!LATEST_VERSION! -t %IMAGE_NAME% -f "%SCRIPT_DIR%\Containerfile" "%SCRIPT_DIR%"
    ) else (
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
REM Git identity and credentials — only when GIT_ACCESS is on.
set HOST_MOUNTS=
if defined GIT_ACCESS_ON (
    if exist "%USERPROFILE%\.gitconfig" set HOST_MOUNTS=-v %USERPROFILE%\.gitconfig:/tmp/.host-gitconfig:ro
    if exist "%USERPROFILE%\.ssh" set HOST_MOUNTS=!HOST_MOUNTS! -v %USERPROFILE%\.ssh:/tmp/.host-ssh:ro
    if exist "%APPDATA%\GitHub CLI" set HOST_MOUNTS=!HOST_MOUNTS! -v "%APPDATA%\GitHub CLI:/home/claude/.config/gh:ro"
)

REM Ensure credentials file exists for the shared read-write mount
if not exist "%USERPROFILE%\.claude" mkdir "%USERPROFILE%\.claude"
if not exist "%USERPROFILE%\.claude\.credentials.json" echo {}> "%USERPROFILE%\.claude\.credentials.json"
set HOST_MOUNTS=!HOST_MOUNTS! -v "%USERPROFILE%\.claude\.credentials.json:/tmp/.host-credentials.json"

REM Share Codex auth the same way (seed an empty file so the bind mount works).
REM Mounted for both agents so the image serves either regardless of which one
REM you launched to log in.
if not exist "%USERPROFILE%\.codex" mkdir "%USERPROFILE%\.codex"
if not exist "%USERPROFILE%\.codex\auth.json" echo {}> "%USERPROFILE%\.codex\auth.json"
set HOST_MOUNTS=!HOST_MOUNTS! -v "%USERPROFILE%\.codex\auth.json:/tmp/.host-codex-auth.json"

REM Pass the selected agent, git-access flag, and any auth env vars into the container
set ENV_FLAGS=-e CONTAINER_AGENT=%AGENT% -e GIT_ACCESS=%GIT_ACCESS_VALUE%
if defined ANTHROPIC_API_KEY set ENV_FLAGS=!ENV_FLAGS! -e ANTHROPIC_API_KEY=%ANTHROPIC_API_KEY%
if defined OPENAI_API_KEY set ENV_FLAGS=!ENV_FLAGS! -e OPENAI_API_KEY=%OPENAI_API_KEY%

REM Runtime-specific flags
if "%RUNTIME%"=="podman" (
    set RUNTIME_FLAGS=--userns=keep-id
) else (
    set RUNTIME_FLAGS=--cap-drop=ALL --security-opt=no-new-privileges
)

REM Summarize the active auth source for the banner. An env-var key takes
REM precedence over the persisted subscription/ChatGPT login in the mounted home.
if /i "%AGENT%"=="codex" (
    if defined OPENAI_API_KEY ( set AUTH_STATUS=OPENAI_API_KEY ) else ( set AUTH_STATUS=ChatGPT login ^(~/.codex^) )
) else (
    if defined ANTHROPIC_API_KEY ( set AUTH_STATUS=ANTHROPIC_API_KEY ) else ( set AUTH_STATUS=subscription login ^(~/.claude^) )
)

echo --------------------------------------------------------------
echo   GIT ACCESS:  %GIT_STATUS%
echo                (toggle with GIT_ACCESS=1^|0)
echo --------------------------------------------------------------
echo   Agent:       %AGENT_LABEL%   (switch with AGENT=claude^|codex)
echo   Auth:        %AUTH_STATUS%
echo   Workspace:   %cd% -^> %WORKSPACE_PATH%
echo   Home volume: %VOLUME_NAME% (persistent)
echo   Update:      %LAUNCHER% --update   rebuilds with the latest release
echo --------------------------------------------------------------

%RUNTIME% run --rm -it --network=bridge -w "%WORKSPACE_PATH%" %RUNTIME_FLAGS% %ENV_FLAGS% %HOST_MOUNTS% -v %VOLUME_NAME%:/home/claude -v "%cd%:%WORKSPACE_PATH%" %IMAGE_NAME% !RUN_ARGS!
