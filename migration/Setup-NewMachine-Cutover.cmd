@echo off
rem Runs only the repo steps (Cutover) of the new-laptop setup. Double-click it; do NOT
rem "Run as administrator": OneDrive will not download files for an administrator.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewMachine.ps1" -Phase Cutover -KitPath "%~dp0."
echo.
pause
