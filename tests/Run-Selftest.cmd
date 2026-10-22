@echo off
rem Selbsttest mit simulierten Spielen im Ordner tests\_work (fasst keine echten Spiele an)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Tests.ps1"
pause
