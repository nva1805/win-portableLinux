@echo off
setlocal
title Portable Ubuntu Terminal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Launcher.ps1" -Terminal
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
