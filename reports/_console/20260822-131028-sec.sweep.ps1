$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'Matrise - FULL SWEEP (start here)'
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  MATRISE  |  FULL SWEEP (start here)' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'COMMAND:' -ForegroundColor Yellow
$matriseCmdText = @'
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
'@
$matriseCmdText -split "`r?`n" | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkGray }
Write-Host ''
Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

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

Write-Host ''
Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host 'Finished. This window stays open - type exit to close it.' -ForegroundColor Green