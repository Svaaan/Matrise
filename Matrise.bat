@echo off
rem Matrise - launches the window as Administrator.
rem Most checks return partial data without elevation, and none of the Fix
rem commands work at all, so this is the launcher you normally want.

setlocal
set "PS1=%~dp0Matrise.ps1"

net session >nul 2>&1
if %errorlevel%==0 goto run

echo Requesting Administrator...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File','\"%PS1%\"'"
exit /b

:run
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
exit /b
