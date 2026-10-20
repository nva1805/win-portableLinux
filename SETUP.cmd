@echo off
setlocal
title win-portableLinux - Setup
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\Setup.ps1"
set "result=%errorlevel%"
echo.
if not "%result%"=="0" echo Setup did not complete. Read the message above and runtime\logs.
pause
exit /b %result%
