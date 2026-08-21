$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'Matrise - Disk health + free space'
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  MATRISE  |  Disk health + free space' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'COMMAND:' -ForegroundColor Yellow
$matriseCmdText = @'
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, HealthStatus, OperationalStatus,
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize | Out-String -Width 300
Get-Volume | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
  @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
  @{n='FreePct';e={ if ($_.Size) { [math]::Round(100*$_.SizeRemaining/$_.Size,1) } else { 0 } }} |
  Format-Table -AutoSize | Out-String -Width 300
'@
$matriseCmdText -split "`r?`n" | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkGray }
Write-Host ''
Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, HealthStatus, OperationalStatus,
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}} | Format-Table -AutoSize | Out-String -Width 300
Get-Volume | Where-Object { $_.DriveLetter } | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus,
  @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
  @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
  @{n='FreePct';e={ if ($_.Size) { [math]::Round(100*$_.SizeRemaining/$_.Size,1) } else { 0 } }} |
  Format-Table -AutoSize | Out-String -Width 300

Write-Host ''
Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host 'Finished. This window stays open - type exit to close it.' -ForegroundColor Green