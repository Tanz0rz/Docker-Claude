@echo off
REM setlocal + explicit AGENT so a leftover AGENT=codex in the shell (e.g. after
REM `ccodex`) can't redirect this launch.
setlocal
set AGENT=claude
"%~dp0run.bat" %*
