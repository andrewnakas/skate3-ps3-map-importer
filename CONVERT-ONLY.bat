@echo off
setlocal
cd /d "%~dp0"
title Skate 3 PS3 to Xbox 360 Map Converter v1.18
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Skate3-PS3-to-X360-Map-Importer.ps1" -SkipInstallPrompt %*
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" echo Converter exited with error code %ERR%.
pause
exit /b %ERR%
