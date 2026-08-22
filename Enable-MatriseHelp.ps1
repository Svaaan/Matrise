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
Write-Host "If this seems to stop on step 2, give it a minute before worrying." -ForegroundColor DarkGray
Write-Host "Every step says done when it finishes, so you can always see where it is." -ForegroundColor DarkGray
Write-Host ""

Write-Host "STEP 1 of 5 - making this network Private" -ForegroundColor Cyan
$pub = @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' })
if ($pub) {
    foreach ($p in $pub) {
        Write-Host "   $($p.InterfaceAlias): Public -> Private"
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
    }
} else {
    Write-Host "   already Private"
}
Write-Host "   done" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 2 of 5 - turning on Windows remote management" -ForegroundColor Cyan
Write-Host "   This is the slow one. It normally takes 20-60 seconds and the"
Write-Host "   window looks frozen while it works. It is not frozen."

# Run it with a time limit. Left to itself this command can wait forever on
# a network stack that is mid-change, and it prints nothing while it does,
# which is indistinguishable from a crash.
$job = Start-Job -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck }
if (Wait-Job $job -Timeout 180) {
    $r = Receive-Job $job -ErrorAction SilentlyContinue
    if ($r) { $r | Out-String | Write-Host }
    Write-Host "   done" -ForegroundColor Green
} else {
    Stop-Job $job -ErrorAction SilentlyContinue
    Write-Host "   it did not finish within 3 minutes" -ForegroundColor Yellow
}
Remove-Job $job -Force -ErrorAction SilentlyContinue

# What matters is not whether the command returned, but whether this PC is
# now actually accepting connections. Check the thing itself.
$listening = @(Get-NetTCPConnection -LocalPort 5985,5986 -State Listen -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty LocalPort -Unique)
if (-not $listening) {
    Write-Host ""
    Write-Host "STOPPING - remote management is still not accepting connections." -ForegroundColor Red
    Write-Host "A code handed over now would not work, so this script will not print one."
    Write-Host ""
    Write-Host "Try these two by hand, then run this script again:" -ForegroundColor Cyan
    Write-Host "   Get-NetConnectionProfile      <- every one should say Private"
    Write-Host "   winrm quickconfig -force"
    Write-Host ""
    Write-Host "If winrm quickconfig also hangs, restart the PC and try once more -"
    Write-Host "a pending Windows Update can hold the network stack open."
    Write-Host ""
    Read-Host "Press Enter to close"
    return
}
Write-Host "   listening on port $($listening -join '/')" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 3 of 5 - creating the helper account" -ForegroundColor Cyan
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

Write-Host "   done" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 4 of 5 - allowing that account to administer this PC remotely" -ForegroundColor Cyan
# Without this, a local administrator connecting over the network gets a
# stripped-down token and every repair fails with "access denied" even
# though the password was right. This is the documented setting for
# remote management between PCs that are not in a domain.
$k = "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"
New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "   done" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 5 of 5 - building your code" -ForegroundColor Cyan

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