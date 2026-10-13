@echo off
rem Sets up a new ScanB dev laptop from this kit. Double-click it (do NOT "Run as administrator":
rem the setup opens its own admin window for the installs, and the repo steps must run without it).
rem Optional argument: prepare, cutover or all (the default).
setlocal
set "PHASE=%~1"
if "%PHASE%"=="" set "PHASE=All"
cd /d "%~dp0"

rem Ask OneDrive to keep the whole kit on this device.
attrib +P -U /S /D "%~dp0*" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-NewMachine.ps1" -Phase %PHASE% -KitPath "%~dp0."
echo.
pause
