# Matrise - Devices on your network.
#
# The scan finds what is here; this remembers it. A known-device registry
# (devices.json) stores a friendly name and owner per MAC, so future scans show
# names instead of hex - and anything whose MAC is NOT in the registry stands
# out as new, which is a quiet way to notice a device you did not put there.

$script:MatriseOui = @{
    '50-EB-F6'='ASUS'; '1C-86-9A'='Intel'; 'F0-EF-86'='Google'; 'C8-48-05'='Samsung'
    '1C-69-7A'='Intel'; 'DC-A6-32'='Raspberry Pi'; 'B8-27-EB'='Raspberry Pi'
    'E4-5F-01'='Raspberry Pi'; '3C-22-FB'='Apple'; 'A4-83-E7'='Apple'; 'F0-18-98'='Apple'
    '00-1A-11'='Google'; 'D8-3A-DD'='Google'; '00-17-88'='Philips Hue'
    'EC-FA-BC'='Espressif/IoT'; '2C-F4-32'='Espressif/IoT'; '00-50-56'='VMware'
    '08-00-27'='VirtualBox'
}

# Common ports, and the plain-word service each one means.
# Plain hashtable, NOT [ordered]: an OrderedDictionary indexed by an int does
# positional access (item #53), not key lookup, so names would come back blank.
$script:MatrisePortNames = @{
    22   = 'SSH'; 53 = 'DNS'; 80 = 'web'; 139 = 'file sharing'; 443 = 'web (secure)'
    445  = 'file sharing'; 548 = 'Apple file share'; 631 = 'printing'; 1883 = 'smart-home (MQTT)'
    3389 = 'Remote Desktop'; 5900 = 'screen share (VNC)'; 5985 = 'remote management'
    8009 = 'Chromecast'; 8080 = 'web (alt)'; 9100 = 'printer'; 32400 = 'Plex media'
    62078= 'iPhone/iPad sync'
}

function ConvertTo-MatriseMac {
    param([string]$Mac)
    ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper() -replace '(..)(?=.)', '$1-'
}

# ------------------------------------------------------------- the scan ----
function Invoke-MatriseDeviceScan {
    # Ping every address on the local /24 so devices answer at layer 2, then
    # read the neighbour table. Returns one object per device.
    $bases = @()
    foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
        $p = $a.IPAddress.Split('.'); $bases += "$($p[0]).$($p[1]).$($p[2])."
    }
    $bases = $bases | Select-Object -Unique

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

    $rows = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.LinkLayerAddress -match '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' -and
        $_.LinkLayerAddress -notmatch '^(00-00-00-00-00-00|FF-FF-FF-FF-FF-FF)$' -and
        $_.LinkLayerAddress -notlike '01-00-5E-*' -and
        $_.IPAddress -notlike '224.*' -and $_.IPAddress -notlike '239.*' -and
        $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '255.255.255.255'
    }

    $macByIp = [ordered]@{}
    foreach ($ip in $me) {
        $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).MacAddress
        if ($mac) { $macByIp[$ip] = $mac }
    }
    foreach ($r in $rows) { if (-not $macByIp.Contains($r.IPAddress)) { $macByIp[$r.IPAddress] = $r.LinkLayerAddress } }

    $ips = @($macByIp.Keys)
    $dns = @{}
    foreach ($ip in $ips) { try { $dns[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch { } }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($dns.Values), 3000) } catch { }

    foreach ($ip in ($ips | Sort-Object { try { [version]$_ } catch { [version]'0.0.0.0' } })) {
        $name = ''
        try { if ($dns[$ip].Status -eq 'RanToCompletion') { $name = ($dns[$ip].Result.HostName -split '\.')[0] } } catch { }
        $note = ''
        if ($me -contains $ip) { $note = 'this PC' } elseif ($ip -eq $gw) { $note = 'gateway/router' }
        $mac = ConvertTo-MatriseMac $macByIp[$ip]
        $vendor = ''; if ($mac.Length -ge 8) { $vendor = $script:MatriseOui[$mac.Substring(0,8)] }
        [pscustomobject]@{
            IP = $ip; MAC = $mac; Vendor = $vendor; DnsName = $name; Note = $note
        }
    }
}

# ------------------------------------------------------- known devices -----
function Get-MatriseDeviceStorePath { param([string]$WorkDir) Join-Path $WorkDir 'devices.json' }

function Get-MatriseKnownDevices {
    param([string]$WorkDir)
    $p = Get-MatriseDeviceStorePath -WorkDir $WorkDir
    $map = @{}
    if (Test-Path $p) {
        try {
            $o = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($prop in $o.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
        } catch { }
    }
    $map
}

function Save-MatriseKnownDevices {
    param([string]$WorkDir, $Map)
    $p = Get-MatriseDeviceStorePath -WorkDir $WorkDir
    $obj = [pscustomobject]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Map[$k] }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $p -Encoding UTF8
}

function Set-MatriseDeviceLabel {
    param([string]$WorkDir, [string]$Mac, [string]$Name, [string]$Owner)
    $m = ConvertTo-MatriseMac $Mac
    $map = Get-MatriseKnownDevices -WorkDir $WorkDir
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($map.ContainsKey($m)) {
        $e = $map[$m]
        $e.name = $Name; $e.owner = $Owner; $e.lastSeenUtc = $now
    } else {
        $map[$m] = [pscustomobject]@{ name = $Name; owner = $Owner; firstSeenUtc = $now; lastSeenUtc = $now }
    }
    Save-MatriseKnownDevices -WorkDir $WorkDir -Map $map
    $map[$m]
}

function Remove-MatriseDeviceLabel {
    param([string]$WorkDir, [string]$Mac)
    $m = ConvertTo-MatriseMac $Mac
    $map = Get-MatriseKnownDevices -WorkDir $WorkDir
    if ($map.ContainsKey($m)) { $map.Remove($m); Save-MatriseKnownDevices -WorkDir $WorkDir -Map $map; return $true }
    $false
}

# Records that these MACs were seen now (bumps lastSeen; sets firstSeen once),
# WITHOUT giving them a label - so "known" stays a deliberate choice, not
# something that happens just because a device appeared.
function Update-MatriseDeviceSeen {
    param([string]$WorkDir, $Devices)
    $map = Get-MatriseKnownDevices -WorkDir $WorkDir
    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($d in $Devices) {
        $m = $d.MAC
        if ($map.ContainsKey($m)) { $map[$m].lastSeenUtc = $now }
    }
    Save-MatriseKnownDevices -WorkDir $WorkDir -Map $map
}

# Merge a scan with the registry: attach saved name/owner, and mark whether each
# device is one you have named before.
function Join-MatriseDevices {
    param([string]$WorkDir, $Scan)
    $map = Get-MatriseKnownDevices -WorkDir $WorkDir
    foreach ($d in $Scan) {
        $known = $map.ContainsKey($d.MAC)
        $label = ''
        $owner = ''
        if ($known) { $label = [string]$map[$d.MAC].name; $owner = [string]$map[$d.MAC].owner }
        [pscustomobject]@{
            IP     = $d.IP
            MAC    = $d.MAC
            Name   = $(if ($label) { $label } else { $d.DnsName })
            Owner  = $owner
            Vendor = $d.Vendor
            Note   = $d.Note
            Known  = $known
            DnsName= $d.DnsName
        }
    }
}

# ------------------------------------------------------- live + services ---
function Test-MatriseDevicesOnline {
    param([string[]]$Ips, [int]$TimeoutMs = 600)
    $t = @{}
    foreach ($ip in $Ips) {
        $p = New-Object System.Net.NetworkInformation.Ping
        $t[$ip] = $p.SendPingAsync($ip, $TimeoutMs)
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($t.Values), ($TimeoutMs + 500)) } catch { }
    $out = @{}
    foreach ($ip in $Ips) {
        $ok = $false
        try { $ok = ($t[$ip].Status -eq 'RanToCompletion' -and $t[$ip].Result.Status -eq 'Success') } catch { }
        $out[$ip] = $ok
    }
    $out
}

function Get-MatriseDeviceServices {
    param([string]$Ip, [int]$TimeoutMs = 500)
    $ports = @($script:MatrisePortNames.Keys)
    $clients = @{}
    foreach ($p in $ports) {
        $c = New-Object System.Net.Sockets.TcpClient
        $clients[$p] = @{ Client = $c; Task = $c.ConnectAsync($Ip, $p) }
    }
    Start-Sleep -Milliseconds $TimeoutMs
    $open = New-Object System.Collections.ArrayList
    foreach ($p in $ports) {
        $ok = $false
        try { $ok = $clients[$p].Client.Connected } catch { }
        try { $clients[$p].Client.Close() } catch { }
        # [ordered] keys are ints; index with an int or the lookup misses.
        if ($ok) { [void]$open.Add([pscustomobject]@{ Port = [int]$p; Service = $script:MatrisePortNames[[int]$p] }) }
    }
    # Return a real array (not the ArrayList wrapped by the comma operator, which
    # would reach the caller as a single object).
    @($open.ToArray())
}

# Which URL, if any, this device probably serves a page on.
function Get-MatriseDeviceWebUrl {
    param([string]$Ip)
    $svc = Get-MatriseDeviceServices -Ip $Ip -TimeoutMs 500
    if ($svc | Where-Object { $_.Port -eq 443 })  { return "https://$Ip" }
    if ($svc | Where-Object { $_.Port -eq 80 })   { return "http://$Ip" }
    if ($svc | Where-Object { $_.Port -eq 8080 })  { return "http://${Ip}:8080" }
    ''
}
