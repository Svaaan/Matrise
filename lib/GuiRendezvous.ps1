# Matrise - the Guest and Host windows
#
#   Host  : "someone may help this PC"   - waits, shows who is asking, approves
#   Guest : "I want to help a PC"        - finds hosts, asks, receives
#
# Neither side types or pastes anything. The only thing a person reads is the
# six-digit number, and only to confirm it matches on both screens.

function New-MxRvLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Size = 9, [bool]$Bold = $false, $Color = $null)
    $l = New-MxLabel -Text $Text -Size $Size -Bold $Bold -Color $Color
    $l.SetBounds($X, $Y, $W, $H)
    $l
}

# =========================================================================
#  HOST - the PC that wants help
# =========================================================================
function Show-MxHostWindow {

    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Matrise - let someone help this PC'
    $d.StartPosition = 'CenterParent'
    $d.ClientSize = New-Object System.Drawing.Size(720, 520)
    $d.MinimumSize = New-Object System.Drawing.Size(660, 470)
    $d.BackColor = $script:MxBg; $d.ForeColor = $script:MxFg

    $d.Controls.Add((New-MxRvLabel 'Waiting for someone to connect' 16 14 660 26 12 $true))
    $d.Controls.Add((New-MxRvLabel (@(
        'Leave this open. The other PC will see this computer in their list and ask to',
        'connect. Nothing happens until you press Approve, and you will see who is asking.'
    ) -join "`r`n") 16 44 680 40 9 $false $script:MxDim))

    $status = New-MxDlgText -X 16 -Y 96 -W 688 -H 300 -ReadOnly $true -Text 'Starting...'
    $d.Controls.Add($status)

    $btnClose = New-MxDlgButton -Text 'Stop hosting' -W 130 -Result 'Cancel'
    $btnClose.SetBounds(574, 470, 130, 30)
    $btnClose.Anchor = 'Bottom, Right'
    $d.Controls.Add($btnClose)
    $d.CancelButton = $btnClose

    $script:MxRvHostState = [pscustomobject]@{
        Listener = $null; Beacon = $null; Drain = $null; Job = $null
        Session  = [guid]::NewGuid().ToString('N').Substring(0, 8)
        Account  = 'MatriseHelp'; Password = ''
        Lines    = New-Object System.Collections.ArrayList
        Busy     = $false
    }
    $H = $script:MxRvHostState

    $say = {
        param($text)
        [void]$H.Lines.Add(("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $text))
        while ($H.Lines.Count -gt 40) { $H.Lines.RemoveAt(0) }
        $status.Text = ($H.Lines -join "`r`n")
        $status.SelectionStart = $status.TextLength
        $status.ScrollToCaret()
    }

    $d.Add_Shown({
        Hide-MxPop
        Show-MxDialogFront -Dialog $d
        $d.Refresh()

        & $say 'Setting this PC up to be helped...'
        $init = Initialize-MatriseHostSide -Account $H.Account
        foreach ($s in $init.Steps) { & $say ($(if ($s.Ok) { '  ok   ' } else { '  FAIL ' }) + $s.Text) }
        if (-not $init.Ok) {
            & $say ''
            & $say 'Cannot host until that is fixed.'
            return
        }
        $H.Password = $init.Password

        & $say (('  ') + (Add-MatriseRvFirewallRule))

        $H.Listener = Start-MatriseRvListener -Port $script:MxRvHostPort
        Start-Sleep -Milliseconds 300
        if ($H.Listener.State['Error']) {
            & $say "  FAIL could not listen: $($H.Listener.State['Error'])"
            return
        }
        & $say "  ok   listening for requests on UDP $($script:MxRvHostPort)"

        # WinRM last, and in the background - it is slow, and the other PC can
        # already see us while it finishes.
        & $say ''
        & $say 'Turning on remote management in the background (this is the slow part)...'
        $H.Job = Start-Job -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck }

        & $say ''
        & $say "This PC is now visible as: $env:COMPUTERNAME"
        & $say 'Waiting for someone to ask...'

        $H.Beacon = New-Object System.Windows.Forms.Timer
        $H.Beacon.Interval = 1500
        $H.Beacon.Add_Tick({
            $hello = New-MatriseRvHello -SessionId $script:MxRvHostState.Session
            foreach ($t in (Get-MatriseBroadcastAddresses)) {
                try { Send-MatriseRvDatagram -Address $t -Port $script:MxRvGuestPort -Payload $hello -Broadcast } catch { }
            }
        })
        $H.Beacon.Start()

        $H.Drain = New-Object System.Windows.Forms.Timer
        $H.Drain.Interval = 300
        $H.Drain.Add_Tick({
            $S = $script:MxRvHostState

            if ($S.Job -and $S.Job.State -ne 'Running') {
                $r = Enable-MatriseHostRemoting
                & $say ('  remote management: ' + $(if ($r.Ok) { $r.Detail } else { 'NOT ready - ' + $r.Detail }))
                try { Remove-Job $S.Job -Force -ErrorAction SilentlyContinue } catch { }
                $S.Job = $null
            }

            if (-not $S.Listener) { return }
            while ($S.Listener.Queue.Count -gt 0) {
                $item = $S.Listener.Queue.Dequeue()
                $m = $item.Message
                if ($m.t -ne 'req') { continue }
                if ($S.Busy) { continue }
                $S.Busy = $true

                $code = Get-MatriseRvCode -Modulus $m.m -Nonce $m.n
                & $say ''
                & $say "REQUEST from $($m.u) on $($m.h) ($($item.From)) - code $code"

                $ok = Show-MxApproveDialog -Who "$($m.u) on $($m.h)" -From $item.From -Code $code
                if ($ok) {
                    $grant = New-MatriseRvGrant -Account $S.Account -Password $S.Password `
                                -Modulus $m.m -Exponent $m.e
                    try {
                        Send-MatriseRvDatagram -Address $item.From -Port ([int]$m.p) -Payload $grant
                        & $say 'APPROVED - sign-in sent. They can connect now.'
                    }
                    catch { & $say ("Could not reply: " + $_.Exception.Message) }
                }
                else {
                    try { Send-MatriseRvDatagram -Address $item.From -Port ([int]$m.p) -Payload (New-MatriseRvDeny) } catch { }
                    & $say 'DENIED - nothing was sent.'
                }
                $S.Busy = $false
            }
        })
        $H.Drain.Start()
    })

    $d.Add_FormClosing({
        $S = $script:MxRvHostState
        if ($S.Beacon) { $S.Beacon.Stop(); $S.Beacon.Dispose() }
        if ($S.Drain)  { $S.Drain.Stop();  $S.Drain.Dispose() }
        if ($S.Listener) { Stop-MatriseRvListener -Listener $S.Listener }
        if ($S.Job) { try { Stop-Job $S.Job -EA SilentlyContinue; Remove-Job $S.Job -Force -EA SilentlyContinue } catch { } }
        Add-MxBoardLine ''
        Add-MxBoardLine '*** Stopped hosting. ***'
        Add-MxBoardLine "    The $($S.Account) account is still there. Remove it with: Remove-LocalUser $($S.Account)"
        Update-MxBoardFlush
    })

    [void]$d.ShowDialog($script:MxForm)
    $d.Dispose()
}

# The box the person being helped actually reads.
function Show-MxApproveDialog {
    param([string]$Who, [string]$From, [string]$Code)

    $a = New-Object System.Windows.Forms.Form
    $a.Text = 'Matrise - someone wants to connect'
    $a.StartPosition = 'CenterScreen'
    $a.FormBorderStyle = 'FixedDialog'
    $a.MinimizeBox = $false; $a.MaximizeBox = $false
    $a.TopMost = $true
    $a.ClientSize = New-Object System.Drawing.Size(560, 330)
    $a.BackColor = $script:MxBg; $a.ForeColor = $script:MxFg

    $a.Controls.Add((New-MxRvLabel 'Someone wants to connect to this PC' 20 18 520 26 12 $true $script:MxFix))
    $a.Controls.Add((New-MxRvLabel "$Who" 20 54 520 24 11 $true))
    $a.Controls.Add((New-MxRvLabel "from $From" 20 78 520 20 9 $false $script:MxDim))

    $a.Controls.Add((New-MxRvLabel 'Check this number matches the one on their screen:' 20 116 520 20 9 $false $script:MxDim))
    $codeLbl = New-MxRvLabel $Code 20 138 520 46 26 $true $script:MxAccent
    $codeLbl.TextAlign = 'MiddleCenter'
    $a.Controls.Add($codeLbl)

    $a.Controls.Add((New-MxRvLabel (@(
        'If the numbers do not match, press Deny - someone else on the network is',
        'trying to get in. If you were not expecting this at all, press Deny.',
        '',
        'Approving gives them administrator access to this PC until you remove it.'
    ) -join "`r`n") 20 192 520 70 9 $false $script:MxFg))

    $yes = New-MxDlgButton -Text 'Approve' -W 150
    $yes.SetBounds(290, 280, 150, 34)
    $yes.ForeColor = [System.Drawing.Color]::FromArgb(124, 222, 146)
    $yes.Add_Click({ $a.DialogResult = 'OK'; $a.Close() })
    $a.Controls.Add($yes)

    $no = New-MxDlgButton -Text 'Deny' -W 110 -Result 'Cancel'
    $no.SetBounds(170, 280, 110, 34)
    $no.ForeColor = $script:MxHeavy
    $a.Controls.Add($no)

    # Deny is the default: leaning on the keyboard must never approve anything.
    $a.CancelButton = $no
    $a.AcceptButton = $no

    $r = $a.ShowDialog()
    $a.Dispose()
    ($r -eq [System.Windows.Forms.DialogResult]::OK)
}

# =========================================================================
#  GUEST - the PC doing the helping
# =========================================================================
function Show-MxGuestWindow {

    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Matrise - find a PC to help'
    $d.StartPosition = 'CenterParent'
    $d.ClientSize = New-Object System.Drawing.Size(720, 500)
    $d.MinimumSize = New-Object System.Drawing.Size(660, 460)
    $d.BackColor = $script:MxBg; $d.ForeColor = $script:MxFg

    $d.Controls.Add((New-MxRvLabel 'Pick the PC you are helping' 16 14 660 26 12 $true))
    $d.Controls.Add((New-MxRvLabel (@(
        'They press Host on their machine and it appears here. Nothing is typed on',
        'either side - they just approve, and the sign-in is delivered encrypted.'
    ) -join "`r`n") 16 44 684 40 9 $false $script:MxDim))

    $list = New-Object System.Windows.Forms.ListView
    $list.SetBounds(16, 92, 688, 170)
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.BackColor = $script:MxPanel; $list.ForeColor = $script:MxFg
    $list.BorderStyle = 'None'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    [void]$list.Columns.Add('Computer', 240)
    [void]$list.Columns.Add('Signed in as', 200)
    [void]$list.Columns.Add('Address', 220)
    $d.Controls.Add($list)

    $btnAsk = New-MxDlgButton -Text 'Ask to connect' -W 160
    $btnAsk.SetBounds(16, 272, 160, 32)
    $d.Controls.Add($btnAsk)

    $codeLbl = New-MxRvLabel '' 190 272 510 32 12 $true $script:MxAccent
    $d.Controls.Add($codeLbl)

    $status = New-MxDlgText -X 16 -Y 316 -W 688 -H 130 -ReadOnly $true `
        -Text 'Listening for PCs offering to be helped...'
    $d.Controls.Add($status)

    $btnClose = New-MxDlgButton -Text 'Close' -W 110 -Result 'Cancel'
    $btnClose.SetBounds(594, 456, 110, 30)
    $btnClose.Anchor = 'Bottom, Right'
    $d.Controls.Add($btnClose)
    $d.CancelButton = $btnClose

    $script:MxRvGuestState = [pscustomobject]@{
        Listener = $null; Drain = $null
        KeyPair = $null; Nonce = ''; Code = ''
        Seen = @{}
        Lines = New-Object System.Collections.ArrayList
        Asked = ''
    }
    $G = $script:MxRvGuestState

    $say = {
        param($text)
        [void]$G.Lines.Add(("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $text))
        while ($G.Lines.Count -gt 30) { $G.Lines.RemoveAt(0) }
        $status.Text = ($G.Lines -join "`r`n")
        $status.SelectionStart = $status.TextLength
        $status.ScrollToCaret()
    }

    $btnAsk.Add_Click({
        $G2 = $script:MxRvGuestState
        if ($list.SelectedItems.Count -eq 0) { & $say 'Pick a computer in the list first.'; return }
        $sel = $list.SelectedItems[0]
        $addr = $sel.SubItems[2].Text

        $G2.KeyPair = New-MatriseRvKeyPair
        $G2.Nonce   = New-MatriseRvNonce
        $G2.Code    = Get-MatriseRvCode -Modulus $G2.KeyPair.Modulus -Nonce $G2.Nonce
        $G2.Asked   = $sel.Text

        $codeLbl.Text = "Your code: $($G2.Code)"
        & $say ''
        & $say "Asked $($sel.Text) to let you connect."
        & $say "Read them this number: $($G2.Code) - it must match what they see."
        & $say 'Waiting for them to press Approve...'

        try {
            Send-MatriseRvDatagram -Address $addr -Port $script:MxRvHostPort `
                -Payload (New-MatriseRvRequest -KeyPair $G2.KeyPair -Nonce $G2.Nonce)
        }
        catch { & $say ("Could not send the request: " + $_.Exception.Message) }
    })

    $d.Add_Shown({
        Hide-MxPop
        Show-MxDialogFront -Dialog $d
        $d.Refresh()

        & $say (Add-MatriseRvFirewallRule)
        $G.Listener = Start-MatriseRvListener -Port $script:MxRvGuestPort
        Start-Sleep -Milliseconds 300
        if ($G.Listener.State['Error']) {
            & $say "Could not listen on UDP $($script:MxRvGuestPort): $($G.Listener.State['Error'])"
            return
        }
        & $say "Listening on UDP $($script:MxRvGuestPort). Ask them to press Host."

        $G.Drain = New-Object System.Windows.Forms.Timer
        $G.Drain.Interval = 400
        $G.Drain.Add_Tick({
            $S = $script:MxRvGuestState
            if (-not $S.Listener) { return }

            while ($S.Listener.Queue.Count -gt 0) {
                $item = $S.Listener.Queue.Dequeue()
                $m = $item.Message

                if ($m.t -eq 'hello') {
                    $key = "$($m.h)|$($item.From)"
                    if ($S.Seen.ContainsKey($key)) { continue }
                    $S.Seen[$key] = $true
                    $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList ([string]$m.h)
                    [void]$it.SubItems.Add([string]$m.u)
                    [void]$it.SubItems.Add([string]$item.From)
                    [void]$list.Items.Add($it)
                    if ($list.SelectedItems.Count -eq 0) { $it.Selected = $true }
                    & $say "Found $($m.h) (signed in as $($m.u))"
                }
                elseif ($m.t -eq 'grant') {
                    try {
                        $pw = Unprotect-MatriseRvSecret -KeyPair $S.KeyPair -Cipher $m.c
                    }
                    catch {
                        & $say 'A reply arrived but could not be decrypted - ignoring it.'
                        continue
                    }

                    & $say ''
                    & $say "APPROVED by $($m.h)."

                    $names = @($m.h) + @($m.i) | Where-Object { $_ }
                    try { & $say ('  ' + (Add-MatriseTrustedHost -Name ($names -join ','))) }
                    catch { & $say ('  could not update the trusted list: ' + $_.Exception.Message) }

                    $sec = ConvertTo-SecureString $pw -AsPlainText -Force
                    $cred = New-Object System.Management.Automation.PSCredential("$($m.h)\$($m.u)", $sec)
                    try {
                        [void](Save-MatrisePeerCredential -HostName ([string]$m.h) -Credential $cred)
                        & $say '  sign-in saved, encrypted to your Windows account only'
                    }
                    catch { & $say ('  could not save the sign-in: ' + $_.Exception.Message) }

                    $script:MxTargetBox.Text = [string]$m.h
                    $script:MxTarget = New-MatriseTarget -Name ([string]$m.h) -Credential $cred
                    Update-MxTargetLabel

                    Add-MxBoardLine ''
                    Add-MxBoardLine "*** Connected to $($m.h). ***"
                    Update-MxBoardFlush

                    & $say ''
                    & $say 'Done. Close this and press Test connection.'
                    $codeLbl.Text = 'Approved'
                }
                elseif ($m.t -eq 'deny') {
                    & $say ''
                    & $say "$($m.h) pressed Deny. Nothing was sent."
                    $codeLbl.Text = 'Denied'
                }
            }
        })
        $G.Drain.Start()
    })

    $d.Add_FormClosing({
        $S = $script:MxRvGuestState
        if ($S.Drain) { $S.Drain.Stop(); $S.Drain.Dispose() }
        if ($S.Listener) { Stop-MatriseRvListener -Listener $S.Listener }
    })

    [void]$d.ShowDialog($script:MxForm)
    $d.Dispose()
}
