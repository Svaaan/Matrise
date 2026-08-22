# Matrise - the Devices window.
#
# A living list of what is on your network. Name the ones you recognise; any
# device you have never named is flagged, so a stranger on the network stands
# out. Live online dots, and per-device actions (open its page, see what it
# exposes).

# Runs the scan + online check in its own runspace and hands the device objects
# back through a synchronized bag the UI polls. Not the board-oriented
# Start-MxBackground - this needs structured data, not text lines.
function Start-MxDeviceScan {
    param([string]$LibDir, [string]$WorkDir, [switch]$StatusOnly, $KnownIps)

    $state = [hashtable]::Synchronized(@{ Done = $false; Devices = @(); Status = @{}; Error = '' })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs

    [void]$ps.AddScript({
        param($libDir, $workDir, $statusOnly, $knownIps, $state)
        try {
            . (Join-Path $libDir 'Devices.ps1')
            if ($statusOnly) {
                $state['Status'] = (Test-MatriseDevicesOnline -Ips @($knownIps))
            }
            else {
                $scan   = @(Invoke-MatriseDeviceScan)
                $online = Test-MatriseDevicesOnline -Ips @($scan | ForEach-Object { $_.IP })
                $joined = @(Join-MatriseDevices -WorkDir $workDir -Scan $scan)
                foreach ($d in $joined) {
                    $d | Add-Member -NotePropertyName Online -NotePropertyValue ([bool]$online[$d.IP]) -Force
                }
                Update-MatriseDeviceSeen -WorkDir $workDir -Devices $joined
                $state['Devices'] = $joined
            }
        }
        catch { $state['Error'] = $_.Exception.Message }
        finally { $state['Done'] = $true }
    })
    [void]$ps.AddArgument($LibDir).AddArgument($WorkDir).AddArgument([bool]$StatusOnly).AddArgument($KnownIps).AddArgument($state)

    [pscustomobject]@{ State = $state; Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke() }
}

function Stop-MxDeviceScan {
    param($Job)
    if (-not $Job) { return }
    try { $Job.Ps.Dispose() } catch { }
    try { $Job.Rs.Close(); $Job.Rs.Dispose() } catch { }
}

function Show-MxDevicesWindow {

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Matrise - devices on your network'
    $f.StartPosition = 'CenterParent'
    $f.ClientSize = New-Object System.Drawing.Size(900, 560)
    $f.MinimumSize = New-Object System.Drawing.Size(760, 460)
    $f.BackColor = $script:MxBg; $f.ForeColor = $script:MxFg

    $head = New-MxLabel -Text 'Devices on your network' -Size 12 -Bold $true
    $head.SetBounds(16, 12, 600, 24); $f.Controls.Add($head)

    $sub = New-MxLabel -Text 'Name the ones you know. Anything left as NEW is a device you have not named - worth a look if you did not expect it.' `
                       -Size 9 -Color $script:MxDim
    $sub.SetBounds(16, 38, 868, 18); $f.Controls.Add($sub)

    $list = New-Object System.Windows.Forms.ListView
    $list.SetBounds(16, 62, 868, 400)
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false
    $list.HideSelection = $false; $list.GridLines = $false
    $list.BackColor = $script:MxPanel; $list.ForeColor = $script:MxFg; $list.BorderStyle = 'None'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $list.Anchor = 'Top, Left, Right, Bottom'
    [void]$list.Columns.Add('', 24)          # online dot
    [void]$list.Columns.Add('Name', 190)
    [void]$list.Columns.Add('Owner', 110)
    [void]$list.Columns.Add('IP', 120)
    [void]$list.Columns.Add('MAC', 150)
    [void]$list.Columns.Add('Maker', 110)
    [void]$list.Columns.Add('', 60)          # NEW tag
    $f.Controls.Add($list)

    $status = New-MxLabel -Text 'Scanning...' -Size 9 -Color $script:MxDim
    $status.SetBounds(16, 470, 500, 18); $status.Anchor = 'Bottom, Left'
    $f.Controls.Add($status)

    $y = 498
    $btnScan = New-MxDlgButton -Text 'Rescan' -W 90
    $btnScan.SetBounds(16, $y, 90, 30); $btnScan.Anchor = 'Bottom, Left'; $f.Controls.Add($btnScan)

    $btnName = New-MxDlgButton -Text 'Name this...' -W 110
    $btnName.SetBounds(112, $y, 110, 30); $btnName.Anchor = 'Bottom, Left'; $f.Controls.Add($btnName)

    $btnForget = New-MxDlgButton -Text 'Forget' -W 80
    $btnForget.SetBounds(228, $y, 80, 30); $btnForget.Anchor = 'Bottom, Left'; $f.Controls.Add($btnForget)

    $btnWeb = New-MxDlgButton -Text 'Open its page' -W 118
    $btnWeb.SetBounds(320, $y, 118, 30); $btnWeb.Anchor = 'Bottom, Left'; $f.Controls.Add($btnWeb)

    $btnPorts = New-MxDlgButton -Text 'What it exposes' -W 128
    $btnPorts.SetBounds(444, $y, 128, 30); $btnPorts.Anchor = 'Bottom, Left'; $f.Controls.Add($btnPorts)

    $btnClose = New-MxDlgButton -Text 'Close' -W 90 -Result 'Cancel'
    $btnClose.SetBounds(794, $y, 90, 30); $btnClose.Anchor = 'Bottom, Right'; $f.Controls.Add($btnClose)
    $f.CancelButton = $btnClose

    $script:MxDevState = [pscustomobject]@{
        List = $list; Status = $status; Devices = @()
        ScanJob = $null; StatJob = $null; Poll = $null; LibDir = (Join-Path $script:MxWorkDir 'lib')
    }
    $D = $script:MxDevState

    $render = {
        $S = $script:MxDevState
        $S.List.BeginUpdate(); $S.List.Items.Clear()
        foreach ($d in $S.Devices) {
            $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList ($(if ($d.Online) { [char]0x25CF } else { '' }))
            [void]$it.SubItems.Add([string]$d.Name)
            [void]$it.SubItems.Add([string]$d.Owner)
            [void]$it.SubItems.Add([string]$d.IP)
            [void]$it.SubItems.Add([string]$d.MAC)
            [void]$it.SubItems.Add([string]$d.Vendor)
            [void]$it.SubItems.Add($(if ($d.Known) { '' } else { 'NEW' }))
            # The online dot is drawn green via a per-item colour only on col 0;
            # ListView colours whole rows, so instead use the NEW flag for the
            # row colour (the security signal) and let the dot glyph carry online.
            if (-not $d.Known) { $it.ForeColor = $script:MxFix }
            elseif (-not $d.Online) { $it.ForeColor = $script:MxDim }
            $it.UseItemStyleForSubItems = $true
            $it.Tag = $d
            [void]$S.List.Items.Add($it)
        }
        $S.List.EndUpdate()
        $new = @($S.Devices | Where-Object { -not $_.Known }).Count
        $on  = @($S.Devices | Where-Object { $_.Online }).Count
        $S.Status.Text = "$(@($S.Devices).Count) devices - $on online, $new not named yet"
        $S.Status.ForeColor = $(if ($new -gt 0) { $script:MxFix } else { $script:MxDim })
    }

    $beginScan = {
        param([bool]$statusOnly)
        $S = $script:MxDevState
        if ($S.ScanJob) { return }
        if ($statusOnly) {
            if (@($S.Devices).Count -eq 0) { return }
            $S.ScanJob = Start-MxDeviceScan -LibDir $S.LibDir -WorkDir $script:MxWorkDir -StatusOnly `
                            -KnownIps @($S.Devices | ForEach-Object { $_.IP })
        } else {
            $S.Status.Text = 'Scanning the network (a few seconds)...'; $S.Status.ForeColor = $script:MxDim
            $S.ScanJob = Start-MxDeviceScan -LibDir $S.LibDir -WorkDir $script:MxWorkDir
        }
        $S.ScanJob | Add-Member -NotePropertyName StatusOnly -NotePropertyValue $statusOnly -Force
        $S.Poll.Start()
    }

    $poll = New-Object System.Windows.Forms.Timer
    $poll.Interval = 250
    $poll.Add_Tick({
        $S = $script:MxDevState
        if (-not $S.ScanJob) { $S.Poll.Stop(); return }
        if (-not $S.ScanJob.State['Done']) { return }

        $S.Poll.Stop()
        $job = $S.ScanJob; $S.ScanJob = $null
        if ($job.State['Error']) {
            $S.Status.Text = "scan error: $($job.State['Error'])"; $S.Status.ForeColor = $script:MxFix
        }
        elseif ($job.StatusOnly) {
            $st = $job.State['Status']
            foreach ($d in $S.Devices) { if ($st.ContainsKey($d.IP)) { $d.Online = [bool]$st[$d.IP] } }
            & $render
        }
        else {
            $S.Devices = @($job.State['Devices'])
            & $render
        }
        Stop-MxDeviceScan -Job $job
    })
    $D.Poll = $poll

    $selected = { if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag } else { $null } }

    $btnScan.Add_Click({ & $beginScan $false })

    $btnName.Add_Click({
        $d = & $selected; if (-not $d) { return }
        $name = Show-MxInputDialog -Title 'Name this device' `
                    -Question "What is $($d.IP) ($($d.Vendor))? Give it a name you will recognise." -Default $d.Name
        if ($null -eq $name) { return }
        $owner = Show-MxInputDialog -Title 'Whose is it?' -Question 'Owner (optional) - e.g. a person or a room.' -Default $d.Owner
        if ($null -eq $owner) { $owner = '' }
        [void](Set-MatriseDeviceLabel -WorkDir $script:MxWorkDir -Mac $d.MAC -Name $name.Trim() -Owner $owner.Trim())
        $d.Name = $name.Trim(); $d.Owner = $owner.Trim(); $d.Known = $true
        & $render
    })

    $btnForget.Add_Click({
        $d = & $selected; if (-not $d) { return }
        if (-not $d.Known) { return }
        [void](Remove-MatriseDeviceLabel -WorkDir $script:MxWorkDir -Mac $d.MAC)
        $d.Known = $false; $d.Owner = ''; $d.Name = $d.DnsName
        & $render
    })

    $btnWeb.Add_Click({
        $d = & $selected; if (-not $d) { return }
        $script:MxDevState.Status.Text = "Looking for a web page on $($d.IP)..."
        $f.Refresh()
        $url = Get-MatriseDeviceWebUrl -Ip $d.IP
        if ($url) { Start-Process $url; $script:MxDevState.Status.Text = "opened $url" }
        else {
            $script:MxDevState.Status.Text = "$($d.IP) does not seem to serve a web page"
            [void][System.Windows.Forms.MessageBox]::Show(
                "$($d.IP) is not serving a web page on the usual ports (80/443/8080). Not every device has one.",
                'Matrise', 'OK', 'Information')
        }
    })

    $btnPorts.Add_Click({
        $d = & $selected; if (-not $d) { return }
        $script:MxDevState.Status.Text = "Checking what $($d.IP) exposes..."
        $f.Refresh()
        $svc = @(Get-MatriseDeviceServices -Ip $d.IP -TimeoutMs 600)
        $name = $(if ($d.Name) { $d.Name } else { $d.IP })
        if (@($svc).Count) {
            $lines = ($svc | Sort-Object Port | ForEach-Object { "   {0,-6} {1}" -f $_.Port, $_.Service }) -join "`r`n"
            [void][System.Windows.Forms.MessageBox]::Show(
                "$name ($($d.IP)) is listening on:`r`n`r`n$lines`r`n`r`nThese are doors other devices on the network can knock on.",
                'Matrise - what it exposes', 'OK', 'Information')
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                "$name ($($d.IP)) has none of the common ports open - it is not offering services to the network.",
                'Matrise - what it exposes', 'OK', 'Information')
        }
        $script:MxDevState.Status.Text = "$(@($svc).Count) open port(s) on $($d.IP)"
    })

    $list.Add_DoubleClick({ $btnName.PerformClick() })

    # Re-check who is online every 8 seconds - cheap, and only if nothing else
    # is scanning.
    $live = New-Object System.Windows.Forms.Timer
    $live.Interval = 8000
    $live.Add_Tick({ if (-not $script:MxDevState.ScanJob) { & $beginScan $true } })

    $f.Add_Shown({
        Hide-MxPop
        Show-MxDialogFront -Dialog $f
        & $beginScan $false
        $live.Start()
    })
    $f.Add_FormClosing({
        $live.Stop(); $live.Dispose()
        $S = $script:MxDevState
        if ($S.Poll) { $S.Poll.Stop(); $S.Poll.Dispose() }
        if ($S.ScanJob) { Stop-MxDeviceScan -Job $S.ScanJob }
    })

    [void]$f.ShowDialog($script:MxForm)
    $f.Dispose()
}
