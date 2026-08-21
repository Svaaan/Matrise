@echo off
rem Matrise without elevation.
rem Read-only checks mostly still work; commands marked * return partial data
rem and everything in the Fix sections will fail. Use Matrise.bat instead
rem unless you specifically want to avoid the UAC prompt.

start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Matrise.ps1"
exit /b
