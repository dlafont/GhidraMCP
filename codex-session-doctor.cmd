@echo off
setlocal
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\codex-session-doctor.ps1" %*
exit /b %ERRORLEVEL%
