@echo off
setlocal DisableDelayedExpansion
title Codex Shutdown Guard Setup
if not exist "%~dp0scripts\Setup.ps1" goto incomplete
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\Setup.ps1" -Mode Install
set "setup_exit=%errorlevel%"
if "%setup_exit%"=="0" exit /b 0
echo Setup did not finish successfully. See the setup window for details.
pause
exit /b %setup_exit%
:incomplete
echo Package is incomplete. Extract the entire ZIP, then double-click Install.cmd.
pause
exit /b 1
