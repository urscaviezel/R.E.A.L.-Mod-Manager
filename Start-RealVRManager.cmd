@echo off
rem R.E.A.L. Mod Manager starten (fragt nach Administratorrechten)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0RealVRManager.ps1"
