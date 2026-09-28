@echo off
setlocal
cd /d "%~dp0"
title Install Converted Xbox 360 Map to Skate3Recomp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Converted-Map-To-Recomp.ps1" %*
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" echo Installer exited with error code %ERR%.
pause
exit /b %ERR%
