# Matrise - Targeting
#
# Runs the catalog against another machine on the internal network, by hostname
# or IP, instead of against this one.
#
# Transport is PowerShell Remoting (WinRM). That is deliberate:
#   - it is already present and managed in every AD environment
#   - it authenticates as the operator, through Kerberos, against the endpoint
#   - it is the transport JEA constrains, so the same connection can be locked
#     down to exactly the commands Security allows (see Jea.ps1)
#
# No agent to install, no listener of our own, nothing that has to be allowed
# through application control.

function New-MatriseTarget {
    param(
        [string]$Name = 'localhost',
        [System.Management.Automation.PSCredential]$Credential = $null,
        [switch]$UseSsl,
        [string]$ConfigurationName = '',
        # Normally this machine's own name means "run locally". ForceRemote
        # sends it round the WinRM loop anyway, which is the only way to prove
        # the remote path works without a second computer.
        [switch]$ForceRemote
    )

    $n = $Name.Trim()
    if (-not $n) { $n = 'localhost' }
    $isLocal = (-not $ForceRemote) -and ($n -in @('localhost', '.', '127.0.0.1', '::1', $env:COMPUTERNAME))

    $ipOut = [ref]([ipaddress]::None)
    $isIp  = [ipaddress]::TryParse($n, $ipOut)

    [pscustomobject]@{
        Mode        = $(if ($isLocal) { 'local' } else { 'remote' })
        Name        = $n
        IsIpLiteral = [bool]$isIp
        Credential  = $Credential
        UseSsl      = [bool]$UseSsl
        Port        = $(if ($UseSsl) { 5986 } else { 5985 })
        ConfigName  = $ConfigurationName
        Status      = 'unknown'
        Detail      = ''
        Resolved    = ''
        CheckedAt   = $null
    }
}

function Get-MatriseTargetLabel {
    param($Target)
    if (-not $Target -or $Target.Mode -eq 'local') { return "$env:COMPUTERNAME (this PC)" }
    $who = $(if ($Target.Credential) { $Target.Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" })
    "$($Target.Name) as $who"
}

# Walks the chain a remote connection actually depends on, in order, and stops
# at the first thing that is broken. Each failure carries the fix, because
# "connection failed" on its own costs an afternoon.
function Test-MatriseTarget {
    param($Target, [int]$TimeoutSec = 8)

    $report = New-Object System.Collections.ArrayList
    $add = { param($ok, $step, $detail) [void]$report.Add([pscustomobject]@{ Ok = $ok; Step = $step; Detail = $detail }) }

    if ($Target.Mode -eq 'local') {
        & $add $true 'target' 'Local machine - nothing to connect to.'
        $Target.Status = 'ok'
        $Target.Detail = 'local'
        $Target.CheckedAt = Get-Date
        return $report.ToArray()
    }

    # --- name resolution --------------------------------------------------
    if ($Target.IsIpLiteral) {
        $Target.Resolved = $Target.Name
        & $add $true 'resolve' "IP literal, no DNS lookup needed: $($Target.Name)"
        if (-not $Target.UseSsl -and -not $Target.Credential) {
            & $add $false 'kerberos' (@(
                'Connecting to a bare IP cannot use Kerberos, so WinRM falls back to NTLM.',
                'That needs either an explicit credential, HTTPS, or the IP listed in the',
                'client TrustedHosts. Easiest fix: use the hostname instead. If you only',
                'have the IP, supply a credential with the "Run as..." button.'
            ) -join ' ')
        }
    }
    else {
        try {
            $entry = [System.Net.Dns]::GetHostEntry($Target.Name)
            $Target.Resolved = ($entry.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                                Select-Object -First 1).IPAddressToString
            if (-not $Target.Resolved) { $Target.Resolved = $entry.AddressList[0].IPAddressToString }
            & $add $true 'resolve' "$($entry.HostName) -> $($Target.Resolved)"
        }
        catch {
            & $add $false 'resolve' (@(
                "DNS cannot resolve '$($Target.Name)'.",
                'Check the spelling, check you are on the corporate network or VPN, and',
                'try the fully qualified name (host.corp.example.com).'
            ) -join ' ')
            $Target.Status = 'unresolved'
            $Target.CheckedAt = Get-Date
            return $report.ToArray()
        }
    }

    # --- WinRM port -------------------------------------------------------
    $portOpen = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($Target.Resolved, $Target.Port, $null, $null)
        $portOpen = $iar.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSec))
        if ($portOpen) { $tcp.EndConnect($iar) }
        $tcp.Close()
    } catch { $portOpen = $false }

    if ($portOpen) {
        & $add $true 'winrm-port' "TCP $($Target.Port) is open."
    } else {
        & $add $false 'winrm-port' (@(
            "Nothing is listening on TCP $($Target.Port).",
            'Either the machine is off, a firewall is in the way, or WinRM is not enabled.',
            'WinRM is normally switched on by Group Policy; if this one machine is the',
            'exception, it is a policy or imaging problem worth reporting rather than',
            'something to fix by hand.'
        ) -join ' ')
        $Target.Status = 'no-winrm'
        $Target.CheckedAt = Get-Date
        return $report.ToArray()
    }

    # --- WinRM handshake + authentication ---------------------------------
    try {
        $p = @{ ComputerName = $Target.Name; ErrorAction = 'Stop' }
        if ($Target.Credential) {
            $p['Credential'] = $Target.Credential
            # Test-WSMan defaults -Authentication to None, and None plus a
            # credential is a hard error rather than a fallback. Negotiate is
            # what actually gets used between PCs that are not in a domain.
            $p['Authentication'] = 'Negotiate'
        }
        if ($Target.UseSsl) { $p['UseSSL'] = $true }
        Test-WSMan @p | Out-Null
        & $add $true 'winrm-auth' 'WinRM responded and accepted the credentials.'
        $Target.Status = 'ok'
    }
    catch {
        $m = $_.Exception.Message
        $hint = 'WinRM refused the connection.'
        if ($m -match 'Access is denied') {
            $hint = @(
                'Access denied. Your account is not a local administrator (or Remote',
                'Management User) on that machine. In a managed environment that comes',
                'from an AD group - ask for the endpoint support group rather than a',
                'local account.'
            ) -join ' '
        }
        elseif ($m -match 'TrustedHosts|Kerberos|cannot process the request') {
            $hint = @(
                'Authentication could not complete. Connecting by IP, or to a machine',
                'outside the domain, needs HTTPS or a TrustedHosts entry. Try the',
                'hostname first - it is almost always the real fix.'
            ) -join ' '
        }
        & $add $false 'winrm-auth' ("$hint`n`nWinRM said: $m")
        $Target.Status = 'denied'
    }

    $Target.Detail = ($report | Where-Object { -not $_.Ok } | Select-Object -First 1).Detail
    $Target.CheckedAt = Get-Date
    $report.ToArray()
}

function Format-MatriseTargetReport {
    param($Report, $Target)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('================================================================')
    [void]$sb.AppendLine("  CONNECTION CHECK: $($Target.Name)")
    [void]$sb.AppendLine('================================================================')
    foreach ($r in $Report) {
        $mark = $(if ($r.Ok) { 'OK  ' } else { 'FAIL' })
        [void]$sb.AppendLine("[$mark] $($r.Step)")
        foreach ($line in ($r.Detail -split "`r?`n")) {
            [void]$sb.AppendLine("       $line")
        }
    }
    [void]$sb.AppendLine("  result: $($Target.Status)")
    $sb.ToString()
}

# The literal thing that will be executed on the far end, shown in the UI and
# written into the audit log before anything runs.
function Get-MatriseRemoteCommandLine {
    param($Entry, $Target)
    if (-not $Target -or $Target.Mode -eq 'local') { return (Get-MatriseCommandLine -Entry $Entry) }

    $inner = $(if ($Entry.Shell -eq 'cmd') { "cmd.exe /d /c $($Entry.Command)" } else { '<PowerShell body below>' })
    $cfg = $(if ($Target.ConfigName) { " -ConfigurationName $($Target.ConfigName)" } else { '' })
    "Invoke-Command -ComputerName $($Target.Name)$cfg -ScriptBlock { $inner }"
}
