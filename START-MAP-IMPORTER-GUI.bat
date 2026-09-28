@echo off
setlocal
cd /d "%~dp0"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Skate3-PS3-to-X360-Map-Importer-GUI.ps1"
exit /b 0
