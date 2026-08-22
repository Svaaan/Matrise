# Matrise - Run a command that is not in the catalog.
#
# It is built into a normal catalog entry and handed to Start-MxEntry, so it
# goes through the same policy check, audit line, confirmation and local/remote
# routing as everything else - a typed command is not a way around any of that.

function New-MxCustomEntry {
    param([string]$Shell, [string]$Command)
    [pscustomobject]@{
        Id      = 'custom.run'
        Group   = 'Custom'
        Section = 'Custom'
        Name    = "Custom $Shell command"
        Desc    = 'A command you typed yourself.'
        Shell   = $Shell
        Command = $Command
        # Typed commands are treated as system-changing: they get the "this
        # runs on <machine>, continue?" confirmation rather than running blind.
        Impact  = 'fix'
        Admin   = $false
        Timeout = 300
        Prompt  = ''
        PromptDefault = ''
    }
}

function Show-MxCustomCommand {
    $onRemote = ($script:MxTarget.Mode -eq 'remote')
    $where = $(if ($onRemote) { $script:MxTarget.Name } else { "$env:COMPUTERNAME (this PC)" })

    $d = New-Object System.Windows.Forms.Form
    $d.Text = "Matrise - run a command on $where"
    $d.StartPosition = 'CenterParent'
    $d.ClientSize = New-Object System.Drawing.Size(720, 340)
    $d.MinimumSize = New-Object System.Drawing.Size(600, 300)
    $d.BackColor = $script:MxBg; $d.ForeColor = $script:MxFg

    $head = New-MxLabel -Text "Runs on: $where" -Size 11 -Bold $true `
                        -Color $(if ($onRemote) { $script:MxAccent } else { $script:MxFg })
    $head.SetBounds(16, 12, 690, 24); $d.Controls.Add($head)

    $hint = New-MxLabel -Text 'Type any command. It goes through the same safety check and audit as the built-in ones.' `
                        -Size 9 -Color $script:MxDim
    $hint.SetBounds(16, 38, 690, 18); $d.Controls.Add($hint)

    $rbCmd = New-Object System.Windows.Forms.RadioButton
    $rbCmd.Text = 'Command Prompt (cmd)'; $rbCmd.SetBounds(16, 62, 200, 22)
    $rbCmd.ForeColor = $script:MxFg; $rbCmd.Checked = $true
    $d.Controls.Add($rbCmd)

    $rbPs = New-Object System.Windows.Forms.RadioButton
    $rbPs.Text = 'PowerShell'; $rbPs.SetBounds(224, 62, 160, 22)
    $rbPs.ForeColor = $script:MxFg
    $d.Controls.Add($rbPs)

    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds(16, 90, 688, 160); $box.Multiline = $true
    $box.ScrollBars = 'Vertical'; $box.AcceptsReturn = $true
    $box.BackColor = $script:MxBoardBg; $box.ForeColor = $script:MxFg
    $box.BorderStyle = 'FixedSingle'
    $box.Font = New-Object System.Drawing.Font('Consolas', 11)
    $box.Anchor = 'Top, Left, Right, Bottom'
    $d.Controls.Add($box)

    $run = New-MxDlgButton -Text 'Run' -W 110
    $run.SetBounds(484, 262, 110, 34)
    $run.Anchor = 'Bottom, Right'
    $d.Controls.Add($run)

    $cancel = New-MxDlgButton -Text 'Cancel' -W 100 -Result 'Cancel'
    $cancel.SetBounds(604, 262, 100, 34)
    $cancel.Anchor = 'Bottom, Right'
    $d.Controls.Add($cancel)
    $d.CancelButton = $cancel

    $run.Add_Click({
        $cmd = $box.Text.Trim()
        if (-not $cmd) { return }
        $shell = $(if ($rbPs.Checked) { 'ps' } else { 'cmd' })
        $d.Tag = New-MxCustomEntry -Shell $shell -Command $cmd
        $d.DialogResult = 'OK'
        $d.Close()
    })

    $d.Add_Shown({ Hide-MxPop; Show-MxDialogFront -Dialog $d; $box.Focus() })
    $r = $d.ShowDialog($script:MxForm)
    $entry = $d.Tag
    $d.Dispose()

    if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $entry) {
        Start-MxEntry -Entry $entry
    }
}
