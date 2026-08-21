# Matrise - Request and approval windows
#
# Two dialogs:
#   Show-MxPolicyStop     what happened and what you can do about it
#   Show-MxRequestsWindow the queue, the conversation, and the decision
#
# The approve and deny buttons are shown to everyone, because hiding them is
# theatre. Whether they work is decided by the ACL on the grant folder, and if
# it says no, the error says so plainly.

function New-MxDlgButton {
    param([string]$Text, [int]$W = 110, $Dialog = $null, [string]$Result = '')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $W; $b.Height = 30
    $b.FlatStyle = 'Flat'; $b.BackColor = $script:MxPanel; $b.ForeColor = $script:MxFg
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 66, 78)
    if ($Result) { $b.DialogResult = $Result }
    $b
}

function New-MxDlgText {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '', [bool]$ReadOnly = $false, [bool]$Mono = $true)
    $t = New-Object System.Windows.Forms.TextBox
    $t.SetBounds($X, $Y, $W, $H)
    $t.Multiline = ($H -gt 34)
    $t.ScrollBars = $(if ($H -gt 34) { 'Vertical' } else { 'None' })
    $t.ReadOnly = $ReadOnly
    $t.Text = $Text
    $t.BackColor = $script:MxBoardBg
    $t.ForeColor = $script:MxFg
    $t.BorderStyle = 'FixedSingle'
    $t.Font = New-Object System.Drawing.Font($(if ($Mono) { 'Consolas' } else { 'Segoe UI' }), 9.5)
    $t
}

# Shown instead of running, when policy says no.
function Show-MxPolicyStop {
    param($Entry, $Permission, $Policy)

    $canAsk = ($Permission.Action -eq 'requireApproval')

    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Matrise - blocked by policy'
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MinimizeBox = $false; $d.MaximizeBox = $false
    $d.ClientSize = New-Object System.Drawing.Size(660, 430)
    $d.BackColor = $script:MxBg; $d.ForeColor = $script:MxFg

    $title = New-MxLabel -Text $(if ($canAsk) { 'This one needs approval first' } else { 'Security policy blocks this' }) `
                         -Size 12 -Bold $true -Color $(if ($canAsk) { $script:MxFix } else { $script:MxHeavy })
    $title.SetBounds(16, 14, 620, 26)
    $d.Controls.Add($title)

    $body = @(
        "Command : $($Entry.Name)",
        "Target  : $(Get-MatriseTargetLabel -Target $script:MxTarget)",
        "Rule    : $($Permission.Rule)",
        '',
        'WHY',
        (Format-MatriseWrap -Text $Permission.Reason -Width 76),
        '',
        "Policy  : $($Policy.policyName)",
        "Contact : $($Policy.contact)",
        '',
        $(if ($canAsk) {
            'You can ask Security to open this up for a limited time. Say what you' + "`r`n" +
            'have already tried and why this is the next step - a request with a' + "`r`n" +
            'real justification gets answered; "please approve" does not.'
        } else {
            'This is a hard block. It will not open on request. If you believe the' + "`r`n" +
            'rule is wrong for this case, take it to the contact above rather than' + "`r`n" +
            'working around it.'
        })
    ) -join "`r`n"

    $tb = New-MxDlgText -X 16 -Y 46 -W 624 -H 250 -Text $body -ReadOnly $true
    $d.Controls.Add($tb)

    $ok = New-MxDlgButton -Text 'Close' -W 110 -Result 'Cancel'
    $ok.SetBounds(528, 380, 110, 30)
    $d.Controls.Add($ok)
    $d.CancelButton = $ok

    if ($canAsk) {
        $lbl = New-MxLabel -Text 'Justification' -Size 9 -Color $script:MxDim
        $lbl.SetBounds(16, 302, 120, 18)
        $d.Controls.Add($lbl)

        $just = New-MxDlgText -X 16 -Y 322 -W 400 -H 48 -Mono $false
        $d.Controls.Add($just)

        $mlbl = New-MxLabel -Text 'Minutes' -Size 9 -Color $script:MxDim
        $mlbl.SetBounds(430, 302, 80, 18)
        $d.Controls.Add($mlbl)

        $mins = New-Object System.Windows.Forms.NumericUpDown
        $mins.SetBounds(430, 322, 90, 26)
        $mins.Minimum = 15; $mins.Maximum = 480; $mins.Value = 60; $mins.Increment = 15
        $mins.BackColor = $script:MxBoardBg; $mins.ForeColor = $script:MxFg
        $d.Controls.Add($mins)

        $send = New-MxDlgButton -Text 'Send request' -W 130
        $send.SetBounds(388, 380, 130, 30)
        $send.Add_Click({
            if ($just.Text.Trim().Length -lt 15) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    'Write a real justification - at least a sentence. Whoever reads this has no idea what you are looking at.',
                    'Matrise', 'OK', 'Warning')
                return
            }
            try {
                $req = New-MatriseRequest -Policy $Policy -Entry $Entry `
                          -TargetName $script:MxTarget.Name -Justification $just.Text.Trim() `
                          -RequestedMinutes ([int]$mins.Value) -Permission $Permission
                Write-MatriseAudit -WorkDir $script:MxWorkDir -Policy $Policy -Action 'request-raised' `
                          -Entry $Entry -Target $script:MxTarget -Permission $Permission -Note $req.id | Out-Null
                [void][System.Windows.Forms.MessageBox]::Show(
                    "Request $($req.id) sent.`r`n`r`nOpen Requests to follow it and talk to whoever picks it up.",
                    'Matrise', 'OK', 'Information')
                $d.DialogResult = 'OK'
                $d.Close()
            }
            catch {
                [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Matrise - could not send', 'OK', 'Error')
            }
        })
        $d.Controls.Add($send)
    }

    [void]$d.ShowDialog($script:MxForm)
    $d.Dispose()
}

# The queue, the thread, and the decision.
function Show-MxRequestsWindow {
    param($Policy)

    $store = Get-MatriseRequestStore -Policy $Policy
    if (-not (Test-MatriseStoreReachable $store)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "The request store is not reachable:`r`n`r`n  $store`r`n`r`nCheck the policy file and that you are on the corporate network.",
            'Matrise - requests', 'OK', 'Warning')
        return
    }
    $canApprove = Test-MatriseCanApprove -Policy $Policy

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Matrise - access requests    $(if ($canApprove) { '[you can approve]' } else { '[read only - you cannot approve your own]' })"
    $f.StartPosition = 'CenterParent'
    $f.ClientSize = New-Object System.Drawing.Size(1180, 700)
    $f.MinimumSize = New-Object System.Drawing.Size(900, 560)
    $f.BackColor = $script:MxBg; $f.ForeColor = $script:MxFg

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.SplitterWidth = 6
    $split.BackColor = [System.Drawing.Color]::FromArgb(58, 64, 76)

    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true
    $list.MultiSelect = $false; $list.HideSelection = $false
    $list.BackColor = $script:MxPanel; $list.ForeColor = $script:MxFg
    $list.BorderStyle = 'None'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    [void]$list.Columns.Add('Status', 80)
    [void]$list.Columns.Add('Command', 190)
    [void]$list.Columns.Add('Target', 110)
    [void]$list.Columns.Add('Raised by', 150)
    $split.Panel1.Controls.Add($list)

    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Fill'; $right.BackColor = $script:MxBg

    $thread = New-MxDlgText -X 0 -Y 0 -W 10 -H 100 -ReadOnly $true
    $thread.Dock = 'Fill'
    $thread.BorderStyle = 'None'

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 108; $bottom.BackColor = $script:MxBg

    $msg = New-MxDlgText -X 8 -Y 6 -W 520 -H 60 -Mono $false
    $msg.Anchor = 'Top, Left, Right'
    $bottom.Controls.Add($msg)

    $btnSay = New-MxDlgButton -Text 'Add comment' -W 120
    $btnSay.SetBounds(8, 72, 120, 30)
    $bottom.Controls.Add($btnSay)

    $btnApprove = New-MxDlgButton -Text 'Approve' -W 110
    $btnApprove.SetBounds(140, 72, 110, 30)
    $btnApprove.ForeColor = [System.Drawing.Color]::FromArgb(124, 222, 146)
    $bottom.Controls.Add($btnApprove)

    $btnDeny = New-MxDlgButton -Text 'Deny' -W 90
    $btnDeny.SetBounds(258, 72, 90, 30)
    $btnDeny.ForeColor = $script:MxHeavy
    $bottom.Controls.Add($btnDeny)

    $mlbl = New-MxLabel -Text 'minutes' -Size 9 -Color $script:MxDim
    $mlbl.SetBounds(452, 78, 60, 18)
    $bottom.Controls.Add($mlbl)

    $mins = New-Object System.Windows.Forms.NumericUpDown
    $mins.SetBounds(360, 74, 86, 26)
    $mins.Minimum = 15; $mins.Maximum = 480; $mins.Value = 60; $mins.Increment = 15
    $mins.BackColor = $script:MxBoardBg; $mins.ForeColor = $script:MxFg
    $bottom.Controls.Add($mins)

    $btnRefresh = New-MxDlgButton -Text 'Refresh' -W 90
    $btnRefresh.SetBounds(520, 72, 90, 30)
    $bottom.Controls.Add($btnRefresh)

    $right.Controls.Add($thread)
    $right.Controls.Add($bottom)
    $split.Panel2.Controls.Add($right)
    $f.Controls.Add($split)

    $script:MxReqCurrent = $null

    $reload = {
        $sel = $null
        if ($list.SelectedItems.Count -gt 0) { $sel = $list.SelectedItems[0].Tag.id }
        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($r in (Get-MatriseRequests -Policy $Policy)) {
            $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList ([string]$r.status)
            [void]$it.SubItems.Add([string]$r.entryId)
            [void]$it.SubItems.Add([string]$r.target)
            [void]$it.SubItems.Add([string]$r.requestedBy)
            switch ($r.status) {
                'pending'  { $it.ForeColor = $script:MxFix }
                'approved' { $it.ForeColor = [System.Drawing.Color]::FromArgb(124, 222, 146) }
                'denied'   { $it.ForeColor = $script:MxHeavy }
            }
            $it.Tag = $r
            [void]$list.Items.Add($it)
        }
        $list.EndUpdate()
        if ($sel) {
            foreach ($i in $list.Items) { if ($i.Tag.id -eq $sel) { $i.Selected = $true } }
        } elseif ($list.Items.Count -gt 0) {
            $list.Items[0].Selected = $true
        }
    }

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedItems.Count -eq 0) { $thread.Text = ''; $script:MxReqCurrent = $null; return }
        $script:MxReqCurrent = $list.SelectedItems[0].Tag
        $thread.Text = Format-MatriseRequestThread -Request $script:MxReqCurrent
    })

    $btnRefresh.Add_Click($reload)

    $btnSay.Add_Click({
        if (-not $script:MxReqCurrent) { return }
        if ($msg.Text.Trim().Length -eq 0) { return }
        try {
            Add-MatriseRequestComment -Policy $Policy -Id $script:MxReqCurrent.id -Text $msg.Text.Trim() | Out-Null
            $msg.Text = ''
            & $reload
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Matrise', 'OK', 'Error')
        }
    })

    $decide = {
        param($what)
        if (-not $script:MxReqCurrent) { return }
        if (-not $canApprove) {
            [void][System.Windows.Forms.MessageBox]::Show(
                ("You do not have write access to the grant folder, so you cannot make this decision.`r`n`r`n" +
                 "  $($Policy.grantStore)`r`n`r`n" +
                 'That is the actual control - Matrise is not deciding this, the share permissions are. ' +
                 'If you should be an approver, ask for membership of the group that owns that folder.'),
                'Matrise - not an approver', 'OK', 'Warning')
            return
        }
        $verb = $(if ($what -eq 'approved') { 'Approve' } else { 'Deny' })
        $conf = [System.Windows.Forms.MessageBox]::Show(
            ("$verb request $($script:MxReqCurrent.id)?`r`n`r`n" +
             "Command : $($script:MxReqCurrent.entryName)`r`n" +
             "Target  : $($script:MxReqCurrent.target)`r`n" +
             "For     : $($script:MxReqCurrent.requestedBy)" +
             $(if ($what -eq 'approved') { "`r`nWindow  : $([int]$mins.Value) minutes" } else { '' })),
            'Matrise', 'YesNo', 'Question')
        if ($conf -ne 'Yes') { return }
        try {
            Set-MatriseRequestDecision -Policy $Policy -Id $script:MxReqCurrent.id -Decision $what `
                -Minutes ([int]$mins.Value) -Comment $msg.Text.Trim() | Out-Null
            $msg.Text = ''
            & $reload
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Matrise', 'OK', 'Error')
        }
    }
    $btnApprove.Add_Click({ & $decide 'approved' })
    $btnDeny.Add_Click({ & $decide 'denied' })

    # The conversation is only useful if it arrives. Cheap poll of a file share.
    $poll = New-Object System.Windows.Forms.Timer
    $poll.Interval = 15000
    $poll.Add_Tick($reload)

    $f.Add_Shown({
        try { $split.SplitterDistance = 540; $split.Panel1MinSize = 320; $split.Panel2MinSize = 380 } catch { }
        & $reload
        $poll.Start()
    })
    $f.Add_FormClosing({ $poll.Stop(); $poll.Dispose() })

    [void]$f.ShowDialog($script:MxForm)
    $f.Dispose()
}
