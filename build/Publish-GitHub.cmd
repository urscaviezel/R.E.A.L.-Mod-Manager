@echo off
rem Laedt den Quellcode nach GitHub hoch und oeffnet die Seite fuer das Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-GitHub.ps1"
echo.
pause
