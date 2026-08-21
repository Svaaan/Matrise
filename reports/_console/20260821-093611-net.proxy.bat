@echo off
title Matrise - Proxy settings (system + user)
echo ================================================================
echo  MATRISE  ^|  Proxy settings (system + user)
echo ================================================================
echo.
echo COMMAND:
echo   netsh winhttp show proxy ^& reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable ^& reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer ^& reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL
echo.
echo ----------------------------------------------------------------
echo.
netsh winhttp show proxy & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL
echo.
echo ----------------------------------------------------------------
echo Finished. This window stays open - type exit to close it.