# Matrise - Command catalog
# Every entry is one runnable check or fix.
#
#   Shell   : 'cmd' (streams live)  |  'ps' (runs in a child powershell)
#   Impact  : 'read' = looks only   |  'fix' = changes the system  |  'heavy' = slow / may need reboot
#   Admin   : $true means it needs an elevated session to return real data

function New-MatriseEntry {
    param(
        [string]$Id,
        [string]$Group,
        [string]$Section,
        [string]$Name,
        [string]$Desc,
        [string]$Shell = 'cmd',
        [string]$Command,
        [string]$Impact = 'read',
        [bool]$Admin = $false,
        [int]$Timeout = 180,
        [string]$Prompt = '',
        [string]$PromptDefault = ''
    )
    [pscustomobject]@{
        Id      = $Id
        Group   = $Group
        Section = $Section
        Name    = $Name
        Desc    = $Desc
        Shell   = $Shell
        Command = $Command
        Impact  = $Impact
        Admin   = $Admin
        Timeout = $Timeout
        # When Prompt is set the GUI asks for a value and swaps it into the
        # command wherever %INPUT% appears, before anything runs.
        Prompt        = $Prompt
        PromptDefault = $PromptDefault
    }
}

function Get-MatriseCatalog {

    $c = New-Object System.Collections.ArrayList
    $add = { param($e) [void]$c.Add($e) }

    # ------------------------------------------------------------------
    # NETWORK / Diagnose
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'net.ipconfig' -Group 'Network' -Section 'Diagnose' `
        -Name 'IP configuration (full)' `
        -Desc 'Every adapter: IPv4/IPv6, DNS servers, DHCP lease, MAC address. Start here for "no internet".' `
        -Shell 'cmd' -Command 'ipconfig /all')

    & $add (New-MatriseEntry -Id 'net.connections' -Group 'Network' -Section 'Diagnose' `
        -Name 'Open connections + owning process' `
        -Desc 'Who is talking to the internet right now, and which .exe owns each socket. The most useful single hunt view.' `
        -Shell 'ps' -Admin $true -Command @'
$procs = @{}
Get-CimInstance Win32_Process | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
Get-NetTCPConnection | Where-Object { $_.State -eq 'Established' -or $_.State -eq 'Listen' } |
  Sort-Object State, RemoteAddress |
  ForEach-Object {
    $p = $procs[[int]$_.OwningProcess]
    [pscustomobject]@{
      State   = $_.State
      Local   = "$($_.LocalAddress):$($_.LocalPort)"
      Remote  = "$($_.RemoteAddress):$($_.RemotePort)"
      OwnerPID= $_.OwningProcess
      Process = $(if ($p) { $p.Name } else { '?' })
      Path    = $(if ($p) { $p.ExecutablePath } else { '' })
    }
  } | Format-Table -AutoSize | Out-String -Width 400
'@)

    & $add (New-MatriseEntry -Id 'net.netstat' -Group 'Network' -Section 'Diagnose' `
        -Name 'netstat -abno (raw CMD output)' `
        -Desc 'Classic netstat with executable names. Slower than the view above, but this is the literal CMD output.' `
        -Shell 'cmd' -Admin $true -Command 'netstat -abno' -Timeout 300)

    & $add (New-MatriseEntry -Id 'net.listeners' -Group 'Network' -Section 'Diagnose' `
        -Name 'Listening ports (inbound exposure)' `
        -Desc 'Every port this machine accepts connections on. Anything on 0.0.0.0 is reachable from the whole LAN.' `
        -Shell 'ps' -Admin $true -Command @'
"=== TCP LISTENING ==="
Get-NetTCPConnection -State Listen |
  Select-Object LocalAddress, LocalPort, OwningProcess,
    @{n='Process';e={ (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }} |
  Sort-Object LocalPort | Format-Table -AutoSize | Out-String -Width 400
"=== UDP BOUND ==="
Get-NetUDPEndpoint |
  Select-Object LocalAddress, LocalPort, OwningProcess,
    @{n='Process';e={ (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }} |
  Sort-Object LocalPort | Format-Table -AutoSize | Out-String -Width 400
'@)

    & $add (New-MatriseEntry -Id 'net.arp' -Group 'Network' -Section 'Diagnose' `
        -Name 'ARP table' `
        -Desc 'MAC-to-IP map of the local network. Two IPs sharing one MAC can mean ARP spoofing / a man in the middle.' `
        -Shell 'cmd' -Command 'arp -a')

    & $add (New-MatriseEntry -Id 'net.scan' -Group 'Network' -Section 'Diagnose' `
        -Name 'Scan network for devices' `
        -Desc 'Finds every device on this network - IP, MAC address, name and best-guess maker. Takes a few seconds.' `
        -Shell 'ps' -Timeout 180 -Command @'
$oui = @{
    '50-EB-F6'='ASUS'; '1C-86-9A'='Intel'; 'F0-EF-86'='Google'; 'C8-48-05'='Samsung'
    '1C-69-7A'='Intel'; 'DC-A6-32'='Raspberry Pi'; 'B8-27-EB'='Raspberry Pi'
    'E4-5F-01'='Raspberry Pi'; '3C-22-FB'='Apple'; 'A4-83-E7'='Apple'; 'F0-18-98'='Apple'
    '00-1A-11'='Google'; 'D8-3A-DD'='Google'; '00-17-88'='Philips Hue'
    'EC-FA-BC'='Espressif/IoT'; '2C-F4-32'='Espressif/IoT'; '00-50-56'='VMware'
    '08-00-27'='VirtualBox'; 'AC-DE-48'='(private)'
}
$bases = @()
foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
    $p = $a.IPAddress.Split('.'); $bases += "$($p[0]).$($p[1]).$($p[2])."
}
$bases = $bases | Select-Object -Unique
"Scanning $((($bases | ForEach-Object { $_ + '0/24' }) -join ', ')) - priming the network..."

# Ping every address so each device answers at layer 2 and lands in the ARP
# table. Replies are ignored; the point is to fill the neighbour list.
$tasks = New-Object System.Collections.ArrayList
foreach ($b in $bases) { foreach ($i in 1..254) {
    $ping = New-Object System.Net.NetworkInformation.Ping
    [void]$tasks.Add($ping.SendPingAsync("$b$i", 800))
} }
try { [void][System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), 6000) } catch { }

$me = @((Get-NetIPAddress -AddressFamily IPv4 |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress)
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object RouteMetric | Select-Object -First 1).NextHop

# A real device is any neighbour with a proper unicast MAC, in any state
# (Reachable / Stale / Probe all count). Drop empties, broadcast and multicast.
$rows = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.LinkLayerAddress -match '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' -and
    $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and
    $_.LinkLayerAddress -notlike '01-00-5E-*' -and
    $_.IPAddress -notlike '224.*' -and $_.IPAddress -notlike '239.*' -and
    $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '255.255.255.255'
}

$macByIp = @{}
foreach ($ip in $me) {
    $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).MacAddress
    if ($mac) { $macByIp[$ip] = $mac }
}
foreach ($r in $rows) { if (-not $macByIp.ContainsKey($r.IPAddress)) { $macByIp[$r.IPAddress] = $r.LinkLayerAddress } }

# Resolve all names at once, then wait once - not five seconds per device.
$ips = @($macByIp.Keys)
$dns = @{}
foreach ($ip in $ips) { try { $dns[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch { } }
try { [void][System.Threading.Tasks.Task]::WaitAll(@($dns.Values), 3000) } catch { }

$out = foreach ($ip in ($ips | Sort-Object { try { [version]$_ } catch { [version]'0.0.0.0' } })) {
    $name = ''
    try { if ($dns[$ip].Status -eq 'RanToCompletion') { $name = ($dns[$ip].Result.HostName -split '\.')[0] } } catch { }
    $note = ''
    if ($me -contains $ip) { $note = 'this PC' } elseif ($ip -eq $gw) { $note = 'gateway/router' }
    $mac = "$($macByIp[$ip])".ToUpper()
    $vendor = ''; if ($mac.Length -ge 8) { $vendor = $oui[$mac.Substring(0,8)] }
    [pscustomobject]@{ IP = $ip; MAC = $mac; Vendor = $vendor; Name = $name; Note = $note }
}
""
"DEVICES FOUND: $(@($out).Count)"
""
$out | Format-Table -AutoSize | Out-String -Width 200
'@)

    & $add (New-MatriseEntry -Id 'net.route' -Group 'Network' -Section 'Diagnose' `
        -Name 'Routing table' `
        -Desc 'Where traffic actually goes. An unexpected 0.0.0.0 default route means traffic is being redirected.' `
        -Shell 'cmd' -Command 'route print')

    & $add (New-MatriseEntry -Id 'net.dnscache' -Group 'Network' -Section 'Diagnose' `
        -Name 'DNS resolver cache' `
        -Desc 'Every hostname this PC recently looked up. Good for spotting beacons to odd domains.' `
        -Shell 'cmd' -Command 'ipconfig /displaydns')

    & $add (New-MatriseEntry -Id 'net.hosts' -Group 'Network' -Section 'Diagnose' `
        -Name 'HOSTS file' `
        -Desc 'Local DNS overrides. Malware and cracks write here to block antivirus updates or hijack sites.' `
        -Shell 'cmd' -Command 'type %SystemRoot%\System32\drivers\etc\hosts')

    & $add (New-MatriseEntry -Id 'net.proxy' -Group 'Network' -Section 'Diagnose' `
        -Name 'Proxy settings (system + user)' `
        -Desc 'A silently configured proxy or AutoConfigURL is a classic traffic-interception trick.' `
        -Shell 'cmd' -Command 'netsh winhttp show proxy & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer & reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL')

    & $add (New-MatriseEntry -Id 'net.firewall' -Group 'Network' -Section 'Diagnose' `
        -Name 'Firewall state (all profiles)' `
        -Desc 'Domain / Private / Public profile status. "State OFF" on any profile is a finding.' `
        -Shell 'cmd' -Command 'netsh advfirewall show allprofiles')

    & $add (New-MatriseEntry -Id 'net.fwrules' -Group 'Network' -Section 'Diagnose' `
        -Name 'Inbound ALLOW firewall rules' `
        -Desc 'Rules that let the outside in. Malware adds these to keep a door open.' `
        -Shell 'ps' -Admin $true -Command @'
Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True |
  ForEach-Object {
    $f = $_ | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
    $p = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Name    = $_.DisplayName
      Profile = $_.Profile
      Program = $f.Program
      Proto   = $p.Protocol
      Port    = $p.LocalPort
    }
  } | Sort-Object Name | Format-Table -AutoSize -Wrap | Out-String -Width 400
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'net.wifi' -Group 'Network' -Section 'Diagnose' `
        -Name 'Wi-Fi profiles + current link' `
        -Desc 'Saved networks and the live connection quality (signal, channel, authentication).' `
        -Shell 'cmd' -Command 'netsh wlan show interfaces & netsh wlan show profiles')

    & $add (New-MatriseEntry -Id 'net.shares' -Group 'Network' -Section 'Diagnose' `
        -Name 'Shared folders + active sessions' `
        -Desc 'What this PC shares on the network, and who is connected to it right now.' `
        -Shell 'cmd' -Admin $true -Command 'net share & net session & net use')

    & $add (New-MatriseEntry -Id 'net.speed' -Group 'Network' -Section 'Diagnose' `
        -Name 'Connectivity + latency test' `
        -Desc 'Pings the gateway, then 1.1.1.1, then resolves a hostname. Separates "no link" from "no DNS".' `
        -Shell 'ps' -Command @'
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object RouteMetric | Select-Object -First 1).NextHop
"Default gateway: $gw"
"--- ping gateway ---"
if ($gw) { ping -n 4 $gw } else { "No default gateway found - you are not routed anywhere." }
"--- ping 1.1.1.1 (raw internet) ---"
ping -n 4 1.1.1.1
"--- DNS resolve test ---"
Resolve-DnsName microsoft.com -ErrorAction SilentlyContinue |
  Format-Table -AutoSize | Out-String -Width 300
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'net.trace' -Group 'Network' -Section 'Diagnose' `
        -Name 'Traceroute to 1.1.1.1' `
        -Desc 'Every hop out of your network. A surprise first hop can mean a rogue router.' `
        -Shell 'cmd' -Command 'tracert -d -h 15 1.1.1.1' -Timeout 300)

    # ------------------------------------------------------------------
    # NETWORK / Fix
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'netfix.flushdns' -Group 'Network' -Section 'Fix' `
        -Name 'Flush DNS cache' `
        -Desc 'Clears poisoned or stale hostname entries. Safe, instant, fixes most "this site will not load" issues.' `
        -Shell 'cmd' -Impact 'fix' -Command 'ipconfig /flushdns & ipconfig /registerdns')

    & $add (New-MatriseEntry -Id 'netfix.renew' -Group 'Network' -Section 'Fix' `
        -Name 'Release + renew DHCP lease' `
        -Desc 'Asks the router for a fresh IP address. Drops you offline for a few seconds.' `
        -Shell 'cmd' -Impact 'fix' -Admin $true -Command 'ipconfig /release & ipconfig /renew')

    & $add (New-MatriseEntry -Id 'netfix.winsock' -Group 'Network' -Section 'Fix' `
        -Name 'Reset Winsock catalog' `
        -Desc 'Removes hijacked LSP layers injected into the TCP stack by adware. NEEDS A REBOOT.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'netsh winsock reset')

    & $add (New-MatriseEntry -Id 'netfix.ipreset' -Group 'Network' -Section 'Fix' `
        -Name 'Reset TCP/IP stack' `
        -Desc 'Rebuilds the IPv4/IPv6 stack from scratch. NEEDS A REBOOT. Use when nothing else restores connectivity.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'netsh int ip reset & netsh int ipv6 reset')

    & $add (New-MatriseEntry -Id 'netfix.proxy' -Group 'Network' -Section 'Fix' `
        -Name 'Clear proxy hijack' `
        -Desc 'Resets the WinHTTP proxy and turns off the per-user proxy plus any auto-config URL.' `
        -Shell 'cmd' -Impact 'fix' -Admin $true -Command 'netsh winhttp reset proxy & reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f & reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL /f')

    & $add (New-MatriseEntry -Id 'netfix.hosts' -Group 'Network' -Section 'Fix' `
        -Name 'Restore clean HOSTS file' `
        -Desc 'Backs the current HOSTS file up next to itself, then writes the Windows default.' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
$h = "$env:SystemRoot\System32\drivers\etc\hosts"
$bak = "$h.matrise-backup"
Copy-Item $h $bak -Force
"Backed up to: $bak"
Set-Content -Path $h -Encoding ASCII -Value @(
  '# Copyright (c) 1993-2009 Microsoft Corp.',
  '# Restored by Matrise.',
  '127.0.0.1       localhost',
  '::1             localhost'
)
"HOSTS file reset. New contents:"
Get-Content $h
'@)

    & $add (New-MatriseEntry -Id 'netfix.firewallon' -Group 'Network' -Section 'Fix' `
        -Name 'Turn the firewall back on' `
        -Desc 'Enables Windows Firewall on all three profiles and shows the result.' `
        -Shell 'cmd' -Impact 'fix' -Admin $true -Command 'netsh advfirewall set allprofiles state on & netsh advfirewall show allprofiles state')

    & $add (New-MatriseEntry -Id 'netfix.adapters' -Group 'Network' -Section 'Fix' `
        -Name 'Restart all network adapters' `
        -Desc 'Disables then re-enables every physical NIC. Brief disconnect while it runs.' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' } | ForEach-Object {
  "Restarting: $($_.Name)"
  Restart-NetAdapter -Name $_.Name -Confirm:$false
}
Start-Sleep -Seconds 3
Get-NetAdapter | Format-Table Name, Status, LinkSpeed -AutoSize | Out-String -Width 200
'@ -Timeout 300)

    # ------------------------------------------------------------------
    # COMPUTER / Diagnose
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'pc.sysinfo' -Group 'Computer' -Section 'Diagnose' `
        -Name 'System summary' `
        -Desc 'OS build, install date, uptime, BIOS, RAM, domain. Context for everything else.' `
        -Shell 'cmd' -Command 'systeminfo' -Timeout 300)

    & $add (New-MatriseEntry -Id 'pc.processes' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Running processes + full paths' `
        -Desc 'Every process with the exact binary it launched from. Paths under Temp or AppData are the red flag.' `
        -Shell 'ps' -Command @'
Get-CimInstance Win32_Process |
  Select-Object @{n='ProcId';e={$_.ProcessId}}, Name,
    @{n='MemMB';e={[math]::Round($_.WorkingSetSize/1MB,1)}},
    ExecutablePath, CommandLine |
  Sort-Object Name | Format-Table -AutoSize -Wrap | Out-String -Width 500
'@)

    & $add (New-MatriseEntry -Id 'pc.unsigned' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Unsigned running binaries' `
        -Desc 'Checks the Authenticode signature of every running .exe. Real software is almost always signed.' `
        -Shell 'ps' -Command @'
Get-Process | Where-Object { $_.Path } | Select-Object -Unique Path | ForEach-Object {
  $s = Get-AuthenticodeSignature $_.Path -ErrorAction SilentlyContinue
  [pscustomobject]@{
    Status = $(if ($s) { $s.Status } else { 'Unknown' })
    Signer = $(if ($s -and $s.SignerCertificate) { $s.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1' } else { '' })
    Path   = $_.Path
  }
} | Where-Object { $_.Status -ne 'Valid' } |
  Sort-Object Path | Format-Table -AutoSize -Wrap | Out-String -Width 400
'@ -Timeout 600)

    & $add (New-MatriseEntry -Id 'pc.autoruns' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Startup / autorun entries' `
        -Desc 'Everything that launches at boot or logon: Run keys, startup folders, Winlogon, WMI subscriptions.' `
        -Shell 'ps' -Command @'
$keys = @(
 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run',
 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $keys) {
  if (Test-Path $k) {
    "=== $k ==="
    (Get-ItemProperty $k).PSObject.Properties |
      Where-Object { $_.Name -notlike 'PS*' } |
      ForEach-Object { "  {0,-30} {1}" -f $_.Name, $_.Value }
  }
}
"=== Startup folders ==="
@("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup") | ForEach-Object {
  if (Test-Path $_) { Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object { "  $($_.FullName)" } }
}
"=== Winlogon (Shell must be explorer.exe, Userinit must be userinit.exe) ==="
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' |
  Select-Object Shell, Userinit, Taskman | Format-List | Out-String
"=== WMI permanent event consumers (advanced persistence) ==="
Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue |
  Select-Object Name, __CLASS | Format-Table -AutoSize | Out-String -Width 300
'@)

    & $add (New-MatriseEntry -Id 'pc.tasks' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Scheduled tasks (non-Microsoft)' `
        -Desc 'Third-party scheduled tasks and the exact command each one runs. Windows built-ins filtered out.' `
        -Shell 'ps' -Command @'
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
  $a = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | '
  [pscustomobject]@{
    State = $_.State
    Task  = ($_.TaskPath + $_.TaskName)
    Runs  = $a
  }
} | Sort-Object Task | Format-Table -AutoSize -Wrap | Out-String -Width 400
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'pc.services' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Services + binary paths' `
        -Desc 'Every non-disabled service and the exact file it runs. Look for paths outside System32 / Program Files.' `
        -Shell 'ps' -Command @'
Get-CimInstance Win32_Service |
  Where-Object { $_.StartMode -ne 'Disabled' } |
  Select-Object State, StartMode, Name, DisplayName, PathName |
  Sort-Object State, Name | Format-Table -AutoSize -Wrap | Out-String -Width 450
'@)

    & $add (New-MatriseEntry -Id 'pc.defender' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Defender status + exclusions' `
        -Desc 'Is real-time protection on, are signatures current, and has anything quietly added exclusion paths?' `
        -Shell 'ps' -Admin $true -Command @'
Get-MpComputerStatus | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled,
  BehaviorMonitorEnabled, IoavProtectionEnabled, AntispywareEnabled, IsTamperProtected,
  AntivirusSignatureLastUpdated, AntivirusSignatureVersion, QuickScanAge | Format-List | Out-String
"=== EXCLUSIONS (attackers add these to hide their files) ==="
$p = Get-MpPreference
"ExclusionPath      : " + (($p.ExclusionPath)      -join '; ')
"ExclusionExtension : " + (($p.ExclusionExtension) -join '; ')
"ExclusionProcess   : " + (($p.ExclusionProcess)   -join '; ')
"DisableRealtimeMonitoring : " + $p.DisableRealtimeMonitoring
"=== Recent threat detections ==="
Get-MpThreatDetection -ErrorAction SilentlyContinue |
  Select-Object -Last 20 InitialDetectionTime, ThreatID, Resources |
  Format-Table -AutoSize -Wrap | Out-String -Width 300
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'pc.accounts' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Local accounts + administrators' `
        -Desc 'Who can sign in and who has admin rights. An unfamiliar name in Administrators is serious.' `
        -Shell 'ps' -Command @'
Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet, Description |
  Format-Table -AutoSize -Wrap | Out-String -Width 300
"=== Administrators group ==="
Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
  Format-Table Name, ObjectClass, PrincipalSource -AutoSize | Out-String -Width 300
"=== Remote Desktop (fDenyTSConnections 0 = RDP is OPEN) ==="
Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue |
  Select-Object fDenyTSConnections | Format-List | Out-String
'@)

    & $add (New-MatriseEntry -Id 'pc.logons' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Recent logons + failed attempts' `
        -Desc 'Successful and failed sign-ins from the Security log. A burst of failures means someone is guessing.' `
        -Shell 'ps' -Admin $true -Command @'
"=== Failed logons (event 4625), last 30 ==="
Get-WinEvent -FilterHashtable @{LogName='Security';Id=4625} -MaxEvents 30 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, @{n='Detail';e={($_.Message -split "`n")[0]}} |
  Format-Table -AutoSize -Wrap | Out-String -Width 300
"=== Successful logons (event 4624), last 20 ==="
Get-WinEvent -FilterHashtable @{LogName='Security';Id=4624} -MaxEvents 20 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, @{n='Detail';e={($_.Message -split "`n")[0]}} |
  Format-Table -AutoSize -Wrap | Out-String -Width 300
'@ -Timeout 600)

    & $add (New-MatriseEntry -Id 'pc.errors' -Group 'Computer' -Section 'Diagnose' `
        -Name 'System errors + crashes (last 7 days)' `
        -Desc 'Critical and error events from the System log. Where "why does it keep freezing" gets answered.' `
        -Shell 'ps' -Command @'
$since = (Get-Date).AddDays(-7)
"=== Most frequent errors, last 7 days ==="
Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2;StartTime=$since} -ErrorAction SilentlyContinue |
  Group-Object ProviderName, Id |
  Sort-Object Count -Descending | Select-Object -First 25 Count, Name |
  Format-Table -AutoSize | Out-String -Width 300
"=== Unexpected shutdowns / bugchecks ==="
Get-WinEvent -FilterHashtable @{LogName='System';Id=41,1001,6008} -MaxEvents 15 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, @{n='Detail';e={($_.Message -split "`n")[0]}} |
  Format-Table -AutoSize -Wrap | Out-String -Width 300
'@ -Timeout 600)

    & $add (New-MatriseEntry -Id 'pc.disk' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Disk health + free space' `
        -Desc 'SMART health per physical disk and free space per volume. A failing disk explains a lot of weirdness.' `
        -Shell 'ps' -Command @'
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, HealthStatus, OperationalStatus,
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize | Out-String -Width 300
Get-Volume | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
  @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
  @{n='FreePct';e={ if ($_.Size) { [math]::Round(100*$_.SizeRemaining/$_.Size,1) } else { 0 } }} |
  Format-Table -AutoSize | Out-String -Width 300
'@)

    & $add (New-MatriseEntry -Id 'pc.bigfiles' -Group 'Computer' -Section 'Diagnose' `
        -Name 'What is eating the disk' `
        -Desc 'Size of every junk location Matrise can clean, plus your 25 largest files. Run this before cleaning.' `
        -Shell 'ps' -Command @'
$targets = [ordered]@{
  'User temp'             = $env:TEMP
  'Windows temp'          = "$env:SystemRoot\Temp"
  'Windows Update cache'  = "$env:SystemRoot\SoftwareDistribution\Download"
  'Prefetch'              = "$env:SystemRoot\Prefetch"
  'Crash dumps'           = "$env:LOCALAPPDATA\CrashDumps"
  'INetCache'             = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"
}
"=== Reclaimable locations ==="
foreach ($k in $targets.Keys) {
  $p = $targets[$k]
  if ($p -and (Test-Path $p)) {
    $s = Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    "{0,-24} {1,10:N1} MB  {2,7} files   {3}" -f $k, ($s.Sum/1MB), $s.Count, $p
  } else {
    "{0,-24} {1,10}      (not present)" -f $k, '-'
  }
}
"=== 25 largest files in your profile ==="
Get-ChildItem $env:USERPROFILE -Recurse -File -Force -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending | Select-Object -First 25 |
  Select-Object @{n='MB';e={[math]::Round($_.Length/1MB,1)}}, FullName |
  Format-Table -AutoSize | Out-String -Width 400
'@ -Timeout 900)

    & $add (New-MatriseEntry -Id 'pc.installed' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Installed programs (newest first)' `
        -Desc 'If the trouble started on a certain date, look at what arrived that day.' `
        -Shell 'ps' -Command @'
$paths = @(
 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
Get-ItemProperty $paths -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName } |
  Select-Object InstallDate, DisplayName, DisplayVersion, Publisher, InstallLocation |
  Sort-Object InstallDate -Descending |
  Format-Table -AutoSize -Wrap | Out-String -Width 450
'@)

    & $add (New-MatriseEntry -Id 'pc.drivers' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Drivers + problem devices' `
        -Desc 'Unsigned drivers, plus any device reporting an error code in Device Manager.' `
        -Shell 'ps' -Command @'
"=== Devices reporting a problem ==="
Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
  Select-Object Name, DeviceID, ConfigManagerErrorCode, Status |
  Format-Table -AutoSize -Wrap | Out-String -Width 400
"=== Unsigned drivers ==="
driverquery /si | Select-String -Pattern 'FALSE'
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'pc.integrity' -Group 'Computer' -Section 'Diagnose' `
        -Name 'System file integrity (read-only)' `
        -Desc 'Verifies protected Windows files without changing anything. Safe to run any time.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'sfc /verifyonly' -Timeout 2400)

    & $add (New-MatriseEntry -Id 'pc.bitlocker' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Encryption + Secure Boot state' `
        -Desc 'BitLocker per volume, Secure Boot, and TPM. Your baseline hardware security posture.' `
        -Shell 'ps' -Admin $true -Command @'
Get-BitLockerVolume -ErrorAction SilentlyContinue |
  Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage |
  Format-Table -AutoSize | Out-String -Width 200
"Secure Boot enabled : " + (Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)
Get-Tpm -ErrorAction SilentlyContinue | Select-Object TpmPresent, TpmReady, TpmEnabled | Format-List | Out-String
'@)

    # ------------------------------------------------------------------
    # COMPUTER / Fix
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'pcfix.restorepoint' -Group 'Computer' -Section 'Fix' `
        -Name 'Create a restore point FIRST' `
        -Desc 'Your undo button. Run this before anything else in the Fix sections.' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
Checkpoint-Computer -Description "Matrise - before cleanup" -RestorePointType MODIFY_SETTINGS
"Restore point created."
Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 5 CreationTime, Description, SequenceNumber |
  Format-Table -AutoSize | Out-String -Width 200
'@ -Timeout 900)

    & $add (New-MatriseEntry -Id 'pcfix.temp' -Group 'Computer' -Section 'Fix' `
        -Name 'Clean temp + cache files' `
        -Desc 'Deletes user temp, Windows temp, crash dumps and web cache. Files in use are skipped safely.' `
        -Shell 'ps' -Impact 'fix' -Command @'
$targets = @($env:TEMP, "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\CrashDumps",
             "$env:LOCALAPPDATA\Microsoft\Windows\INetCache")
$total = 0
foreach ($t in $targets) {
  if (-not $t -or -not (Test-Path $t)) { continue }
  $before = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
  $after = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  $freed = [math]::Max(0, ($before - $after))
  $total += $freed
  "{0,10:N1} MB freed   {1}" -f ($freed/1MB), $t
}
""
"TOTAL FREED: {0:N1} MB" -f ($total/1MB)
'@ -Timeout 1200)

    & $add (New-MatriseEntry -Id 'pcfix.recyclebin' -Group 'Computer' -Section 'Fix' `
        -Name 'Empty the Recycle Bin' `
        -Desc 'Permanently deletes everything currently in the bin, on every drive.' `
        -Shell 'ps' -Impact 'fix' -Command @'
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
"Recycle Bin emptied."
'@)

    & $add (New-MatriseEntry -Id 'pcfix.wucache' -Group 'Computer' -Section 'Fix' `
        -Name 'Reset Windows Update cache' `
        -Desc 'Stops the update services, clears the download cache, restarts them. Fixes stuck updates.' `
        -Shell 'cmd' -Impact 'fix' -Admin $true -Command 'net stop wuauserv & net stop bits & net stop cryptsvc & rd /s /q %SystemRoot%\SoftwareDistribution\Download & net start cryptsvc & net start bits & net start wuauserv & echo Windows Update cache reset.' -Timeout 900)

    & $add (New-MatriseEntry -Id 'pcfix.sfc' -Group 'Computer' -Section 'Fix' `
        -Name 'Repair system files (SFC)' `
        -Desc 'Finds and replaces corrupted Windows files from the local cache. Takes 5-20 minutes.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'sfc /scannow' -Timeout 3600)

    & $add (New-MatriseEntry -Id 'pcfix.dism' -Group 'Computer' -Section 'Fix' `
        -Name 'Repair the component store (DISM)' `
        -Desc 'Repairs the source that SFC repairs from, using Windows Update. Run this if SFC could not fix everything.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'DISM /Online /Cleanup-Image /RestoreHealth' -Timeout 3600)

    & $add (New-MatriseEntry -Id 'pcfix.chkdsk' -Group 'Computer' -Section 'Fix' `
        -Name 'Schedule a disk check at next boot' `
        -Desc 'Queues a full chkdsk /f /r on the system drive. Runs on next restart and takes a long time.' `
        -Shell 'cmd' -Impact 'heavy' -Admin $true -Command 'echo Y| chkdsk %SystemDrive% /f /r')

    & $add (New-MatriseEntry -Id 'pcfix.defenderscan' -Group 'Computer' -Section 'Fix' `
        -Name 'Update signatures + quick scan' `
        -Desc 'Pulls the newest Defender definitions, then scans the usual infection points.' `
        -Shell 'ps' -Impact 'heavy' -Admin $true -Command @'
"Updating signatures..."
Update-MpSignature -ErrorAction SilentlyContinue
Get-MpComputerStatus | Select-Object AntivirusSignatureVersion, AntivirusSignatureLastUpdated | Format-List | Out-String
"Running quick scan (this takes a few minutes, output appears when it finishes)..."
Start-MpScan -ScanType QuickScan
"=== Threats found ==="
Get-MpThreat -ErrorAction SilentlyContinue |
  Select-Object ThreatName, SeverityID, Resources | Format-Table -AutoSize -Wrap | Out-String -Width 300
'@ -Timeout 3600)

    & $add (New-MatriseEntry -Id 'pcfix.defenderon' -Group 'Computer' -Section 'Fix' `
        -Name 'Re-enable Defender real-time protection' `
        -Desc 'Turns real-time and behaviour monitoring back on. Fails harmlessly if Tamper Protection is on.' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection $false -ErrorAction SilentlyContinue
Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled, BehaviorMonitorEnabled, IoavProtectionEnabled |
  Format-List | Out-String
'@)

    & $add (New-MatriseEntry -Id 'pcfix.optimize' -Group 'Computer' -Section 'Fix' `
        -Name 'Optimize drives (TRIM / defrag)' `
        -Desc 'TRIM for SSDs, defragment for spinning disks. Windows picks the right operation per volume.' `
        -Shell 'ps' -Impact 'heavy' -Admin $true -Command @'
Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' } | ForEach-Object {
  "Optimizing $($_.DriveLetter): ..."
  Optimize-Volume -DriveLetter $_.DriveLetter -Verbose
}
'@ -Timeout 3600)

    # ------------------------------------------------------------------
    # SECURITY / Hunt
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'sec.sweep' -Group 'Security' -Section 'Hunt' `
        -Name 'FULL SWEEP (start here)' `
        -Desc 'Runs the whole hunt in one pass and dumps everything into the board for the analyzer to chew on.' `
        -Shell 'ps' -Admin $true -Command @'
function Sec($t) { ""; "==================== $t ===================="; }

Sec 'PROCESSES RUNNING FROM SUSPICIOUS LOCATIONS'
Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -match '\\AppData\\|\\Temp\\|\\Downloads\\|\\Public\\|\\ProgramData\\'
} | Select-Object ProcessId, Name, ExecutablePath, CommandLine |
  Format-Table -AutoSize -Wrap | Out-String -Width 450

Sec 'OUTBOUND CONNECTIONS TO PUBLIC IPs'
$procs = @{}; Get-CimInstance Win32_Process | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object {
  $_.RemoteAddress -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|::1|fe80|0\.0\.0\.0)'
} | ForEach-Object {
  $p = $procs[[int]$_.OwningProcess]
  [pscustomobject]@{
    Remote  = "$($_.RemoteAddress):$($_.RemotePort)"
    OwnerPID= $_.OwningProcess
    Process = $(if($p){$p.Name}else{'?'})
    Path    = $(if($p){$p.ExecutablePath}else{''})
  }
} | Sort-Object Process | Format-Table -AutoSize -Wrap | Out-String -Width 400

Sec 'PERSISTENCE - RUN KEYS'
@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') | ForEach-Object {
  if (Test-Path $_) {
    "--- $_"
    (Get-ItemProperty $_).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } |
      ForEach-Object { "  {0,-28} {1}" -f $_.Name, $_.Value }
  }
}

Sec 'PERSISTENCE - SCHEDULED TASKS (non-Microsoft)'
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
  "  {0,-45} {1}" -f ($_.TaskPath + $_.TaskName), (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ')
}

Sec 'PERSISTENCE - SERVICES OUTSIDE SYSTEM32 / PROGRAM FILES'
Get-CimInstance Win32_Service | Where-Object {
  $_.PathName -and $_.PathName -notmatch 'System32|SysWOW64|Program Files'
} | Select-Object Name, State, StartMode, PathName | Format-Table -AutoSize -Wrap | Out-String -Width 400

Sec 'DEFENDER POSTURE + EXCLUSIONS'
Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled, AntivirusEnabled, BehaviorMonitorEnabled,
  AntivirusSignatureLastUpdated | Format-List | Out-String
$mp = Get-MpPreference
"ExclusionPath    : " + (($mp.ExclusionPath) -join '; ')
"ExclusionProcess : " + (($mp.ExclusionProcess) -join '; ')

Sec 'FIREWALL STATE'
netsh advfirewall show allprofiles state

Sec 'ADMIN ACCOUNTS'
Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
  Format-Table Name, PrincipalSource -AutoSize | Out-String -Width 200
Get-LocalUser | Where-Object { $_.Enabled } |
  Format-Table Name, LastLogon, PasswordLastSet -AutoSize | Out-String -Width 200

Sec 'REMOTE ACCESS'
"fDenyTSConnections (0 = RDP OPEN): " + (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
Get-Service -Name TermService, RemoteRegistry, SSHD -ErrorAction SilentlyContinue |
  Format-Table Name, Status, StartType -AutoSize | Out-String -Width 200

Sec 'HOSTS FILE (non-comment lines)'
Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue |
  Where-Object { $_ -match '^\s*[^#\s]' }

Sec 'PROXY CONFIGURATION'
netsh winhttp show proxy
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue |
  Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Format-List | Out-String

Sec 'RECENTLY MODIFIED EXECUTABLES IN SYSTEM FOLDERS (14 days)'
$cut = (Get-Date).AddDays(-14)
Get-ChildItem "$env:SystemRoot\System32" -Include *.exe,*.dll,*.sys -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt $cut } |
  Select-Object LastWriteTime, FullName | Sort-Object LastWriteTime -Descending |
  Format-Table -AutoSize | Out-String -Width 400

Sec 'SWEEP COMPLETE'
'@ -Timeout 1200)

    & $add (New-MatriseEntry -Id 'sec.suspath' -Group 'Security' -Section 'Hunt' `
        -Name 'Processes in Temp / AppData / Downloads' `
        -Desc 'Real software installs into Program Files. Malware runs from wherever it happened to land.' `
        -Shell 'ps' -Command @'
Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -match '\\AppData\\|\\Temp\\|\\Downloads\\|\\Public\\|\\Recycle'
} | ForEach-Object {
  $sig = Get-AuthenticodeSignature $_.ExecutablePath -ErrorAction SilentlyContinue
  [pscustomobject]@{
    ProcId = $_.ProcessId
    Name   = $_.Name
    Signed = $(if ($sig) { $sig.Status } else { 'Unknown' })
    Path   = $_.ExecutablePath
    Cmd    = $_.CommandLine
  }
} | Format-Table -AutoSize -Wrap | Out-String -Width 450
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'sec.lolbins' -Group 'Security' -Section 'Hunt' `
        -Name 'Living-off-the-land abuse' `
        -Desc 'Windows own tools used as malware: encoded PowerShell, certutil downloads, mshta, rundll32 tricks.' `
        -Shell 'ps' -Command @'
$bad = 'certutil|bitsadmin|mshta|regsvr32|rundll32|wmic|cscript|wscript|-enc |-EncodedCommand|FromBase64String|-w hidden|-windowstyle hidden|-nop |IEX|Invoke-Expression|DownloadString|DownloadFile'
"=== Running processes with suspicious command lines ==="
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $bad } |
  Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize -Wrap | Out-String -Width 450
"=== Scheduled tasks invoking those tools ==="
Get-ScheduledTask | ForEach-Object {
  $a = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
  if ($a -match $bad) { "  {0,-45} {1}" -f ($_.TaskPath + $_.TaskName), $a }
}
"=== Services invoking those tools ==="
Get-CimInstance Win32_Service | Where-Object { $_.PathName -match $bad } |
  Select-Object Name, PathName | Format-Table -AutoSize -Wrap | Out-String -Width 400
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'sec.browser' -Group 'Security' -Section 'Hunt' `
        -Name 'Browser extensions + hijacked shortcuts' `
        -Desc 'Extensions across Chrome/Edge/Brave, and browser shortcuts with a URL injected into the arguments.' `
        -Shell 'ps' -Command @'
$roots = [ordered]@{
  Chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data"
  Edge   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
  Brave  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
}
foreach ($b in $roots.Keys) {
  $r = $roots[$b]
  if (-not (Test-Path $r)) { continue }
  "=== $b extensions ==="
  Get-ChildItem "$r\*\Extensions" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $id = $_.Name
    $m = Get-ChildItem $_.FullName -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | Select-Object -First 1
    $nm = ''
    if ($m) { try { $nm = (Get-Content $m.FullName -Raw | ConvertFrom-Json).name } catch { $nm = '' } }
    "  {0}  {1}" -f $id, $nm
  }
}
"=== Browser shortcuts with a URL injected into the arguments ==="
$sh = New-Object -ComObject WScript.Shell
@("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "$env:APPDATA\Microsoft\Windows\Start Menu") |
 ForEach-Object {
  Get-ChildItem $_ -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    $lnk = $sh.CreateShortcut($_.FullName)
    if ($lnk.TargetPath -match 'chrome|msedge|firefox|brave|opera' -and $lnk.Arguments -match 'http') {
      "  HIJACKED SHORTCUT: {0}" -f $_.FullName
      "     target: {0}" -f $lnk.TargetPath
      "     args  : {0}" -f $lnk.Arguments
    }
  }
}
'@ -Timeout 600)

    & $add (New-MatriseEntry -Id 'sec.newfiles' -Group 'Security' -Section 'Hunt' `
        -Name 'Executables written in the last 7 days' `
        -Desc 'New .exe/.dll/.ps1/.bat dropped into your profile or ProgramData. Ask where each one came from.' `
        -Shell 'ps' -Command @'
$cut = (Get-Date).AddDays(-7)
@("$env:APPDATA", "$env:LOCALAPPDATA", "$env:ProgramData", "$env:TEMP", "$env:PUBLIC") | ForEach-Object {
  Get-ChildItem $_ -Recurse -File -Force -Include *.exe,*.dll,*.ps1,*.bat,*.cmd,*.vbs,*.js,*.hta,*.scr -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -gt $cut }
} | Sort-Object CreationTime -Descending | Select-Object -First 100 |
  Select-Object CreationTime, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, FullName |
  Format-Table -AutoSize | Out-String -Width 450
'@ -Timeout 900)

    # ------------------------------------------------------------------
    # SECURITY / Fix
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'sec.quarantine' -Group 'Security' -Section 'Fix' `
        -Name 'Kill + quarantine a process' `
        -Desc 'Stops a PID and moves its binary into Matrise\Quarantine. Logged, and reversible by hand.' `
        -Prompt 'PID of the process to kill and quarantine' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
$target = '%INPUT%'
$p = Get-Process -Id $target -ErrorAction Stop
$path = $p.Path
"Process : $($p.ProcessName)"
"Path    : $path"
$q = Join-Path $env:MATRISE_HOME 'Quarantine'
New-Item -ItemType Directory -Path $q -Force | Out-Null
Stop-Process -Id $target -Force
Start-Sleep -Milliseconds 500
if ($path -and (Test-Path $path)) {
  $dest = Join-Path $q ("{0}__{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Split-Path $path -Leaf))
  Move-Item $path $dest -Force
  "Quarantined to: $dest"
  Add-Content (Join-Path $q 'quarantine-log.txt') ("{0}`t{1}`t{2}" -f (Get-Date), $path, $dest)
  "Original path logged in quarantine-log.txt - move the file back if this was a mistake."
} else {
  "Process stopped. Binary path was not accessible, so nothing was moved."
}
'@)

    & $add (New-MatriseEntry -Id 'sec.harden' -Group 'Security' -Section 'Fix' `
        -Name 'Baseline hardening' `
        -Desc 'Firewall on, RDP off, Remote Registry off, SMBv1 off, Defender real-time on. Reports the result of each.' `
        -Shell 'ps' -Impact 'fix' -Admin $true -Command @'
"--- Firewall on (all profiles)"
netsh advfirewall set allprofiles state on
"--- Disable Remote Desktop"
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1
"--- Disable Remote Registry"
Set-Service RemoteRegistry -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service RemoteRegistry -Force -ErrorAction SilentlyContinue
"--- Disable SMBv1"
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
"--- Defender real-time protection on"
Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
""
"=== RESULT ==="
netsh advfirewall show allprofiles state
"RDP denied (1 = good): " + (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections
Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled | Format-List | Out-String
'@ -Timeout 600)

    # ------------------------------------------------------------------
    # ASK-AND-RUN  (the GUI prompts, then swaps the answer in for %INPUT%)
    # ------------------------------------------------------------------
    & $add (New-MatriseEntry -Id 'net.pinghost' -Group 'Network' -Section 'Diagnose' `
        -Name 'Ping + trace a specific host' `
        -Desc 'Proves whether one named site or server is reachable, and shows where the path breaks.' `
        -Prompt 'Host or IP to test' -PromptDefault 'google.com' `
        -Shell 'cmd' -Command 'ping -n 4 %INPUT% & echo. & tracert -d -h 15 %INPUT%' -Timeout 300)

    & $add (New-MatriseEntry -Id 'net.dnslookup' -Group 'Network' -Section 'Diagnose' `
        -Name 'DNS lookup + hijack comparison' `
        -Desc 'Resolves a domain through YOUR DNS server and through Cloudflare. Different answers means your DNS is lying.' `
        -Prompt 'Domain to resolve' -PromptDefault 'microsoft.com' `
        -Shell 'ps' -Command @'
$target = '%INPUT%'
"=== Records ==="
Resolve-DnsName $target -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String -Width 300
"=== MX / TXT ==="
Resolve-DnsName $target -Type MX  -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String -Width 300
Resolve-DnsName $target -Type TXT -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String -Width 300
"=== Hijack check: your DNS vs Cloudflare (answers should overlap) ==="
"your DNS : " + (((Resolve-DnsName $target -Type A -ErrorAction SilentlyContinue).IPAddress) -join ', ')
"1.1.1.1  : " + (((Resolve-DnsName $target -Type A -Server 1.1.1.1 -ErrorAction SilentlyContinue).IPAddress) -join ', ')
'@ -Timeout 120)

    & $add (New-MatriseEntry -Id 'net.portcheck' -Group 'Network' -Section 'Diagnose' `
        -Name 'Test a host and port' `
        -Desc 'Is that port actually open and routable from here? Answers "is it the firewall or the service?"' `
        -Prompt 'host:port' -PromptDefault '1.1.1.1:443' `
        -Shell 'ps' -Command @'
$parts = ('%INPUT%' -split ':')
$h = $parts[0]
$prt = 443
if ($parts.Count -gt 1) { $prt = [int]$parts[1] }
Test-NetConnection -ComputerName $h -Port $prt -InformationLevel Detailed | Format-List | Out-String
'@ -Timeout 120)

    & $add (New-MatriseEntry -Id 'pc.procinfo' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Investigate one process' `
        -Desc 'Everything about a process by name or PID: path, parent, command line, signature, SHA256, live connections.' `
        -Prompt 'Process name or PID' -PromptDefault 'explorer' `
        -Shell 'ps' -Command @'
$q = '%INPUT%'
if ($q -match '^\d+$') { $procs = @(Get-CimInstance Win32_Process -Filter "ProcessId=$q") }
else { $procs = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -like "*$q*" }) }
if ($procs.Count -eq 0) { "No process matched: $q" }
foreach ($p in $procs) {
  "================================================================"
  "Name      : $($p.Name)"
  "PID       : $($p.ProcessId)    Parent PID: $($p.ParentProcessId)"
  "Path      : $($p.ExecutablePath)"
  "CommandLn : $($p.CommandLine)"
  if ($p.ExecutablePath -and (Test-Path $p.ExecutablePath)) {
    $s = Get-AuthenticodeSignature $p.ExecutablePath -ErrorAction SilentlyContinue
    "Signature : $($s.Status)"
    if ($s.SignerCertificate) { "Signer    : $($s.SignerCertificate.Subject)" }
    "SHA256    : $((Get-FileHash $p.ExecutablePath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash)"
  }
  "--- network connections owned by this PID ---"
  Get-NetTCPConnection -OwningProcess $p.ProcessId -ErrorAction SilentlyContinue |
    Select-Object State, LocalPort, RemoteAddress, RemotePort |
    Format-Table -AutoSize | Out-String -Width 200
}
'@ -Timeout 300)

    & $add (New-MatriseEntry -Id 'pc.findfile' -Group 'Computer' -Section 'Diagnose' `
        -Name 'Find a file anywhere in your profile' `
        -Desc 'Searches your profile, ProgramData and Windows temp for a name or wildcard pattern.' `
        -Prompt 'File name or pattern' -PromptDefault '*.exe' `
        -Shell 'ps' -Command @'
$pat = '%INPUT%'
@("$env:USERPROFILE", "$env:ProgramData", "$env:SystemRoot\Temp") | ForEach-Object {
  Get-ChildItem $_ -Recurse -File -Force -Filter $pat -ErrorAction SilentlyContinue
} | Select-Object -First 200 |
  Select-Object CreationTime, LastWriteTime, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}, FullName |
  Sort-Object CreationTime -Descending | Format-Table -AutoSize | Out-String -Width 450
'@ -Timeout 900)

    & $add (New-MatriseEntry -Id 'sec.hashfile' -Group 'Security' -Section 'Hunt' `
        -Name 'Fingerprint a suspicious file' `
        -Desc 'Hashes, signature, and the URL it was downloaded from. Paste the SHA256 into VirusTotal to identify it.' `
        -Prompt 'Full path of the file' `
        -Shell 'ps' -Command @'
$f = ('%INPUT%').Trim('"').Trim()
if (-not (Test-Path $f)) { "Not found: $f" } else {
  $i = Get-Item $f
  "Path     : $($i.FullName)"
  "Size     : $($i.Length) bytes"
  "Created  : $($i.CreationTime)"
  "Modified : $($i.LastWriteTime)"
  "MD5      : $((Get-FileHash $f -Algorithm MD5).Hash)"
  "SHA1     : $((Get-FileHash $f -Algorithm SHA1).Hash)"
  "SHA256   : $((Get-FileHash $f -Algorithm SHA256).Hash)"
  $s = Get-AuthenticodeSignature $f
  "Signature: $($s.Status)"
  if ($s.SignerCertificate) { "Signer   : $($s.SignerCertificate.Subject)" }
  ""
  "--- Mark of the web (where this file came from) ---"
  $z = Get-Content -Path $f -Stream Zone.Identifier -ErrorAction SilentlyContinue
  if ($z) { $z } else { "no zone information - file was not downloaded by a browser" }
  ""
  "Paste the SHA256 above into VirusTotal to identify it:"
  "https://www.virustotal.com/gui/home/search"
}
'@ -Timeout 300)

    return $c

}
