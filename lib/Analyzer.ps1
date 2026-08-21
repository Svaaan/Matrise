# Matrise - Local analysis engine
#
# Reads whatever is on the board (command output, or text you pasted from the
# clipboard) and flags things worth a second look. Runs entirely offline.
#
# Every rule carries a Why: a finding you cannot act on is just noise.

function New-MatriseRule {
    param(
        [string]$Id,
        [string]$Severity,   # Critical | High | Medium | Low | Info
        [string]$Title,
        [string]$Pattern,
        [string]$Why,
        [int]$MaxHits = 40,
        # Aggregate collapses a repetitive rule into one finding with a count,
        # so thirty identical failed-logon lines do not bury everything else.
        [switch]$Aggregate
    )
    [pscustomobject]@{
        Id       = $Id
        Severity = $Severity
        Title    = $Title
        Regex    = [regex]::new($Pattern, ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                                           [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                                           [System.Text.RegularExpressions.RegexOptions]::Multiline))
        Why       = $Why
        MaxHits   = $MaxHits
        Aggregate = [bool]$Aggregate
    }
}

function Get-MatriseSeverityRank {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { 0 }
        'High'     { 1 }
        'Medium'   { 2 }
        'Low'      { 3 }
        default    { 4 }
    }
}

$script:MatriseRules = $null

function Get-MatriseRules {
    if ($script:MatriseRules) { return $script:MatriseRules }

    $r = New-Object System.Collections.ArrayList
    $a = { param($x) [void]$r.Add($x) }

    # ---------- Execution / living-off-the-land ----------
    & $a (New-MatriseRule -Id 'enc-powershell' -Severity 'Critical' `
        -Title 'Base64-encoded PowerShell command' `
        -Pattern '(?:powershell|pwsh)[^\r\n]{0,200}?[ \t]-(?:e|en|enc|ec|encodedcommand)[ \t]+[A-Za-z0-9+/=]{20,}' `
        -Why 'Legitimate software almost never launches PowerShell with an encoded command. This is the single most common way malware hides what it is doing. Decode the Base64 to see the real script before you do anything else.')

    & $a (New-MatriseRule -Id 'ps-hidden' -Severity 'High' `
        -Title 'PowerShell launched hidden with profile bypass' `
        -Pattern '(?:powershell|pwsh)[^\r\n]{0,200}?(?:-w(?:indowstyle)?[ \t]+hidden|-nop\b|-noprofile\b[^\r\n]{0,80}-ep[ \t]+bypass)' `
        -Why 'A hidden, profile-less PowerShell window is how malware runs without you seeing it. Check what script it executes and which parent process started it.')

    & $a (New-MatriseRule -Id 'iex-download' -Severity 'Critical' `
        -Title 'Downloads and executes code straight from the internet' `
        -Pattern '(?:IEX|Invoke-Expression|DownloadString|DownloadFile|Net\.WebClient|Invoke-WebRequest[^\r\n]{0,60}\|\s*iex)' `
        -Why 'Code is being pulled from a URL and run in memory, never touching disk, so antivirus never sees a file. Find the URL in the command line and treat it as hostile.')

    & $a (New-MatriseRule -Id 'certutil-download' -Severity 'High' `
        -Title 'certutil used as a downloader' `
        -Pattern 'certutil[^\r\n]{0,120}(?:-urlcache|-decode|-f\s+-split)' `
        -Why 'certutil is a certificate tool, not a download tool. Attackers use it to fetch payloads past filters that only watch browsers. Look at the URL or file it is operating on.')

    & $a (New-MatriseRule -Id 'lolbin-remote' -Severity 'High' `
        -Title 'Windows tool fetching remote content' `
        -Pattern '(?:mshta|regsvr32|rundll32|bitsadmin|wmic)[^\r\n]{0,150}(?:https?://|\\\\[^\r\n\\]+\\)' `
        -Why 'These built-in tools are being pointed at a remote address. That is a signed-binary proxy execution technique: Windows own executable runs the attackers code, so it looks trusted.')

    & $a (New-MatriseRule -Id 'script-in-temp' -Severity 'High' `
        -Title 'Script or executable running from a temp folder' `
        -Pattern '[A-Za-z]:\\[^\r\n"]{0,200}?\\(?:Temp|Tmp)\\[^\r\n"]{0,120}\.(?:exe|dll|ps1|bat|cmd|vbs|js|hta|scr|jar)\b' `
        -Why 'Installed software lives in Program Files. Anything executing from a Temp folder either just arrived, or is deliberately staying somewhere that gets wiped. Fingerprint the file before deleting it.')

    & $a (New-MatriseRule -Id 'exe-in-appdata' -Severity 'Medium' `
        -Title 'Executable running from AppData or ProgramData' `
        -Pattern '[A-Za-z]:\\[^\r\n"]{0,200}?\\(?:AppData|ProgramData)\\(?![^\r\n"]{0,140}\\Te?mp\\)[^\r\n"]{0,140}\.(?:exe|dll|scr|com)\b' `
        -Why 'Some legitimate apps do this (Teams, Discord, Spotify, Chrome updaters). Anything you do not recognise by name is worth fingerprinting, because it is also where malware installs to avoid needing admin rights.')

    & $a (New-MatriseRule -Id 'double-extension' -Severity 'High' `
        -Title 'Double file extension' `
        -Pattern '[^\r\n\\/:*?"<>|]{1,80}\.(?:pdf|doc|docx|xls|xlsx|jpg|png|txt|zip)\.(?:exe|scr|bat|cmd|com|pif|vbs|js|hta)\b' `
        -Why 'A file named like "invoice.pdf.exe" is a program pretending to be a document. Windows hides the real extension by default, which is exactly what this relies on.')

    # ---------- Persistence ----------
    & $a (New-MatriseRule -Id 'winlogon-shell' -Severity 'Critical' `
        -Title 'Winlogon Shell or Userinit has been changed' `
        -Pattern '^(?>[ \t]*)(?:Shell|Userinit)(?>[ \t]*):(?>[ \t]*)(?!explorer\.exe[ \t]*$)(?!C:\\Windows\\system32\\userinit\.exe,?[ \t]*$)\S.*$' `
        -Why 'Shell must be exactly explorer.exe and Userinit must be userinit.exe. Anything appended here runs at every single logon with your full rights. This is a serious persistence finding.')

    & $a (New-MatriseRule -Id 'run-key-script' -Severity 'High' `
        -Title 'Autorun entry pointing at a script or temp path' `
        -Pattern '^[ \t]{2,}\S[^\r\n]{0,60}?[ \t]{2,}[^\r\n]{0,200}?(?:\\Temp\\|\\AppData\\|\.vbs|\.js|\.hta|\.bat|\.cmd|\.ps1)[^\r\n]{0,80}$' `
        -Why 'Run keys start this at every logon. Legitimate entries point at installed programs, not at loose scripts or temp folders. Note the name so you can remove it from Task Manager > Startup.' -MaxHits 25)

    & $a (New-MatriseRule -Id 'wmi-consumer' -Severity 'High' `
        -Title 'WMI permanent event consumer present' `
        -Pattern '(?:ActiveScriptEventConsumer|CommandLineEventConsumer)' `
        -Why 'WMI event subscriptions are fileless persistence: they survive reboots and most cleanup tools never look here. A few enterprise management suites use them, but on a home machine this is almost always malicious.')

    & $a (New-MatriseRule -Id 'service-odd-path' -Severity 'High' `
        -Title 'Service running from a user-writable folder' `
        -Pattern '^[^\r\n]{0,80}(?:Running|Stopped|Auto)[^\r\n]{0,60}[A-Za-z]:\\(?:Users|ProgramData|Windows\\Temp)\\[^\r\n]{0,200}$' `
        -Why 'Services run as SYSTEM. One whose binary sits in a folder you can write to means anyone who compromises your account gets SYSTEM. Malicious or just badly written, it needs attention.')

    # ---------- Defensive controls turned off ----------
    & $a (New-MatriseRule -Id 'rtp-off' -Severity 'Critical' `
        -Title 'Defender real-time protection is OFF' `
        -Pattern '(?:RealTimeProtectionEnabled|AntivirusEnabled|BehaviorMonitorEnabled|AMServiceEnabled)[ \t]*:[ \t]*False' `
        -Why 'Your antivirus is not watching. Either another AV product took over (check that first), or something disabled it deliberately, which is a standard first step for malware. Turn it back on from Computer > Fix.')

    & $a (New-MatriseRule -Id 'rtp-disabled-pref' -Severity 'Critical' `
        -Title 'Defender explicitly disabled by policy' `
        -Pattern 'DisableRealtimeMonitoring[ \t]*:[ \t]*True' `
        -Why 'Somebody set this on purpose. If it was not you or your IT department, treat the machine as compromised and scan from a rescue USB.')

    & $a (New-MatriseRule -Id 'defender-exclusion' -Severity 'High' `
        -Title 'Defender exclusion paths configured' `
        -Pattern '^Exclusion(?:Path|Process|Extension)[ \t]*:[ \t]*\S[^\r\n]*$' `
        -Why 'An exclusion tells Defender to ignore a folder entirely. Adding one is a favourite malware move, and it is also what game cracks and mining software ask you to do. Verify every path listed is one you knowingly approved.')

    & $a (New-MatriseRule -Id 'firewall-off' -Severity 'High' `
        -Title 'Firewall profile is OFF' `
        -Pattern '^[ \t]*State[ \t]+OFF[ \t]*$' `
        -Why 'This network profile accepts anything that reaches it. On a public or shared network that is a direct exposure. Turn it on from Network > Fix.')

    & $a (New-MatriseRule -Id 'sig-old' -Severity 'Medium' `
        -Title 'Antivirus signatures may be stale' `
        -Pattern 'AntivirusSignatureLastUpdated[ \t]*:[ \t]*[^\r\n]+' `
        -Why 'Check this date against today. More than about a week old means updates are failing, and Defender is missing everything discovered since then.' -MaxHits 3)

    # ---------- Network exposure ----------
    & $a (New-MatriseRule -Id 'rdp-open' -Severity 'High' `
        -Title 'Remote Desktop is enabled' `
        -Pattern 'fDenyTSConnections[ \t]*[:=]?[ \t]*(?:0x0\b|0[ \t]*$)' `
        -Why 'RDP is on. If this machine is reachable from the internet it will be brute-forced within hours; RDP is the number one ransomware entry point. Turn it off unless you actively use it.')

    & $a (New-MatriseRule -Id 'backdoor-port' -Severity 'Critical' `
        -Title 'Listening on a known backdoor / RAT port' `
        -Pattern '(?::|\s)(?:4444|4445|5555|6666|1337|31337|12345|54321|9001|8081|1080)\b[^\r\n]{0,40}(?:LISTEN|Listen)' `
        -Why 'These ports are the defaults for Metasploit, common remote-access trojans and SOCKS proxies. Find the owning process and fingerprint its binary before doing anything else.')

    & $a (New-MatriseRule -Id 'remote-access-port' -Severity 'Medium' `
        -Title 'Remote-control service listening' `
        -Pattern '(?::|\s)(?:3389|5900|5938|6568|7070|23)\b[^\r\n]{0,40}(?:LISTEN|Listen)' `
        -Why 'RDP (3389), VNC (5900), TeamViewer (5938) or Telnet (23) is accepting connections. Fine if you set it up on purpose. Alarming if you did not.')

    & $a (New-MatriseRule -Id 'smb-listen' -Severity 'Low' `
        -Title 'File sharing (SMB) is listening' `
        -Pattern '(?::|\s)(?:445|139)\b[^\r\n]{0,40}(?:LISTEN|Listen)' `
        -Why 'Normal on a home or office LAN. Only a problem if this machine faces the internet directly, where SMB should never be exposed.' -MaxHits 6)

    & $a (New-MatriseRule -Id 'hosts-hijack' -Severity 'High' `
        -Title 'HOSTS file redirects a hostname' `
        -Pattern '^(?>[ \t]*)(?!#)(?!127\.0\.0\.1[ \t]+localhost[ \t]*$)(?:\d{1,3}\.){3}\d{1,3}(?>[ \t]+)(?![0-9a-fA-F]{2}[-:])[A-Za-z0-9_*-]+(?:\.[A-Za-z0-9_*-]+)*[ \t]*$' `
        -Why 'Something is overriding DNS on this machine. Blocking antivirus update domains this way is standard for cracked software and malware. Restore the clean HOSTS file from Network > Fix.')

    & $a (New-MatriseRule -Id 'proxy-set' -Severity 'High' `
        -Title 'A proxy or auto-config URL is configured' `
        -Pattern '(?:ProxyEnable[ \t]*(?:REG_DWORD)?[ \t]*(?::|=)?[ \t]*0x1|AutoConfigURL[ \t]*(?:REG_SZ)?[ \t]*(?::|=)?[ \t]*\S+|Proxy Server\(s\)[ \t]*:[ \t]*\S+)' `
        -Why 'All your web traffic is being routed through a middleman that can read and rewrite it. Unless your workplace set this, clear it from Network > Fix.')

    & $a (New-MatriseRule -Id 'dns-unusual' -Severity 'Medium' `
        -Title 'Unusual DNS server configured' `
        -Pattern 'DNS Servers[^\r\n]{0,40}:[ \t]*(?!192\.168\.|10\.|172\.(?:1[6-9]|2\d|3[01])\.|127\.|8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9|208\.67\.)(?:\d{1,3}\.){3}\d{1,3}' `
        -Why 'Your DNS is not your router and not a well-known public resolver. Whoever runs that server decides where every domain you visit actually points. Compare results using the DNS hijack check.')

    # ---------- Accounts ----------
    & $a (New-MatriseRule -Id 'guest-enabled' -Severity 'Medium' `
        -Title 'Guest or DefaultAccount is enabled' `
        -Pattern '^[ \t]*(?:Guest|DefaultAccount)[ \t]+True\b' `
        -Why 'These accounts ship disabled for good reason. An enabled Guest account is a login with no password.')

    & $a (New-MatriseRule -Id 'failed-logons' -Severity 'Medium' `
        -Title 'Failed logon attempts recorded' `
        -Pattern 'An account failed to log on' `
        -Why 'A handful is you mistyping a password. Dozens in a short window, especially from a network address, means someone is guessing credentials against this machine.' -MaxHits 200 -Aggregate)

    # ---------- File integrity ----------
    & $a (New-MatriseRule -Id 'sfc-corrupt' -Severity 'High' `
        -Title 'Corrupt system files found' `
        -Pattern 'found corrupt files|integrity violations|could not perform the requested operation' `
        -Why 'Windows protected files do not match their known-good hashes. Usually failing storage or a bad update, occasionally a rootkit. Run DISM RestoreHealth, then SFC again.')

    & $a (New-MatriseRule -Id 'unsigned-binary' -Severity 'Medium' `
        -Title 'Unsigned or invalidly signed binary' `
        -Pattern '^[ \t]*(?:NotSigned|HashMismatch|UnknownError|NotTrusted)\b' `
        -Why 'Real software is code-signed. HashMismatch is the serious one: the file was modified after it was signed. NotSigned is common for small open-source tools and self-built binaries, so judge it by the path.' -MaxHits 60)

    & $a (New-MatriseRule -Id 'disk-unhealthy' -Severity 'Critical' `
        -Title 'Disk reporting an unhealthy state' `
        -Pattern 'HealthStatus[ \t]*:?[ \t]*(?:Unhealthy|Warning)|OperationalStatus[ \t]*:?[ \t]*(?:Degraded|Failed)|Pred[ \t]*Fail' `
        -Why 'The drive is telling you it is dying. Back up now, before you troubleshoot anything else. Every other symptom on this machine may be a consequence of this.')

    & $a (New-MatriseRule -Id 'bugcheck' -Severity 'Medium' `
        -Title 'Unexpected shutdown or blue screen' `
        -Pattern 'The system has rebooted without cleanly shutting down|BugCheck|previous system shutdown at' `
        -Why 'The machine crashed rather than shut down. Repeated occurrences point at failing RAM, a bad driver, or overheating.' -MaxHits 200 -Aggregate)

    $script:MatriseRules = $r
    $r
}

# Map a character offset in the text back to a 1-based line number.
function Get-MatriseLineIndex {
    param([string]$Text)
    $offsets = New-Object System.Collections.Generic.List[int]
    $offsets.Add(0)
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") { $offsets.Add($i + 1) }
    }
    $offsets
}

function Resolve-MatriseLineNumber {
    param($Offsets, [int]$Position)
    $lo = 0; $hi = $Offsets.Count - 1
    while ($lo -lt $hi) {
        $mid = [int](($lo + $hi + 1) / 2)
        if ($Offsets[$mid] -le $Position) { $lo = $mid } else { $hi = $mid - 1 }
    }
    $lo + 1
}

function Invoke-MatriseAnalysis {
    param(
        [string]$Text,
        [int]$MaxFindings = 400
    )

    $findings = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return $findings }

    # Normalise line endings first: a stray \r sitting before every $ silently
    # breaks end-of-line anchors in half the rules. Line numbers are unaffected.
    $norm    = $Text -replace "`r`n", "`n"
    $offsets = Get-MatriseLineIndex -Text $norm
    $lines   = $norm -split "`n"
    $seen    = @{}

    foreach ($rule in Get-MatriseRules) {
        # $mlist, not $matches: $matches is a PowerShell automatic variable.
        $mlist = @($rule.Regex.Matches($norm))
        if ($mlist.Count -eq 0) { continue }

        if ($rule.Aggregate -and $mlist.Count -gt 1) {
            $ln = Resolve-MatriseLineNumber -Offsets $offsets -Position $mlist[0].Index
            $ev = ''
            if ($ln -le $lines.Count) { $ev = $lines[$ln - 1].Trim() }
            [void]$findings.Add([pscustomobject]@{
                Severity = $rule.Severity
                Rank     = Get-MatriseSeverityRank $rule.Severity
                Title    = "$($mlist.Count) x $($rule.Title)"
                RuleId   = $rule.Id
                Line     = $ln
                Evidence = "first at line ${ln}: $ev"
                Why      = $rule.Why
            })
            continue
        }

        $hits = 0
        foreach ($m in $mlist) {
            if ($hits -ge $rule.MaxHits) { break }
            $ln  = Resolve-MatriseLineNumber -Offsets $offsets -Position $m.Index
            $key = "$($rule.Id)|$ln"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $hits++

            # Never name this $text: PowerShell is case-insensitive, so it would
            # overwrite the $Text parameter and every later rule would scan one line.
            $evidence = ''
            if ($ln -le $lines.Count) { $evidence = $lines[$ln - 1].Trim() }
            if ($evidence.Length -gt 220) { $evidence = $evidence.Substring(0, 220) + ' ...' }

            [void]$findings.Add([pscustomobject]@{
                Severity = $rule.Severity
                Rank     = Get-MatriseSeverityRank $rule.Severity
                Title    = $rule.Title
                RuleId   = $rule.Id
                Line     = $ln
                Evidence = $evidence
                Why      = $rule.Why
            })
        }
    }

    foreach ($f in (Get-MatriseStructuredFindings -Text $norm -Lines $lines)) {
        $key = "$($f.RuleId)|$($f.Line)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$findings.Add($f)
    }

    # Always hand back a real array, even when empty, and use the comma
    # operator so the pipeline does not unroll it. Callers must NOT wrap the
    # call in @() -- that would re-wrap this into a nested single-element array.
    $sorted = @($findings | Sort-Object Rank, Line | Select-Object -First $MaxFindings)
    , $sorted
}

# Checks that need more than a single regex can express.
function Get-MatriseStructuredFindings {
    param([string]$Text, $Lines)

    $out = New-Object System.Collections.ArrayList

    # --- Established connections to public IP addresses -------------------
    $private = '^(?:10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|0\.0\.0\.0|224\.|239\.|255\.)'
    $rx = [regex]::new('(?m)^.*?\b((?:\d{1,3}\.){3}\d{1,3}):(\d{1,5})\b.*?(?:ESTABLISHED|Established)\s*$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $remotes = @{}
    foreach ($m in $rx.Matches($Text)) {
        $ip = $m.Groups[1].Value
        if ($ip -match $private) { continue }
        if (-not $remotes.ContainsKey($ip)) { $remotes[$ip] = 0 }
        $remotes[$ip]++
    }
    if ($remotes.Count -gt 0) {
        $top = ($remotes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
                ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', '
        [void]$out.Add([pscustomobject]@{
            Severity = 'Info'
            Rank     = 4
            Title    = "$($remotes.Count) distinct public IPs connected"
            RuleId   = 'struct-public-ips'
            Line     = 1
            Evidence = $top
            Why      = 'Most of these are normal (browser, updates, cloud sync). Look for a connection owned by a process you do not recognise, or one that keeps reconnecting on a fixed interval, which is how command-and-control beaconing looks.'
        })
    }

    # --- Duplicate MAC in the ARP table (possible spoofing) ---------------
    $arp = @{}
    foreach ($ln in 0..($Lines.Count - 1)) {
        $m = [regex]::Match($Lines[$ln], '^\s*((?:\d{1,3}\.){3}\d{1,3})\s+([0-9a-f]{2}(?:-[0-9a-f]{2}){5})\s+dynamic', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $mac = $m.Groups[2].Value.ToLower()
        if (-not $arp.ContainsKey($mac)) { $arp[$mac] = New-Object System.Collections.ArrayList }
        [void]$arp[$mac].Add(@{ Ip = $m.Groups[1].Value; Line = $ln + 1 })
    }
    foreach ($mac in $arp.Keys) {
        if ($arp[$mac].Count -lt 2) { continue }
        $ips = ($arp[$mac] | ForEach-Object { $_.Ip }) -join ', '
        [void]$out.Add([pscustomobject]@{
            Severity = 'High'
            Rank     = 1
            Title    = 'One MAC address claiming several IPs (possible ARP spoofing)'
            RuleId   = "struct-arp-$mac"
            Line     = $arp[$mac][0].Line
            Evidence = "$mac is answering for: $ips"
            Why      = 'On a normal network each device has one IP per MAC. One device answering for several addresses, especially the gateway, is how a man-in-the-middle intercepts traffic on the local network. It can also be a router with several interfaces, so confirm before panicking.'
        })
    }

    # --- Listening on all interfaces --------------------------------------
    # 0.0.0.0 must sit in the LOCAL address column. In netstat output the
    # foreign address of every listener is also 0.0.0.0:0, and counting those
    # would flag a machine that is listening only on loopback.
    $netstatWild = '^[ \t]*(?:TCP|UDP)[ \t]+0\.0\.0\.0:\d{1,5}[ \t]'      # netstat -ano
    $psWild      = '^[ \t]*0\.0\.0\.0[ \t]+\d{1,5}[ \t]+\d+'              # Get-NetTCPConnection table
    $wild = 0
    foreach ($ln in 0..($Lines.Count - 1)) {
        $l = $Lines[$ln]
        if ($l -match $psWild) { $wild++; continue }
        if ($l -match $netstatWild -and ($l -match 'LISTEN' -or $l -match '^[ \t]*UDP')) { $wild++ }
    }
    if ($wild -gt 0) {
        [void]$out.Add([pscustomobject]@{
            Severity = 'Low'
            Rank     = 3
            Title    = "$wild ports listening on all network interfaces"
            RuleId   = 'struct-wildcard-listen'
            Line     = 1
            Evidence = "0.0.0.0 bindings: $wild"
            Why      = 'A service bound to 0.0.0.0 accepts connections from any machine that can reach you, not just from this computer. Anything that only needs to talk to itself should be bound to 127.0.0.1 instead.'
        })
    }

    , $out
}

function Format-MatriseFindings {
    param($Findings)
    if (-not $Findings -or @($Findings).Count -eq 0) {
        return @(
            '',
            '================================================================',
            '  ANALYSIS: nothing suspicious matched.',
            '================================================================',
            '',
            'No rule fired against the text on the board. That is a good sign,',
            'but it is not a clean bill of health: Matrise only sees what you',
            'have actually run. Try the Security > FULL SWEEP command for the',
            'broadest single view.'
        ) -join "`r`n"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('================================================================')
    [void]$sb.AppendLine("  ANALYSIS: $(@($Findings).Count) finding(s)")
    [void]$sb.AppendLine('================================================================')

    $bySev = $Findings | Group-Object Severity | Sort-Object { Get-MatriseSeverityRank $_.Name }
    $summary = ($bySev | ForEach-Object { "$($_.Name): $($_.Count)" }) -join '   '
    [void]$sb.AppendLine("  $summary")
    [void]$sb.AppendLine('')

    $n = 0
    foreach ($f in $Findings) {
        $n++
        [void]$sb.AppendLine("[$($f.Severity.ToUpper())] $($f.Title)")
        [void]$sb.AppendLine("   line $($f.Line): $($f.Evidence)")
        [void]$sb.AppendLine("   why: $($f.Why)")
        [void]$sb.AppendLine('')
    }
    $sb.ToString()
}
