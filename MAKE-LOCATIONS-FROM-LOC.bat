@echo off
setlocal
cd /d "%~dp0"
title Make Skate 3 Locations from a map's locator table
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Make-LocationGroupFromLoc.ps1" %*
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" echo Exited with error code %ERR%.
pause
exit /b %ERR%
