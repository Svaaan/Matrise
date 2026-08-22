# ===================================================================
#  Matrise - let one PC in this house help this one.
#
#  Asked for by : daniel on DESKTOP-1DP2QP6
#
#  HOW TO RUN IT
#    Right-click the Start button, choose Terminal (Admin) or
#    PowerShell (Admin), then run this file.
#
#  YOUR CODE APPEARS AT STEP 3 OF 4, on purpose.
#  Step 4 is the slow one and can stall on some PCs. By then the code
#  is already on your clipboard and saved to your Desktop, so a stall
#  costs you nothing - close the window and send the code anyway.
#
#  Everything this changes is undone by the commands at the bottom.
# ===================================================================

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "This needs an Administrator window." -ForegroundColor Red
    Write-Host "Right-click Start, choose Terminal (Admin), and run it again."
    Write-Host ""
    Read-Host "Press Enter to close"
    return
}

$acct = 'MatriseHelp'

Write-Host ""
Write-Host "Four steps. Your code arrives at step 3 - before anything slow runs." -ForegroundColor DarkGray
Write-Host "Each step says done when it finishes, so you can see where it is." -ForegroundColor DarkGray
Write-Host "Ctrl+C stops it safely at any point." -ForegroundColor DarkGray
Write-Host ""

Write-Host "STEP 1 of 4 - creating the helper account" -ForegroundColor Cyan
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-'
$bytes = New-Object byte[] 24
$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$plain = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
$sec = ConvertTo-SecureString $plain -AsPlainText -Force

if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $acct -Password $sec
    Write-Host "   reused $acct and gave it a new password"
} else {
    New-LocalUser -Name $acct -Password $sec -FullName "Matrise remote help" `
        -Description "Matrise remote help - safe to delete" `
        -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Write-Host "   created $acct"
}
Add-LocalGroupMember -Group "Administrators" -Member $acct -ErrorAction SilentlyContinue
Write-Host "   done" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 2 of 4 - allowing that account to administer this PC remotely" -ForegroundColor Cyan
# Without this a local administrator connecting over the network gets a
# stripped-down token, and every repair fails with access denied even
# though the password was right. Documented requirement for PCs that are
# not in a company domain.
$k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host "   done" -ForegroundColor Green

# Deliberately before step 4. Everything above is instant and cannot
# stall; step 4 touches the network stack and sometimes does. Getting the
# code out first makes a stall an inconvenience rather than a dead end.
Write-Host ""
Write-Host "STEP 3 of 4 - your code" -ForegroundColor Cyan
$ips = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
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

$saved = ""
try {
    $desk = [Environment]::GetFolderPath("Desktop")
    $codeFile = Join-Path $desk "Matrise-code.txt"
    Set-Content -Path $codeFile -Value $code -Encoding UTF8
    $saved = $codeFile
} catch { }
try { Set-Clipboard -Value $code } catch { }

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " SEND THIS ONE LINE BACK:" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host $code -ForegroundColor Yellow
Write-Host ""
Write-Host " It is on your clipboard - just paste it to them." -ForegroundColor Green
if ($saved) { Write-Host " Also saved to: $saved" -ForegroundColor Green }
Write-Host ""
Write-Host " That code is a password. Send it privately, delete it afterwards." -ForegroundColor Yellow
Write-Host "   done" -ForegroundColor Green

Write-Host ""
Write-Host "STEP 4 of 4 - turning on Windows remote management" -ForegroundColor Cyan
Write-Host "   This is the slow one - 20 to 60 seconds is normal, and the window"
Write-Host "   looks frozen while it works."
Write-Host "   YOUR CODE IS ALREADY SAVED. If this stalls, close the window and"
Write-Host "   send the code anyway - the rest can be sorted out afterwards."
Write-Host ""

# Reported, not changed. Switching the network category reconfigures the
# firewall and the network stack, and -SkipNetworkProfileCheck below makes
# it unnecessary: the rule it adds is scoped to the local subnet.
$pub = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' })
if ($pub) {
    Write-Host "   note: this network is set to Public ($($pub[0].InterfaceAlias))."
    Write-Host "   Usually still fine. If the other PC cannot connect later, run:"
    Write-Host "      Set-NetConnectionProfile -InterfaceIndex $($pub[0].InterfaceIndex) -NetworkCategory Private"
    Write-Host ""
}

$job = Start-Job -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck }
if (Wait-Job $job -Timeout 180) {
    $r = Receive-Job $job -ErrorAction SilentlyContinue
    if ($r) { $r | Out-String | Write-Host }
    Write-Host "   done" -ForegroundColor Green
} else {
    Stop-Job $job -ErrorAction SilentlyContinue
    Write-Host "   it did not finish within 3 minutes - moving on" -ForegroundColor Yellow
}
Remove-Job $job -Force -ErrorAction SilentlyContinue

$listening = @(Get-NetTCPConnection -LocalPort 5985,5986 -State Listen -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty LocalPort -Unique)
Write-Host ""
if ($listening) {
    Write-Host "ALL DONE. This PC is ready, listening on port $($listening -join '/')." -ForegroundColor Green
} else {
    Write-Host "Remote management is not accepting connections yet." -ForegroundColor Yellow
    Write-Host "Send the code anyway - it stays valid. Then try this and run me again:" -ForegroundColor Yellow
    Write-Host "   winrm quickconfig -force"
    Write-Host "If that hangs too, restart the PC first - a pending Windows Update"
    Write-Host "can hold the network stack open and make this step wait forever."
}

Write-Host ""
Write-Host "TO UNDO EVERYTHING LATER, run as Administrator:" -ForegroundColor Cyan
Write-Host "   Disable-PSRemoting -Force"
Write-Host "   Remove-LocalUser -Name $acct"
Write-Host "   Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy"
Write-Host "   Stop-Service WinRM; Set-Service WinRM -StartupType Disabled"
Write-Host ""
Read-Host "Press Enter to close"