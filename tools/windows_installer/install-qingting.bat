@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install-qingting.ps1"
exit /b %errorlevel%
