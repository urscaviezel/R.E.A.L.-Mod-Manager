@echo off
rem Startet den Manager mit sichtbarem PowerShell-Fenster (fuer Fehlersuche)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%~dp0RealVRManager.ps1" -DebugConsole
