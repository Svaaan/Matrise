# Matrise - One-code pairing
#
# The manual route works, but it asks a parent to copy a computer name, add it
# to a trusted list, and then type "HERPC\name" plus a password into a Windows
# dialog. Every one of those is a place to get it wrong, and the error you get
# back ("Access is denied") does not tell you which one you got wrong.
#
# This replaces all of it with: they run one script, it prints one code, you
# paste that code. Matrise fills in the machine, trusts it, and stores the
# credential.
#
# ---------------------------------------------------------------------------
# WHAT CANNOT BE AUTOMATED, AND WHY
#
# Something must be run once, by them, as Administrator, on their machine.
# Windows will not let a remote computer switch on its own remote management -
# if it did, that would be the vulnerability. That step is the consent, and it
# is deliberately not something you can do to someone from a distance.
#
# WHAT THE CODE CONTAINS
#
# The code is a password. It carries the account name and password of a helper
# account created on their PC. Base64 is not encryption - anyone who reads the
# code can use it. Send it the same way you would send a password, and delete
# the message afterwards.
# ---------------------------------------------------------------------------

$script:MatriseHelperAccount = 'MatriseHelp'

# Windows caps a local account description at 48 characters and New-LocalUser
# throws rather than truncating, which kills the whole setup at its first step.
# Defined once so the generated script and the Host button cannot drift apart
# or past the limit.
$script:MatriseHelperDesc = 'Matrise remote help - safe to delete'

function New-MatriseCodePassword {
    param([int]$Length = 24)
    # Ambiguous characters left out so a code read aloud or retyped still works.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function ConvertTo-MatrisePairingCode {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Compress)
    'MX1-' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertFrom-MatrisePairingCode {
    param([string]$Code)

    $c = ($Code -replace '\s', '')
    if (-not $c) { throw 'No code was pasted.' }
    if ($c -notmatch '^MX1-') {
        throw ("That does not look like a Matrise pairing code. It should be one long " +
               "line starting with MX1- . Copy the whole thing, including the MX1- part.")
    }
    $b64 = $c.Substring(4)
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $o = $json | ConvertFrom-Json
    }
    catch {
        throw ("The code is damaged - it was probably cut short when copied. Ask them to " +
               "send it again, making sure the whole line comes across in one piece.")
    }
    if (-not $o.h -or -not $o.u -or -not $o.p) {
        throw 'The code is missing part of its contents. Ask them to run the setup script again.'
    }

    [pscustomobject]@{
        HostName  = [string]$o.h
        Addresses = @($o.i)
        UserName  = [string]$o.u
        Password  = [string]$o.p
        MadeUtc   = [string]$o.t
    }
}

# --------------------------------------------------------- credential store -
# Export-Clixml encrypts the password with DPAPI, scoped to this Windows account
# on this machine. Copying the file to another PC, or opening it as another
# user, yields nothing usable.

function Get-MatrisePeerStore {
    $dir = Join-Path $env:LOCALAPPDATA 'Matrise\peers'
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
    $dir
}

function Save-MatrisePeerCredential {
    param([string]$HostName, [System.Management.Automation.PSCredential]$Credential)
    $f = Join-Path (Get-MatrisePeerStore) (($HostName -replace '[^A-Za-z0-9._-]', '_') + '.xml')
    $Credential | Export-Clixml -Path $f -Force
    $f
}

function Get-MatrisePeerCredential {
    param([string]$HostName)
    $f = Join-Path (Get-MatrisePeerStore) (($HostName -replace '[^A-Za-z0-9._-]', '_') + '.xml')
    if (-not (Test-Path $f)) { return $null }
    try { Import-Clixml -Path $f } catch { $null }
}

function Remove-MatrisePeerCredential {
    param([string]$HostName)
    $f = Join-Path (Get-MatrisePeerStore) (($HostName -replace '[^A-Za-z0-9._-]', '_') + '.xml')
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue; return $true }
    $false
}

function Get-MatrisePairedPeers {
    Get-ChildItem (Get-MatrisePeerStore) -Filter '*.xml' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName }
}

# ------------------------------------------------------ the script they run --
function New-MatriseHandshakeScript {
    param([string]$HelperPc = $env:COMPUTERNAME, [string]$HelperUser = $env:USERNAME, [string]$OutFile)

    $acct = $script:MatriseHelperAccount

    $lines = @(
        '# ===================================================================',
        '#  Matrise - let one PC in this house help this one.',
        '#',
        "#  Asked for by : $HelperUser on $HelperPc",
        '#',
        '#  HOW TO RUN IT',
        '#    Right-click the Start button, choose Terminal (Admin) or',
        '#    PowerShell (Admin), then run this file.',
        '#',
        '#  YOUR CODE APPEARS AT STEP 3 OF 4, on purpose.',
        '#  Step 4 is the slow one and can stall on some PCs. By then the code',
        '#  is already on your clipboard and saved to your Desktop, so a stall',
        '#  costs you nothing - close the window and send the code anyway.',
        '#',
        '#  Everything this changes is undone by the commands at the bottom.',
        '# ===================================================================',
        '',
        '$ErrorActionPreference = ''Stop''',
        '',
        'if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()' +
            ').IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {',
        '    Write-Host ""',
        '    Write-Host "This needs an Administrator window." -ForegroundColor Red',
        '    Write-Host "Right-click Start, choose Terminal (Admin), and run it again."',
        '    Write-Host ""',
        '    Read-Host "Press Enter to close"',
        '    return',
        '}',
        '',
        "`$acct = '$acct'",
        '',
        'Write-Host ""',
        'Write-Host "Four steps. Your code arrives at step 3 - before anything slow runs." -ForegroundColor DarkGray',
        'Write-Host "Each step says done when it finishes, so you can see where it is." -ForegroundColor DarkGray',
        'Write-Host "Ctrl+C stops it safely at any point." -ForegroundColor DarkGray',
        'Write-Host ""',
        '',
        'Write-Host "STEP 1 of 4 - creating the helper account" -ForegroundColor Cyan',
        '$alphabet = ''ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-''',
        '$bytes = New-Object byte[] 24',
        '$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()',
        'try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }',
        '$plain = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })',
        '$sec = ConvertTo-SecureString $plain -AsPlainText -Force',
        '',
        'if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {',
        '    Set-LocalUser -Name $acct -Password $sec',
        '    Write-Host "   reused $acct and gave it a new password"',
        '} else {',
        '    New-LocalUser -Name $acct -Password $sec -FullName "Matrise remote help" `',
        "        -Description `"$script:MatriseHelperDesc`" ``",
        '        -PasswordNeverExpires -AccountNeverExpires | Out-Null',
        '    Write-Host "   created $acct"',
        '}',
        'Add-LocalGroupMember -Group "Administrators" -Member $acct -ErrorAction SilentlyContinue',
        'Write-Host "   done" -ForegroundColor Green',
        '',
        'Write-Host ""',
        'Write-Host "STEP 2 of 4 - allowing that account to administer this PC remotely" -ForegroundColor Cyan',
        '# Without this a local administrator connecting over the network gets a',
        '# stripped-down token, and every repair fails with access denied even',
        '# though the password was right. Documented requirement for PCs that are',
        '# not in a company domain.',
        '$k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"',
        'New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null',
        'Write-Host "   done" -ForegroundColor Green',
        '',
        '# Deliberately before step 4. Everything above is instant and cannot',
        '# stall; step 4 touches the network stack and sometimes does. Getting the',
        '# code out first makes a stall an inconvenience rather than a dead end.',
        'Write-Host ""',
        'Write-Host "STEP 3 of 4 - your code" -ForegroundColor Cyan',
        '$ips = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |',
        '    Where-Object { $_.IPAddress -notlike ''127.*'' -and $_.IPAddress -notlike ''169.254.*'' }).IPAddress)',
        '$payload = @{',
        '    v = 1',
        '    h = $env:COMPUTERNAME',
        '    i = $ips',
        '    u = $acct',
        '    p = $plain',
        '    t = (Get-Date).ToUniversalTime().ToString("o")',
        '}',
        '$json = ($payload | ConvertTo-Json -Compress)',
        '$code = "MX1-" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))',
        '',
        '$saved = ""',
        'try {',
        '    $desk = [Environment]::GetFolderPath("Desktop")',
        '    $codeFile = Join-Path $desk "Matrise-code.txt"',
        '    Set-Content -Path $codeFile -Value $code -Encoding UTF8',
        '    $saved = $codeFile',
        '} catch { }',
        'try { Set-Clipboard -Value $code } catch { }',
        '',
        'Write-Host ""',
        'Write-Host "==================================================================" -ForegroundColor Green',
        'Write-Host " SEND THIS ONE LINE BACK:" -ForegroundColor Green',
        'Write-Host "==================================================================" -ForegroundColor Green',
        'Write-Host ""',
        'Write-Host $code -ForegroundColor Yellow',
        'Write-Host ""',
        'Write-Host " It is on your clipboard - just paste it to them." -ForegroundColor Green',
        'if ($saved) { Write-Host " Also saved to: $saved" -ForegroundColor Green }',
        'Write-Host ""',
        'Write-Host " That code is a password. Send it privately, delete it afterwards." -ForegroundColor Yellow',
        'Write-Host "   done" -ForegroundColor Green',
        '',
        'Write-Host ""',
        'Write-Host "STEP 4 of 4 - turning on Windows remote management" -ForegroundColor Cyan',
        'Write-Host "   This is the slow one - 20 to 60 seconds is normal, and the window"',
        'Write-Host "   looks frozen while it works."',
        'Write-Host "   YOUR CODE IS ALREADY SAVED. If this stalls, close the window and"',
        'Write-Host "   send the code anyway - the rest can be sorted out afterwards."',
        'Write-Host ""',
        '',
        '# Reported, not changed. Switching the network category reconfigures the',
        '# firewall and the network stack, and -SkipNetworkProfileCheck below makes',
        '# it unnecessary: the rule it adds is scoped to the local subnet.',
        '$pub = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq ''Public'' })',
        'if ($pub) {',
        '    Write-Host "   note: this network is set to Public ($($pub[0].InterfaceAlias))."',
        '    Write-Host "   Usually still fine. If the other PC cannot connect later, run:"',
        '    Write-Host "      Set-NetConnectionProfile -InterfaceIndex $($pub[0].InterfaceIndex) -NetworkCategory Private"',
        '    Write-Host ""',
        '}',
        '',
        '$job = Start-Job -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck }',
        'if (Wait-Job $job -Timeout 180) {',
        '    $r = Receive-Job $job -ErrorAction SilentlyContinue',
        '    if ($r) { $r | Out-String | Write-Host }',
        '    Write-Host "   done" -ForegroundColor Green',
        '} else {',
        '    Stop-Job $job -ErrorAction SilentlyContinue',
        '    Write-Host "   it did not finish within 3 minutes - moving on" -ForegroundColor Yellow',
        '}',
        'Remove-Job $job -Force -ErrorAction SilentlyContinue',
        '',
        '$listening = @(Get-NetTCPConnection -LocalPort 5985,5986 -State Listen -ErrorAction SilentlyContinue |',
        '               Select-Object -ExpandProperty LocalPort -Unique)',
        'Write-Host ""',
        'if ($listening) {',
        '    Write-Host "ALL DONE. This PC is ready, listening on port $($listening -join ''/'')." -ForegroundColor Green',
        '} else {',
        '    Write-Host "Remote management is not accepting connections yet." -ForegroundColor Yellow',
        '    Write-Host "Send the code anyway - it stays valid. Then try this and run me again:" -ForegroundColor Yellow',
        '    Write-Host "   winrm quickconfig -force"',
        '    Write-Host "If that hangs too, restart the PC first - a pending Windows Update"',
        '    Write-Host "can hold the network stack open and make this step wait forever."',
        '}',
        '',
        'Write-Host ""',
        'Write-Host "TO UNDO EVERYTHING LATER, run as Administrator:" -ForegroundColor Cyan',
        'Write-Host "   Disable-PSRemoting -Force"',
        'Write-Host "   Remove-LocalUser -Name $acct"',
        'Write-Host "   Remove-ItemProperty -Path ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'' -Name LocalAccountTokenFilterPolicy"',
        'Write-Host "   Stop-Service WinRM; Set-Service WinRM -StartupType Disabled"',
        'Write-Host ""',
        'Read-Host "Press Enter to close"'
    ) -join "`r`n"

    if ($OutFile) {
        [System.IO.File]::WriteAllText($OutFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    $lines
}

# ------------------------------------------------------ using the code -------
# Everything the paste does, in one place, so the GUI and the command line
# behave identically.
function Import-MatrisePairingCode {
    param([Parameter(Mandatory)] [string]$Code, [switch]$NoTrust)

    $p = ConvertFrom-MatrisePairingCode -Code $Code
    $steps = New-Object System.Collections.ArrayList
    $add = { param($ok, $text) [void]$steps.Add([pscustomobject]@{ Ok = $ok; Text = $text }) }

    & $add $true "Code is for '$($p.HostName)', account '$($p.UserName)'."
    if ($p.Addresses) { & $add $true "Addresses in the code: $($p.Addresses -join ', ')" }

    if (-not $NoTrust) {
        $names = @($p.HostName) + @($p.Addresses) | Where-Object { $_ }
        try {
            $msg = Add-MatriseTrustedHost -Name ($names -join ',')
            & $add $true $msg
        }
        catch {
            & $add $false ("Could not update the trusted list: " + $_.Exception.Message)
        }
    }

    $sec = ConvertTo-SecureString $p.Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential("$($p.HostName)\$($p.UserName)", $sec)

    try {
        $f = Save-MatrisePeerCredential -HostName $p.HostName -Credential $cred
        & $add $true "Saved the sign-in for $($p.HostName), encrypted to your Windows account only."
    }
    catch {
        & $add $false ("Could not save the sign-in: " + $_.Exception.Message)
    }

    [pscustomobject]@{
        HostName   = $p.HostName
        Credential = $cred
        Steps      = $steps
    }
}
