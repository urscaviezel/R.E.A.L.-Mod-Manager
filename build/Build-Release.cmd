@echo off
rem Baut Portable-ZIP und (falls Inno Setup 6 installiert) den Installer nach dist\
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Release.ps1"
echo.
pause
