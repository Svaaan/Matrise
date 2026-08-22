# Matrise - Home pairing and peer messages for the workgroup case (no domain,
# no Kerberos, no AD group granting rights).
#
# Before one home PC can help another: the helped PC enables WinRM and marks its
# network Private (an elevated step it runs itself, so it is consenting); the
# helping PC lists it in TrustedHosts. Every peer message carries the sender's
# name and machine and the popup shows them - there is deliberately no way to
# send an anonymous or spoofed message.

function Get-MatriseInboxPath {
    # ProgramData when we can write there, so any account on the machine can be
    # reached; the user profile otherwise.
    $shared = Join-Path $env:ProgramData 'Matrise\Inbox'
    try {
        New-Item -ItemType Directory -Path $shared -Force -ErrorAction Stop | Out-Null
        return $shared
    } catch {
        $mine = Join-Path $env:LOCALAPPDATA 'Matrise\Inbox'
        New-Item -ItemType Directory -Path $mine -Force -ErrorAction SilentlyContinue | Out-Null
        return $mine
    }
}

function New-MatrisePeerMessage {
    param([string]$Text)
    [pscustomobject]@{
        id       = [guid]::NewGuid().ToString('N').Substring(0, 10)
        sentUtc  = (Get-Date).ToUniversalTime().ToString('o')
        fromUser = "$env:USERDOMAIN\$env:USERNAME"
        fromPc   = $env:COMPUTERNAME
        text     = $Text
    }
}

# Drops a message into the peer's inbox. Local target writes straight to disk;
# a remote one goes over the same WinRM connection the commands use.
function Send-MatrisePeerMessage {
    param($Target, [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Nothing to send.' }
    $msg  = New-MatrisePeerMessage -Text $Text
    $json = $msg | ConvertTo-Json -Depth 5
    $name = "msg-$($msg.sentUtc -replace '[:.]', '-')-$($msg.id).json"

    if (-not $Target -or $Target.Mode -eq 'local') {
        $dir = Get-MatriseInboxPath
        Set-Content -Path (Join-Path $dir $name) -Value $json -Encoding UTF8 -ErrorAction Stop
        return $msg
    }

    $icm = @{ ComputerName = $Target.Name; ErrorAction = 'Stop' }
    if ($Target.Credential) { $icm['Credential'] = $Target.Credential }
    if ($Target.UseSsl)     { $icm['UseSSL'] = $true }

    Invoke-Command @icm -ArgumentList $json, $name -ScriptBlock {
        param($j, $n)
        $dir = Join-Path $env:ProgramData 'Matrise\Inbox'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir $n) -Value $j -Encoding UTF8
        $dir
    } | Out-Null

    $msg
}

# Messages waiting on THIS machine. Reading one moves it aside so it is not
# shown twice.
function Get-MatriseInboxMessages {
    param([switch]$MarkRead)

    $dir = Get-MatriseInboxPath
    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem $dir -Filter 'msg-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try { $m = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        [void]$out.Add($m)
        if ($MarkRead) {
            try {
                $read = Join-Path $dir 'Read'
                New-Item -ItemType Directory -Path $read -Force -ErrorAction SilentlyContinue | Out-Null
                Move-Item $f.FullName (Join-Path $read $f.Name) -Force -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    $out.ToArray()
}

# Puts a message on the peer's screen even if they do not have Matrise open.
#
# A process started over WinRM lands in session 0, where nothing it draws is
# visible to the person sitting at the machine. msg.exe crosses that boundary,
# but Windows Home does not ship it - so the fallback registers a one-shot task
# that runs in the interactive session and shows the box from there.
function Send-MatriseScreenAlert {
    param($Target, [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Nothing to send.' }
    $from = "$env:USERNAME on $env:COMPUTERNAME"

    $body = {
        param($text, $from)

        # Attribution is added here, on the receiving side, so the sender
        # cannot dress the message up as coming from someone else.
        $shown = "Message from $from" + [Environment]::NewLine + [Environment]::NewLine + $text

        $msgExe = Join-Path $env:SystemRoot 'System32\msg.exe'
        if (Test-Path $msgExe) {
            & $msgExe * /TIME:180 $shown 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { return 'msg.exe' }
        }

        # Windows Home: run it in whoever is logged on right now.
        $who = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $who) { return 'nobody-logged-on' }

        $dir = Join-Path $env:ProgramData 'Matrise'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script = Join-Path $dir 'alert.ps1'

        $lines = @(
            'Add-Type -AssemblyName System.Windows.Forms',
            '$t = Get-Content -LiteralPath "$PSScriptRoot\alert.txt" -Raw',
            '[void][System.Windows.Forms.MessageBox]::Show($t, "Matrise",',
            '    [System.Windows.Forms.MessageBoxButtons]::OK,',
            '    [System.Windows.Forms.MessageBoxIcon]::Information)'
        ) -join "`r`n"
        Set-Content -Path $script -Value $lines -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'alert.txt') -Value $shown -Encoding UTF8

        $taskName = 'MatriseScreenAlert'
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
        $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 2
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        "scheduled-task as $who"
    }

    if (-not $Target -or $Target.Mode -eq 'local') {
        return (& $body $Text $from)
    }

    $icm = @{ ComputerName = $Target.Name; ErrorAction = 'Stop' }
    if ($Target.Credential) { $icm['Credential'] = $Target.Credential }
    if ($Target.UseSsl)     { $icm['UseSSL'] = $true }
    Invoke-Command @icm -ScriptBlock $body -ArgumentList $Text, $from
}

# ------------------------------------------------------------- pairing -----
# The script the person being helped runs, once, on their own PC.
function New-MatrisePairingScript {
    param([string]$HelperPc = $env:COMPUTERNAME, [string]$OutFile)

    $lines = @(
        '# Matrise - let another PC in this house help this one.',
        '#',
        "# Asked for by: $env:USERNAME on $HelperPc",
        '#',
        '# Run this ONCE, on the PC that needs help, as Administrator:',
        '#   right-click Start > Terminal (Admin) / PowerShell (Admin), then paste it.',
        '#',
        '# It does three things, all of them reversible - the undo is at the bottom.',
        '',
        '$ErrorActionPreference = ''Stop''',
        '',
        'Write-Host ""',
        'Write-Host "1. Marking this network as Private" -ForegroundColor Cyan',
        '# Remote help only works on a network Windows trusts. On Public, the',
        '# firewall blocks it - which is correct behaviour in a cafe.',
        'Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq ''Public'' } | ForEach-Object {',
        '    Write-Host "   $($_.InterfaceAlias): Public -> Private"',
        '    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private',
        '}',
        '',
        'Write-Host ""',
        'Write-Host "2. Turning on Windows remote management" -ForegroundColor Cyan',
        'Enable-PSRemoting -Force -SkipNetworkProfileCheck',
        '',
        'Write-Host ""',
        'Write-Host "3. Details the other PC needs" -ForegroundColor Cyan',
        '$ips = (Get-NetIPAddress -AddressFamily IPv4 |',
        '        Where-Object { $_.IPAddress -notlike ''127.*'' -and $_.IPAddress -notlike ''169.254.*'' }).IPAddress',
        'Write-Host ""',
        'Write-Host "   Computer name : $env:COMPUTERNAME" -ForegroundColor Green',
        'Write-Host "   IP address    : $($ips -join '', '')" -ForegroundColor Green',
        'Write-Host "   Your username : $env:USERNAME" -ForegroundColor Green',
        'Write-Host ""',
        'Write-Host "   The other PC will ask for that username and your Windows password."',
        'Write-Host "   If you sign in with a Microsoft account, the username is usually"',
        'Write-Host "   your email address, and the password is the one you type at startup."',
        'Write-Host ""',
        'Write-Host "TO UNDO ALL OF THIS LATER, run:" -ForegroundColor Yellow',
        'Write-Host "   Disable-PSRemoting -Force"',
        'Write-Host "   Stop-Service WinRM; Set-Service WinRM -StartupType Disabled"',
        'Write-Host ""',
        'Read-Host "Press Enter to close"'
    ) -join "`r`n"

    if ($OutFile) {
        [System.IO.File]::WriteAllText($OutFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    $lines
}

# The other half, run on the helping PC. Needs admin because TrustedHosts is a
# machine-wide setting.
# Reading WSMan:\ when the WinRM service is stopped does not fail fast - it sits
# there trying to reach a service that is not listening, and takes the whole UI
# thread down with it. Ask the service control manager first; that answers in
# milliseconds and never blocks.
function Test-MatriseWinRmRunning {
    try { return ((Get-Service WinRM -ErrorAction Stop).Status -eq 'Running') } catch { return $false }
}

function Add-MatriseTrustedHost {
    param([Parameter(Mandatory)] [string]$Name)

    # TrustedHosts is compared as TEXT against whatever you type as the target.
    # A name here does not cover that machine's IP, and an IP does not cover its
    # name, so accept several at once and let people add both.
    $wanted = @($Name -split '[,;\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    foreach ($w in $wanted) {
        if ($w -eq '*' -or $w.Contains('*')) {
            throw ("'*' would tell Windows to send your password to ANY machine that answers, " +
                   "including one pretending to be hers. Add the specific computer name or IP instead.")
        }
    }
    if (-not $wanted) { throw 'Nothing to add.' }

    if (-not (Test-MatriseElevated)) {
        throw "Adding '$Name' to TrustedHosts needs Administrator. Restart Matrise with Matrise.bat and try again."
    }

    $started = ''
    if (-not (Test-MatriseWinRmRunning)) {
        # The trusted list lives in WinRM's own configuration, so the service
        # has to be running to edit it.
        #
        # Do NOT tell the user this is "client side only". Windows frequently
        # ships with a listener already configured but dormant, and starting
        # the service activates it - so this PC can begin accepting inbound
        # remote management as a side effect. Check what actually happened and
        # report that, instead of reassuring them about something unverified.
        # The startup type is deliberately left alone: making it Automatic is a
        # permanent change nobody asked for.
        try {
            Start-Service WinRM -ErrorAction Stop
            $ports = @(Get-NetTCPConnection -LocalPort 5985, 5986 -State Listen -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty LocalPort -Unique)
            if ($ports) {
                $started = "Started Windows Remote Management. NOTE: this PC is now ALSO accepting inbound " +
                           "connections on port $($ports -join '/') - Windows already had a listener configured " +
                           "and starting the service activated it. To close it again: Disable-PSRemoting -Force " +
                           "then Stop-Service WinRM. "
            } else {
                $started = "Started Windows Remote Management (outbound only - nothing is listening for inbound connections). "
            }
        }
        catch {
            throw ("The Windows Remote Management service could not be started, so the trusted list cannot be edited.`
`n`
`n" +
                   $_.Exception.Message)
        }
    }

    $path = 'WSMan:\localhost\Client\TrustedHosts'
    $current = ''
    try { $current = (Get-Item $path -ErrorAction Stop).Value } catch { }

    $have  = @($current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $added = @()
    $dup   = @()
    foreach ($w in $wanted) {
        if ($have -contains $w) { $dup += $w } else { $have += $w; $added += $w }
    }

    if (-not $added) { return "Already trusted: $($dup -join ', '). Nothing changed." }

    $new = ($have -join ',')
    Set-Item $path -Value $new -Force

    $msg = "$started" + "Added $($added -join ', ')."
    if ($dup) { $msg += " (already there: $($dup -join ', '))" }
    "$msg`r`n`r`nTrustedHosts is now: $new"
}

# Returns $null when the answer is genuinely unknown (service stopped), so the
# caller can say so instead of showing a misleading "(none)".
function Get-MatriseTrustedHosts {
    if (-not (Test-MatriseWinRmRunning)) { return $null }
    try { (Get-Item 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value } catch { '' }
}
