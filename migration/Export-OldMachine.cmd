@echo off
rem Packs the ScanB migration kit into OneDrive, encrypted. Run it on the OLD laptop.
rem Any arguments are passed on, for example:  Export-OldMachine.cmd -AllDatabases
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-OldMachine.ps1" %*
echo.
pause
