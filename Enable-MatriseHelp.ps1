# Matrise - let another PC in this house help this one.
#
# Asked for by: daniel on DESKTOP-1DP2QP6
#
# Run this ONCE, on the PC that needs help, as Administrator:
#   right-click Start > Terminal (Admin) / PowerShell (Admin), then paste it.
#
# It does three things, all of them reversible - the undo is at the bottom.

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "1. Marking this network as Private" -ForegroundColor Cyan
# Remote help only works on a network Windows trusts. On Public, the
# firewall blocks it - which is correct behaviour in a cafe.
Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } | ForEach-Object {
    Write-Host "   $($_.InterfaceAlias): Public -> Private"
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

Write-Host ""
Write-Host "2. Turning on Windows remote management" -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck

Write-Host ""
Write-Host "3. Details the other PC needs" -ForegroundColor Cyan
$ips = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress
Write-Host ""
Write-Host "   Computer name : $env:COMPUTERNAME" -ForegroundColor Green
Write-Host "   IP address    : $($ips -join ', ')" -ForegroundColor Green
Write-Host "   Your username : $env:USERNAME" -ForegroundColor Green
Write-Host ""
Write-Host "   The other PC will ask for that username and your Windows password."
Write-Host "   If you sign in with a Microsoft account, the username is usually"
Write-Host "   your email address, and the password is the one you type at startup."
Write-Host ""
Write-Host "TO UNDO ALL OF THIS LATER, run:" -ForegroundColor Yellow
Write-Host "   Disable-PSRemoting -Force"
Write-Host "   Stop-Service WinRM; Set-Service WinRM -StartupType Disabled"
Write-Host ""
Read-Host "Press Enter to close"