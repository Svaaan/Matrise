# Matrise - One-code pairing (fallback for when the Guest/Host buttons are not
# usable). They run one script, it prints one code, you paste it; Matrise fills
# in the machine, trusts it, and stores the credential.
#
# Something must run once, as Administrator, on their machine - Windows will not
# let a remote PC enable its own remote management, and that step IS the consent.
# The code is a password (Base64 is not encryption): send it privately, delete
# it after.

$script:MatriseHelperAccount = 'MatriseHelp'

# Windows caps a local account description at 48 characters and New-LocalUser
# throws rather than truncating, which kills the whole setup at its first step.
# Defined once so the generated script and the Host button cannot drift apart
# or past the limit.
$script:MatriseHelperDesc = 'Matrise remote help - safe to delete'

# Granting the rights is the step that decides whether the other PC can connect
# at all, so it is never silenced and always verified afterwards.
#
# Group names are LOCALISED. On a Swedish Windows the administrators group is
# "Administratorer", on a German one "Administratoren" - asking for
# "Administrators" by name simply fails there. Well-known SIDs are identical on
# every installation, so that is what this uses.
function Grant-MatriseHelperRights {
    param([Parameter(Mandatory)] [string]$Account)

    $steps = New-Object System.Collections.ArrayList
    $add = { param($ok, $t) [void]$steps.Add([pscustomobject]@{ Ok = $ok; Text = $t }) }

    $wanted = @(
        @{ Sid = 'S-1-5-32-544'; What = 'Administrators' },
        @{ Sid = 'S-1-5-32-580'; What = 'Remote Management Users' }
    )

    foreach ($w in $wanted) {
        $g = $null
        try { $g = Get-LocalGroup -SID $w.Sid -ErrorAction Stop } catch { }
        if (-not $g) {
            & $add $false "the $($w.What) group does not exist on this PC ($($w.Sid))"
            continue
        }

        $already = $false
        try {
            $already = @(Get-LocalGroupMember -Group $g -ErrorAction Stop |
                         Where-Object { $_.Name -like "*\$Account" -or $_.Name -eq $Account }).Count -gt 0
        } catch { }

        if ($already) { & $add $true "already in $($g.Name)"; continue }
        try {
            Add-LocalGroupMember -Group $g -Member $Account -ErrorAction Stop
            & $add $true "added to $($g.Name)"
        }
        catch {
            & $add $false "could not add to $($g.Name): $($_.Exception.Message)"
        }
    }

    # Verify rather than assume. Administrators membership is what WinRM checks.
    $isAdmin = $false
    try {
        $ga = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
        $isAdmin = @(Get-LocalGroupMember -Group $ga -ErrorAction Stop |
                     Where-Object { $_.Name -like "*\$Account" -or $_.Name -eq $Account }).Count -gt 0
    } catch { }
    if ($isAdmin) { & $add $true "VERIFIED: $Account is an administrator" }
    else          { & $add $false "VERIFY FAILED: $Account is NOT an administrator - the other PC will be refused" }

    try {
        $u = Get-LocalUser -Name $Account -ErrorAction Stop
        if (-not $u.Enabled) {
            Enable-LocalUser -Name $Account -ErrorAction Stop
            & $add $true 'the account was disabled - enabled it'
        } else {
            & $add $true 'the account is enabled'
        }
    }
    catch { & $add $false "could not confirm the account is enabled: $($_.Exception.Message)" }

    [pscustomobject]@{ Ok = $isAdmin; Steps = $steps }
}

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

# Pushes the whole host-side setup onto a machine you are ALREADY connected to,
# over the existing WinRM channel - no script to send, nothing to paste. Used
# to repair or refresh a peer from your side: rotates the helper account's
# password, re-grants rights by SID, re-enables remoting, resets the token
# policy. The new password is generated on the far end and returned encrypted
# by WinRM, then saved locally so the next connect just works.
#
# It cannot bootstrap a machine with no connection - that first step must be run
# there, with consent. This is for machines already paired.
function Push-MatriseHostSetup {
    param($Target, [string]$Account = 'MatriseHelp')

    if (-not $Target -or $Target.Mode -ne 'remote') {
        throw 'This refreshes a REMOTE machine. Point Matrise at one and connect first.'
    }

    # Self-contained: the far end has stock PowerShell only, so everything the
    # setup needs is inside this block.
    $sb = {
        param($acct, $desc)
        $steps = New-Object System.Collections.ArrayList
        $add = { param($ok, $t) [void]$steps.Add([pscustomobject]@{ Ok = $ok; Text = $t }) }

        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+-'
        $bytes = New-Object byte[] 24
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $plain = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
        $sec = ConvertTo-SecureString $plain -AsPlainText -Force

        try {
            if (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue) {
                Set-LocalUser -Name $acct -Password $sec
                Enable-LocalUser -Name $acct -ErrorAction SilentlyContinue
                & $add $true "refreshed $acct with a new password"
            } else {
                New-LocalUser -Name $acct -Password $sec -FullName 'Matrise remote help' `
                    -Description $desc -PasswordNeverExpires -AccountNeverExpires | Out-Null
                & $add $true "created $acct"
            }
        }
        catch { & $add $false "account: $($_.Exception.Message)"; return @{ Ok=$false; Steps=$steps; Password='' } }

        foreach ($sid in @('S-1-5-32-544', 'S-1-5-32-580')) {
            $g = $null
            try { $g = Get-LocalGroup -SID $sid -ErrorAction Stop } catch { }
            if (-not $g) { continue }
            try { Add-LocalGroupMember -Group $g -Member $acct -ErrorAction Stop; & $add $true "added to $($g.Name)" }
            catch { & $add $true "already in $($g.Name)" }
        }
        $ga = Get-LocalGroup -SID 'S-1-5-32-544'
        $isAdmin = @(Get-LocalGroupMember -Group $ga | Where-Object { $_.Name -like "*\$acct" }).Count -gt 0
        if (-not $isAdmin) { & $add $false "$acct is NOT an administrator"; return @{ Ok=$false; Steps=$steps; Password='' } }
        & $add $true "$acct is an administrator"

        try {
            $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            New-ItemProperty -Path $k -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
            & $add $true 'remote-administration policy set'
        } catch { & $add $false "token policy: $($_.Exception.Message)" }

        try { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null; & $add $true 'remote management on' }
        catch { & $add $true 'remote management already on' }

        @{ Ok = $true; Steps = $steps; Password = $plain }
    }

    $icm = @{ ComputerName = $Target.Name; ErrorAction = 'Stop'; ScriptBlock = $sb
             ArgumentList = @($Account, $script:MatriseHelperDesc) }
    if ($Target.Credential) { $icm['Credential'] = $Target.Credential; $icm['Authentication'] = 'Negotiate' }
    if ($Target.UseSsl)     { $icm['UseSSL'] = $true }

    $r = Invoke-Command @icm

    if ($r.Ok -and $r.Password) {
        $sec  = ConvertTo-SecureString ([string]$r.Password) -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$($Target.Name)\$Account", $sec)
        [void](Save-MatrisePeerCredential -HostName $Target.Name -Credential $cred)
        $Target.Credential = $cred   # keep the live session using the new password
    }
    [pscustomobject]@{ Ok = [bool]$r.Ok; Steps = @($r.Steps) }
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
        '# Group names are localised - "Administrators" does not exist on a',
        '# Swedish or German Windows. Well-known SIDs are the same everywhere.',
        '$granted = $false',
        'foreach ($sid in @("S-1-5-32-544", "S-1-5-32-580")) {',
        '    $g = $null',
        '    try { $g = Get-LocalGroup -SID $sid -ErrorAction Stop } catch { }',
        '    if (-not $g) { Write-Host "   group $sid not present - skipping" -ForegroundColor Yellow; continue }',
        '    try {',
        '        Add-LocalGroupMember -Group $g -Member $acct -ErrorAction Stop',
        '        Write-Host "   added to $($g.Name)"',
        '    } catch {',
        '        Write-Host "   already in or could not add to $($g.Name)"',
        '    }',
        '}',
        '$ga = Get-LocalGroup -SID "S-1-5-32-544"',
        '$granted = @(Get-LocalGroupMember -Group $ga | Where-Object { $_.Name -like "*\\$acct" }).Count -gt 0',
        'if ($granted) {',
        '    Write-Host "   verified: $acct is an administrator" -ForegroundColor Green',
        '} else {',
        '    Write-Host "   PROBLEM: $acct is NOT an administrator." -ForegroundColor Red',
        '    Write-Host "   The other PC will be refused. Stopping." -ForegroundColor Red',
        '    Read-Host "Press Enter to close"',
        '    return',
        '}',
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
