# ===================================================================
#  Matrise - let one PC in this house help this one.
#
#  Asked for by : daniel on DESKTOP-1DP2QP6
#
#  HOW TO RUN IT
#    Right-click the Start button, choose Terminal (Admin) or
#    PowerShell (Admin), paste this whole thing, press Enter.
#
#  WHAT IT DOES - all four are undone by the command at the bottom.
#    1. Marks this network Private, so Windows stops blocking help.
#    2. Turns on Windows remote management.
#    3. Creates a local account called MatriseHelp with a random password,
#       and makes it an administrator so repairs actually work. The
#       account is left VISIBLE on purpose - nothing here hides.
#    4. Allows that account to administer this PC remotely.
#
#  Then it prints ONE CODE. Send that code back. The code IS a
#  password - send it privately and delete it afterwards.
# ===================================================================

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "This needs an Administrator window." -ForegroundColor Red
    Write-Host "Right-click Start, choose Terminal (Admin), and paste it again."
    Write-Host ""
    Read-Host "Press Enter to close"
    return
}

$acct = 'MatriseHelp'

Write-Host ""
Write-Host "1. Making this network Private" -ForegroundColor Cyan
Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } | ForEach-Object {
    Write-Host "   $($_.InterfaceAlias): Public -> Private"
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
}

Write-Host "2. Turning on Windows remote management" -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

Write-Host "3. Creating the helper account" -ForegroundColor Cyan
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-'
$bytes = New-Object byte[] 24
$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$plain = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
$sec = ConvertTo-SecureString $plain -AsPlainText -Force

if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $acct -Password $sec
    Write-Host "   reused the existing $acct account and gave it a new password"
} else {
    New-LocalUser -Name $acct -Password $sec -FullName "Matrise remote help" `
        -Description "Created by Matrise so another PC in this house can help. Safe to delete." `
        -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Host "   created $acct"
}
Add-LocalGroupMember -Group "Administrators" -Member $acct -ErrorAction SilentlyContinue

Write-Host "4. Allowing that account to administer this PC remotely" -ForegroundColor Cyan
# Without this, a local administrator connecting over the network gets a
# stripped-down token and every repair fails with "access denied" even
# though the password was right. This is the documented setting for
# remote management between PCs that are not in a domain.
$k = "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"
New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

$ips = @((Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress)

$payload = @{
    v = 1
    h = $env:COMPUTERNAME
    i = $ips
    u = $acct
    p = $plain
    t = (Get-Date).ToUniversalTime().ToString("o")
}
$json = ($payload | ConvertTo-Json -Compress)
$code = "MX1-" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " DONE. Send this ONE LINE back:" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host $code -ForegroundColor Yellow
Write-Host ""
try {
    Set-Clipboard -Value $code
    Write-Host " (it is already on your clipboard - just paste it to them)" -ForegroundColor Green
} catch { }
Write-Host ""
Write-Host " That code is a password. Send it privately and delete it after." -ForegroundColor Yellow
Write-Host ""
Write-Host "TO UNDO EVERYTHING LATER, run this as Administrator:" -ForegroundColor Cyan
Write-Host "   Disable-PSRemoting -Force"
Write-Host "   Remove-LocalUser -Name $acct"
Write-Host "   Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name LocalAccountTokenFilterPolicy"
Write-Host "   Stop-Service WinRM; Set-Service WinRM -StartupType Disabled"
Write-Host ""
Read-Host "Press Enter to close"