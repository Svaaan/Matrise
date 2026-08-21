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
        '#    PowerShell (Admin), paste this whole thing, press Enter.',
        '#',
        '#  WHAT IT DOES - all four are undone by the command at the bottom.',
        "#    1. Marks this network Private, so Windows stops blocking help.",
        '#    2. Turns on Windows remote management.',
        "#    3. Creates a local account called $acct with a random password,",
        '#       and makes it an administrator so repairs actually work. The',
        '#       account is left VISIBLE on purpose - nothing here hides.',
        '#    4. Allows that account to administer this PC remotely.',
        '#',
        '#  Then it prints ONE CODE. Send that code back. The code IS a',
        '#  password - send it privately and delete it afterwards.',
        '# ===================================================================',
        '',
        '$ErrorActionPreference = ''Stop''',
        '',
        'if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()' +
            ').IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {',
        '    Write-Host ""',
        '    Write-Host "This needs an Administrator window." -ForegroundColor Red',
        '    Write-Host "Right-click Start, choose Terminal (Admin), and paste it again."',
        '    Write-Host ""',
        '    Read-Host "Press Enter to close"',
        '    return',
        '}',
        '',
        "`$acct = '$acct'",
        '',
        'Write-Host ""',
        'Write-Host "1. Making this network Private" -ForegroundColor Cyan',
        'Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq ''Public'' } | ForEach-Object {',
        '    Write-Host "   $($_.InterfaceAlias): Public -> Private"',
        '    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private',
        '}',
        '',
        'Write-Host "2. Turning on Windows remote management" -ForegroundColor Cyan',
        'Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null',
        '',
        'Write-Host "3. Creating the helper account" -ForegroundColor Cyan',
        '$alphabet = ''ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-''',
        '$bytes = New-Object byte[] 24',
        '$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()',
        'try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }',
        '$plain = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })',
        '$sec = ConvertTo-SecureString $plain -AsPlainText -Force',
        '',
        'if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {',
        '    Set-LocalUser -Name $acct -Password $sec',
        '    Write-Host "   reused the existing $acct account and gave it a new password"',
        '} else {',
        '    New-LocalUser -Name $acct -Password $sec -FullName "Matrise remote help" `',
        '        -Description "Created by Matrise so another PC in this house can help. Safe to delete." `',
        '        -PasswordNeverExpires -AccountNeverExpires | Out-Null',
        '    Write-Host "   created $acct"',
        '}',
        'Add-LocalGroupMember -Group "Administrators" -Member $acct -ErrorAction SilentlyContinue',
        '',
        'Write-Host "4. Allowing that account to administer this PC remotely" -ForegroundColor Cyan',
        '# Without this, a local administrator connecting over the network gets a',
        '# stripped-down token and every repair fails with "access denied" even',
        '# though the password was right. This is the documented setting for',
        '# remote management between PCs that are not in a domain.',
        '$k = "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System"',
        'New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null',
        '',
        '$ips = @((Get-NetIPAddress -AddressFamily IPv4 |',
        '    Where-Object { $_.IPAddress -notlike ''127.*'' -and $_.IPAddress -notlike ''169.254.*'' }).IPAddress)',
        '',
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
        'Write-Host ""',
        'Write-Host "==================================================================" -ForegroundColor Green',
        'Write-Host " DONE. Send this ONE LINE back:" -ForegroundColor Green',
        'Write-Host "==================================================================" -ForegroundColor Green',
        'Write-Host ""',
        'Write-Host $code -ForegroundColor Yellow',
        'Write-Host ""',
        'try {',
        '    Set-Clipboard -Value $code',
        '    Write-Host " (it is already on your clipboard - just paste it to them)" -ForegroundColor Green',
        '} catch { }',
        'Write-Host ""',
        'Write-Host " That code is a password. Send it privately and delete it after." -ForegroundColor Yellow',
        'Write-Host ""',
        'Write-Host "TO UNDO EVERYTHING LATER, run this as Administrator:" -ForegroundColor Cyan',
        'Write-Host "   Disable-PSRemoting -Force"',
        'Write-Host "   Remove-LocalUser -Name $acct"',
        'Write-Host "   Remove-ItemProperty -Path ''HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System'' -Name LocalAccountTokenFilterPolicy"',
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
