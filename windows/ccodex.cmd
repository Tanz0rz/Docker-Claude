@echo off
REM setlocal keeps AGENT scoped to this launch so it doesn't leak into the shell
REM and affect a later `cclaude` in the same terminal.
setlocal
set AGENT=codex
"%~dp0run.bat" %*
