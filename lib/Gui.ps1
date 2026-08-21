# Matrise - Window
#
# Layout:
#   toolbar
#   +----------------+------------------------------------------------+
#   | command tree   | selected command + the exact line it will run  |
#   |                | find bar (Ctrl+F, filter mode)                 |
#   |                | THE BOARD - all output lands here              |
#   |                +------------------------------------------------+
#   |                | findings          | why it matters             |
#   +----------------+------------------------------------------------+
#   status bar

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('Matrise.Native' -as [type])) {
    Add-Type -Namespace Matrise -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SendMessage(System.IntPtr hWnd, int msg, int wParam, System.IntPtr lParam);
'@
}

# ---------------------------------------------------------------- palette --
$script:MxBg       = [System.Drawing.Color]::FromArgb(24, 26, 31)
$script:MxPanel    = [System.Drawing.Color]::FromArgb(32, 35, 42)
$script:MxBoardBg  = [System.Drawing.Color]::FromArgb(18, 20, 24)
$script:MxFg       = [System.Drawing.Color]::FromArgb(220, 223, 228)
$script:MxDim      = [System.Drawing.Color]::FromArgb(140, 148, 160)
$script:MxAccent   = [System.Drawing.Color]::FromArgb(88, 166, 255)
$script:MxFix      = [System.Drawing.Color]::FromArgb(255, 180, 84)
$script:MxHeavy    = [System.Drawing.Color]::FromArgb(255, 123, 114)
$script:MxHit      = [System.Drawing.Color]::FromArgb(250, 220, 90)
$script:MxSevColor = @{
    'Critical' = [System.Drawing.Color]::FromArgb(255, 92, 92)
    'High'     = [System.Drawing.Color]::FromArgb(255, 159, 67)
    'Medium'   = [System.Drawing.Color]::FromArgb(255, 217, 61)
    'Low'      = [System.Drawing.Color]::FromArgb(116, 185, 255)
    'Info'     = [System.Drawing.Color]::FromArgb(160, 165, 175)
}

# ------------------------------------------------------------------ state --
$script:MxRaw        = New-Object System.Text.StringBuilder   # canonical board text
$script:MxPending    = New-Object System.Text.StringBuilder   # not yet flushed to the control
$script:MxCtx        = $null
$script:MxEntry      = $null
$script:MxBatch      = New-Object System.Collections.Queue
$script:MxFindings   = @()
$script:MxFiltered   = $false
$script:MxFilterMap  = @()          # display line -> real line
$script:MxWorkDir    = ''
$script:MxElevated   = $false
$script:MxLastFind   = -1
$script:MxChunks     = @()
$script:MxChunkIndex = 0
$script:MxLineCount  = 1
$script:MxTipRow     = ''
$script:MxHead       = $null
$script:MxLayoutReady = $false

$script:MxTipText     = ''
$script:MxTipFont     = New-Object System.Drawing.Font('Segoe UI', 9)
$script:MxTipFontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# Windows draws tooltips in the system light theme no matter what colours the
# app uses, so they have to be owner-drawn to match. Owner drawing also means
# ToolTipTitle is ignored, which is why the title is carried as line one of the
# text and drawn bold here.
function Initialize-MxTipTheme {
    param($Tip)
    $Tip.OwnerDraw = $true

    $Tip.Add_Popup({
        param($sender, $e)
        $txt = ''
        try { $txt = $sender.GetToolTip($e.AssociatedControl) } catch { }
        if ([string]::IsNullOrEmpty($txt)) { $txt = $script:MxTipText }
        if ([string]::IsNullOrEmpty($txt)) { return }

        $lines = $txt -split "`r?`n"
        $w = 0
        foreach ($l in $lines) {
            $lw = [System.Windows.Forms.TextRenderer]::MeasureText($l, $script:MxTipFontBold).Width
            if ($lw -gt $w) { $w = $lw }
        }
        $h = ($lines.Count * $script:MxTipFont.Height)
        $e.ToolTipSize = New-Object System.Drawing.Size(($w + 26), ($h + 18))
    })

    $Tip.Add_Draw({
        param($sender, $e)
        $g = $e.Graphics
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 44, 53))
        $g.FillRectangle($bg, $e.Bounds)
        $pen = New-Object System.Drawing.Pen ($script:MxAccent)
        $g.DrawRectangle($pen, 0, 0, ($e.Bounds.Width - 1), ($e.Bounds.Height - 1))

        $lines = $e.ToolTipText -split "`r?`n"
        $y = 9
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $f = $script:MxTipFont
            $c = $script:MxFg
            if ($i -eq 0 -and $line -notmatch '^(WHAT IT DOES|Found on line)') {
                $f = $script:MxTipFontBold; $c = $script:MxAccent
            }
            elseif ($line -cmatch '^[A-Z][A-Z ]{3,}$') { $f = $script:MxTipFontBold; $c = $script:MxDim }
            elseif ($line -cmatch '^(CAREFUL|NEEDS ADMINISTRATOR|ASKS YOU FIRST)') { $c = $script:MxFix }
            elseif ($line -cmatch '^SAFE') { $c = [System.Drawing.Color]::FromArgb(120, 220, 140) }
            [System.Windows.Forms.TextRenderer]::DrawText($g, $line, $f,
                (New-Object System.Drawing.Point(12, $y)), $c)
            $y += $script:MxTipFont.Height
        }
        $bg.Dispose(); $pen.Dispose()
    })
}

# ------------------------------------------------------------ layout ------
# The window remembers its size and where you dragged the dividers, so the
# shape you set up once is the shape you get next time.

function Get-MxLayoutPath { Join-Path $script:MxWorkDir 'matrise-layout.json' }

function Read-MxLayout {
    $p = Get-MxLayoutPath
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-MxLayout {
    if (-not $script:MxLayoutReady) { return }
    try {
        $maxed = ($script:MxForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
        $b = $(if ($maxed) { $script:MxForm.RestoreBounds } else { $script:MxForm.Bounds })
        [pscustomobject]@{
            Width      = $b.Width
            Height     = $b.Height
            Maximized  = $maxed
            SplitMain  = $script:MxSplit.SplitterDistance
            SplitBoard = $script:MxRSplit.SplitterDistance
            SplitFind  = $script:MxFSplit.SplitterDistance
            Wrap       = $script:MxBoard.WordWrap
        } | ConvertTo-Json | Set-Content -Path (Get-MxLayoutPath) -Encoding UTF8
    } catch { }
}

function Get-MxClamped {
    param($Value, [int]$Default, [int]$Min, [int]$Max)
    if ($Max -lt $Min) { return $Min }
    $v = $Default
    if ($null -ne $Value -and [int]$Value -gt 0) { $v = [int]$Value }
    if ($v -lt $Min) { $v = $Min }
    if ($v -gt $Max) { $v = $Max }
    $v
}

# The command box grows to fit whatever it has to show, instead of hiding the
# first half of a long command behind a scrollbar.
function Update-MxHeadHeight {
    if (-not $script:MxHead -or -not $script:MxHeadCmd) { return }
    $txt = $script:MxHeadCmd.Text
    $wid = $script:MxHeadCmd.ClientSize.Width - 8
    if ($wid -lt 80) { return }

    $needed = 34
    if ($txt) {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
                $txt, $script:MxHeadCmd.Font,
                (New-Object System.Drawing.Size($wid, 4000)),
                ([System.Windows.Forms.TextFormatFlags]::WordBreak))
        $needed = $sz.Height + 12
    }
    # name + description + padding + the box itself
    $want = 22 + 38 + 16 + $needed
    $cap  = [math]::Max(150, [int]($script:MxForm.ClientSize.Height * 0.34))
    $script:MxHead.Height = [math]::Max(126, [math]::Min($cap, $want))
}

# Severity and Line stay fixed; Finding and Evidence share whatever is left, so
# the evidence text is not permanently cut off at the panel edge.
function Update-MxFindColumns {
    if (-not $script:MxFindList) { return }
    # ClientSize already excludes the vertical scrollbar, so only a few
    # pixels of slack are needed to avoid a horizontal one appearing.
    $w = $script:MxFindList.ClientSize.Width
    $rest = $w - 76 - 54 - 6
    if ($rest -lt 240) { return }
    $script:MxFindList.Columns[0].Width = 76
    $script:MxFindList.Columns[1].Width = 54
    $script:MxFindList.Columns[2].Width = [int]($rest * 0.46)
    $script:MxFindList.Columns[3].Width = $rest - [int]($rest * 0.46)
}

function New-MxLabel {
    param([string]$Text, [int]$Size = 9, [bool]$Bold = $false, $Color = $null)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.AutoSize  = $false
    $l.ForeColor = $(if ($Color) { $Color } else { $script:MxFg })
    $style = $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    $l
}

function New-MxButton {
    param([string]$Text, [string]$Tip, [scriptblock]$OnClick, [int]$Width = 92)
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Width     = $Width
    $b.Height    = 28
    $b.FlatStyle = 'Flat'
    $b.BackColor = $script:MxPanel
    $b.ForeColor = $script:MxFg
    $b.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 66, 78)
    $b.Margin    = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    if ($Tip) { $script:MxTip.SetToolTip($b, $Tip) }
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

# --------------------------------------------------------- board plumbing --
function Add-MxBoardText {
    param([string]$Text)
    [void]$script:MxRaw.Append($Text)
    [void]$script:MxPending.Append($Text)
    # Counted incrementally. Re-splitting a multi-megabyte board on every
    # 150 ms timer tick is the difference between smooth and unusable.
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") { $script:MxLineCount++ }
    }
}

function Add-MxBoardLine {
    param([string]$Line = '')
    Add-MxBoardText ($Line + "`r`n")
}

function Update-MxBoardFlush {
    if ($script:MxPending.Length -eq 0) { return }
    if ($script:MxFiltered) { $script:MxPending.Clear() | Out-Null; return }

    $chunk = $script:MxPending.ToString()
    $script:MxPending.Clear() | Out-Null

    $atBottom = $true
    try {
        $visible  = $script:MxBoard.GetLineFromCharIndex($script:MxBoard.GetCharIndexFromPosition(
                     (New-Object System.Drawing.Point(2, $script:MxBoard.ClientSize.Height - 4))))
        $lastLine = $script:MxBoard.GetLineFromCharIndex($script:MxBoard.TextLength)
        $atBottom = ($visible -ge ($lastLine - 3))
    } catch { }

    $script:MxBoard.AppendText($chunk)
    if ($atBottom) {
        $script:MxBoard.SelectionStart = $script:MxBoard.TextLength
        $script:MxBoard.ScrollToCaret()
    }
    Update-MxStatusCounts
}

function Clear-MxBoard {
    $script:MxRaw.Clear()     | Out-Null
    $script:MxPending.Clear() | Out-Null
    $script:MxLineCount = 1
    $script:MxBoard.Clear()
    $script:MxFindings  = @()
    $script:MxFiltered  = $false
    $script:MxFilterMap = @()
    $script:MxChk.Checked = $false
    $script:MxFindList.Items.Clear()
    $script:MxWhy.Text = ''
    Update-MxStatusCounts
}

function Set-MxRedraw {
    param([bool]$On)
    [void][Matrise.Native]::SendMessage($script:MxBoard.Handle, 0x000B, $(if ($On) { 1 } else { 0 }), [System.IntPtr]::Zero)
    if ($On) { $script:MxBoard.Refresh() }
}

function Update-MxStatusCounts {
    $len = $script:MxRaw.Length
    $script:MxStatLines.Text = "$($script:MxLineCount) lines / $([math]::Round($len/1KB)) KB"
}

# --------------------------------------------------------------- find bar --
function Invoke-MxHighlightAll {
    param([string]$Term)

    Set-MxRedraw $false
    try {
        $keepStart = $script:MxBoard.SelectionStart
        $keepLen   = $script:MxBoard.SelectionLength
        $script:MxBoard.SelectAll()
        $script:MxBoard.SelectionBackColor = $script:MxBoard.BackColor

        $count = 0
        if ($Term -and $Term.Length -ge 2) {
            $body = $script:MxBoard.Text
            $idx  = 0
            while ($count -lt 800) {
                $idx = $body.IndexOf($Term, $idx, [System.StringComparison]::OrdinalIgnoreCase)
                if ($idx -lt 0) { break }
                $script:MxBoard.Select($idx, $Term.Length)
                $script:MxBoard.SelectionBackColor = $script:MxHit
                $idx += $Term.Length
                $count++
            }
        }
        $script:MxBoard.Select($keepStart, $keepLen)
        $script:MxFindCount.Text = $(if ($Term.Length -lt 2) { '' } elseif ($count -ge 800) { '800+ hits' } else { "$count hits" })
    }
    finally { Set-MxRedraw $true }
}

function Invoke-MxFindNext {
    param([bool]$Backwards = $false)
    $term = $script:MxFind.Text
    if (-not $term) { return }
    $body = $script:MxBoard.Text
    if (-not $body) { return }

    if ($Backwards) {
        $from = [math]::Max(0, $script:MxBoard.SelectionStart - 1)
        $idx  = $body.LastIndexOf($term, [math]::Min($from, $body.Length - 1), [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { $idx = $body.LastIndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) }
    } else {
        $from = [math]::Min($body.Length, $script:MxBoard.SelectionStart + $script:MxBoard.SelectionLength)
        $idx  = $body.IndexOf($term, $from, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { $idx = $body.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) }
    }
    if ($idx -lt 0) { $script:MxStatus.Text = "not found: $term"; return }

    $script:MxBoard.Select($idx, $term.Length)
    $script:MxBoard.ScrollToCaret()
    $script:MxBoard.Focus()
    $line = $script:MxBoard.GetLineFromCharIndex($idx) + 1
    $script:MxStatus.Text = "match on display line $line"
}

# Filter mode rewrites the board to only the matching lines, keeping the real
# line number in front so a finding is still locatable in the full output.
function Set-MxFilter {
    param([bool]$On)

    $term = $script:MxFind.Text
    if ($On -and $term.Length -lt 2) {
        $script:MxChk.Checked = $false
        return
    }

    Set-MxRedraw $false
    try {
        if (-not $On) {
            $script:MxFiltered  = $false
            $script:MxFilterMap = @()
            $script:MxBoard.Clear()
            $script:MxBoard.AppendText($script:MxRaw.ToString())
        }
        else {
            $all = $script:MxRaw.ToString() -split "`r?`n"
            $sb  = New-Object System.Text.StringBuilder
            $map = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $all.Count; $i++) {
                if ($all[$i].IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [void]$map.Add($i + 1)
                    [void]$sb.AppendLine(('{0,7}  {1}' -f ($i + 1), $all[$i]))
                }
            }
            $script:MxFiltered  = $true
            $script:MxFilterMap = $map
            $script:MxBoard.Clear()
            $script:MxBoard.AppendText($sb.ToString())
            $script:MxStatus.Text = "filter: $($map.Count) of $($all.Count) lines contain '$term'"
        }
    }
    finally { Set-MxRedraw $true }
    Invoke-MxHighlightAll $term
}

function Move-MxToLine {
    param([int]$Line)
    if ($script:MxFiltered) { $script:MxChk.Checked = $false }
    $target = [math]::Max(0, $Line - 1)
    if ($target -ge $script:MxBoard.Lines.Count) { $target = $script:MxBoard.Lines.Count - 1 }
    if ($target -lt 0) { return }
    $start = $script:MxBoard.GetFirstCharIndexFromLine($target)
    if ($start -lt 0) { return }
    $len = $script:MxBoard.Lines[$target].Length
    $script:MxBoard.Select($start, $len)
    $script:MxBoard.ScrollToCaret()
    $script:MxBoard.Focus()
}

# ---------------------------------------------------------------- running --
function Get-MxResolvedEntry {
    param($Entry)

    if (-not $Entry.Prompt) { return $Entry }

    $value = Show-MxInputDialog -Title $Entry.Name -Question $Entry.Prompt -Default $Entry.PromptDefault
    if ($null -eq $value) { return $null }
    $value = $value.Trim()
    if (-not $value) { return $null }

    if ($Entry.Shell -eq 'ps') {
        # %INPUT% always lands inside a single-quoted PowerShell string.
        $safe = $value -replace "'", "''"
    } else {
        # Strip everything cmd would treat as a command separator.
        $safe = $value -replace '[&|<>^"%]', ''
    }

    $clone = $Entry.PSObject.Copy()
    $clone.Command = $Entry.Command -replace '%INPUT%', $safe
    $clone.Name    = "$($Entry.Name)  [$value]"
    $clone
}

function Test-MxConfirm {
    param($Entry)
    if ($Entry.Impact -eq 'read') { return $true }

    $what = $(if ($Entry.Impact -eq 'heavy') {
        "This CHANGES YOUR SYSTEM and may take a long time or need a reboot."
    } else {
        "This CHANGES YOUR SYSTEM."
    })

    $msg = @(
        $Entry.Name,
        '',
        $Entry.Desc,
        '',
        $what,
        '',
        'It will run exactly this:',
        '',
        $Entry.Command,
        '',
        'Continue?'
    ) -join "`r`n"

    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Matrise - confirm change',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    $r -eq [System.Windows.Forms.DialogResult]::Yes
}

function Start-MxEntry {
    param($Entry)

    if ($script:MxCtx -and $script:MxCtx.State['Running']) {
        $script:MxStatus.Text = 'already running - press Stop first'
        return
    }

    $resolved = Get-MxResolvedEntry -Entry $Entry
    if (-not $resolved) { $script:MxStatus.Text = 'cancelled'; return }
    if (-not (Test-MxConfirm -Entry $resolved)) { $script:MxStatus.Text = 'cancelled'; return }

    if ($resolved.Admin -and -not $script:MxElevated) {
        Add-MxBoardLine ''
        Add-MxBoardLine '!!! This command needs Administrator to return complete data.'
        Add-MxBoardLine '!!! Running anyway - expect blank sections or access-denied lines.'
    }

    $script:MxEntry = $resolved
    Add-MxBoardLine ''
    Add-MxBoardLine '================================================================'
    Add-MxBoardLine ("  {0}   [{1}]" -f $resolved.Name, $resolved.Group)
    Add-MxBoardLine ("  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-MxBoardLine '================================================================'
    Add-MxBoardLine 'COMMAND:'
    foreach ($l in ($resolved.Command -split "`r?`n")) { Add-MxBoardLine ("  $l") }
    Add-MxBoardLine '----------------------------------------------------------------'
    Update-MxBoardFlush

    $script:MxCtx = New-MatriseRunContext
    Start-MatriseRun -Context $script:MxCtx -Entry $resolved -WorkDir $script:MxWorkDir | Out-Null

    $script:MxStatus.Text = "running: $($resolved.Name)"
    $script:MxBtnStop.Enabled = $true
    $script:MxTimer.Start()
}

function Start-MxBatch {
    param($Entries)
    $script:MxBatch.Clear()
    foreach ($e in $Entries) { $script:MxBatch.Enqueue($e) }
    Invoke-MxBatchNext
}

function Invoke-MxBatchNext {
    if ($script:MxBatch.Count -eq 0) { return }
    $next = $script:MxBatch.Dequeue()
    Start-MxEntry -Entry $next
}

function Complete-MxRun {
    $code = $script:MxCtx.State['ExitCode']
    $secs = 0
    if ($script:MxCtx.State['Started']) {
        $secs = [math]::Round(((Get-Date) - $script:MxCtx.State['Started']).TotalSeconds, 1)
    }
    Add-MxBoardLine '----------------------------------------------------------------'
    Add-MxBoardLine ("  finished in {0}s   exit code {1}" -f $secs, $code)
    Update-MxBoardFlush

    Close-MatriseRun -Context $script:MxCtx
    $script:MxBtnStop.Enabled = $false
    $script:MxStatus.Text = "done: $($script:MxEntry.Name)  ($secs s, exit $code)"

    if ($script:MxAutoCopy.Checked) { Copy-MxBoard -Quiet }
    if ($script:MxAutoScan.Checked) { Invoke-MxAnalyze -Quiet }

    if ($script:MxBatch.Count -gt 0) {
        $script:MxStatus.Text += "   ($($script:MxBatch.Count) queued)"
        Invoke-MxBatchNext
    } else {
        $script:MxTimer.Stop()
    }
}

# --------------------------------------------------------------- analysis --
function Invoke-MxAnalyze {
    param([switch]$Quiet)

    $body = $script:MxRaw.ToString()
    if ([string]::IsNullOrWhiteSpace($body)) {
        if (-not $Quiet) { $script:MxStatus.Text = 'board is empty - run a command or paste something first' }
        return
    }

    $script:MxStatus.Text = 'analyzing...'
    $script:MxForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $script:MxFindings = Invoke-MatriseAnalysis -Text $body
    } finally {
        $script:MxForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    $script:MxFindList.BeginUpdate()
    $script:MxFindList.Items.Clear()
    foreach ($f in $script:MxFindings) {
        $it = New-Object System.Windows.Forms.ListViewItem -ArgumentList ([string]$f.Severity)
        [void]$it.SubItems.Add([string]$f.Line)
        [void]$it.SubItems.Add($f.Title)
        [void]$it.SubItems.Add($f.Evidence)
        $c = $script:MxSevColor[$f.Severity]
        if ($c) { $it.ForeColor = $c }
        $it.Tag = $f
        [void]$script:MxFindList.Items.Add($it)
    }
    $script:MxFindList.EndUpdate()
    Update-MxFindColumns

    $n = $script:MxFindings.Count
    $crit = @($script:MxFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $high = @($script:MxFindings | Where-Object { $_.Severity -eq 'High' }).Count
    $script:MxStatFind.Text = "$n findings  ($crit critical, $high high)"
    $script:MxStatus.Text   = $(if ($n -eq 0) { 'analysis: nothing matched' } else { "analysis: $n findings - see the list below" })

    if ($n -gt 0) {
        $script:MxFindList.Items[0].Selected = $true
        $script:MxFindList.Select()
    } else {
        $script:MxWhy.Text = 'No rule matched the text on the board.' + "`r`n`r`n" +
            'That is a good sign, but not a clean bill of health - Matrise can only ' +
            'see what you actually ran. Security > FULL SWEEP is the broadest single check.'
    }
}

# ------------------------------------------------------------- clipboard ---
function Set-MxClipboard {
    param([string]$Text)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ([string]::IsNullOrEmpty($Text)) { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($Text) }
            return $true
        } catch {
            Start-Sleep -Milliseconds 120
        }
    }
    $false
}

function Copy-MxBoard {
    param([switch]$Quiet)
    $sel = $script:MxBoard.SelectedText
    $txt = $(if ($sel -and $sel.Length -gt 0) { $sel } else { $script:MxRaw.ToString() })
    if (Set-MxClipboard $txt) {
        $what = $(if ($sel -and $sel.Length -gt 0) { 'selection' } else { 'whole board' })
        if (-not $Quiet) { $script:MxStatus.Text = "copied $what to clipboard ($([math]::Round($txt.Length/1KB)) KB)" }
    } else {
        $script:MxStatus.Text = 'clipboard is locked by another program - try again'
    }
}

function Add-MxFromClipboard {
    $txt = ''
    try { $txt = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    if ([string]::IsNullOrWhiteSpace($txt)) {
        $script:MxStatus.Text = 'clipboard has no text'
        return
    }
    Add-MxBoardLine ''
    Add-MxBoardLine '================================================================'
    Add-MxBoardLine ("  PASTED FROM CLIPBOARD   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-MxBoardLine '================================================================'
    Add-MxBoardText ($txt.TrimEnd() + "`r`n")
    Update-MxBoardFlush
    $script:MxStatus.Text = "pasted $([math]::Round($txt.Length/1KB)) KB - press Analyze"
}

# ------------------------------------------------------------------ agent --
function Invoke-MxAgent {
    $body = $script:MxRaw.ToString()
    if ([string]::IsNullOrWhiteSpace($body)) {
        $script:MxStatus.Text = 'board is empty - nothing to send'
        return
    }
    if (@($script:MxFindings).Count -eq 0) { Invoke-MxAnalyze -Quiet }

    $notes  = Show-MxInputDialog -Title 'Ask Claude' `
                -Question "Anything Claude should know? (symptoms, what changed, what you were doing)`r`nLeave blank to just send the data." `
                -Default ''
    if ($null -eq $notes) { $script:MxStatus.Text = 'cancelled'; return }

    $prompt = New-MatriseAgentPrompt -Text $body -Findings $script:MxFindings -Context $notes
    $file   = Save-MatriseAgentPrompt -Prompt $prompt -WorkDir $script:MxWorkDir

    $cli = Find-MatriseAgentCli
    if ($cli) {
        Add-MxBoardLine ''
        Add-MxBoardLine "Sending $([math]::Round($prompt.Length/1KB)) KB to the Claude CLI at $cli"
        $entry = New-MatriseAgentEntry -CliPath $cli -PromptFile $file
        Start-MxEntry -Entry $entry
        return
    }

    # No CLI: hand off via the clipboard, in paste-sized pieces.
    $script:MxChunks     = @(Split-MatriseForClipboard -Text $prompt)
    $script:MxChunkIndex = 0
    Copy-MxNextChunk

    $n = $script:MxChunks.Count
    $msg = @(
        'The Claude Code CLI is not installed, so Matrise cannot send this for you.',
        '',
        "Part 1 of $n is on your clipboard now.",
        '',
        'Open claude.ai (or any Claude window), paste, and send.',
        $(if ($n -gt 1) { "Then press 'Copy next part' in the toolbar for each remaining part." } else { '' }),
        '',
        "The full prompt was also saved to:",
        $file
    ) -join "`r`n"
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Matrise - hand off to Claude',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Copy-MxNextChunk {
    if (@($script:MxChunks).Count -eq 0) {
        $script:MxStatus.Text = 'nothing prepared - press Ask Claude first'
        return
    }
    if ($script:MxChunkIndex -ge $script:MxChunks.Count) {
        $script:MxStatus.Text = 'all parts copied already'
        return
    }
    $chunk = $script:MxChunks[$script:MxChunkIndex]
    if (Set-MxClipboard $chunk) {
        $script:MxChunkIndex++
        $script:MxBtnChunk.Text = "Copy part $($script:MxChunkIndex + 1)/$($script:MxChunks.Count)"
        $script:MxBtnChunk.Visible = ($script:MxChunkIndex -lt $script:MxChunks.Count)
        $script:MxStatus.Text = "part $($script:MxChunkIndex) of $($script:MxChunks.Count) copied - paste it into Claude"
    }
}

# ----------------------------------------------------------------- report --
function Save-MxReport {
    $body = $script:MxRaw.ToString()
    if ([string]::IsNullOrWhiteSpace($body)) { $script:MxStatus.Text = 'board is empty'; return }

    $dir = Join-Path $script:MxWorkDir 'reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.InitialDirectory = $dir
    $dlg.FileName = "matrise-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dlg.Filter   = 'Text report (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $head = @(
        '================================================================',
        ' MATRISE REPORT',
        " generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        " machine   : $env:COMPUTERNAME",
        " user      : $env:USERNAME",
        " elevated  : $script:MxElevated",
        '================================================================',
        ''
    ) -join "`r`n"

    $analysis = Format-MatriseFindings -Findings $script:MxFindings
    [System.IO.File]::WriteAllText($dlg.FileName, ($head + $analysis + "`r`n" + $body),
        (New-Object System.Text.UTF8Encoding($false)))
    $script:MxStatus.Text = "saved: $($dlg.FileName)"
}

function Open-MxFile {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.InitialDirectory = $script:MxWorkDir
    $dlg.Filter = 'Text and logs (*.txt;*.log;*.md)|*.txt;*.log;*.md|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $txt = [System.IO.File]::ReadAllText($dlg.FileName)
    Add-MxBoardLine ''
    Add-MxBoardLine '================================================================'
    Add-MxBoardLine ("  LOADED FILE: {0}" -f $dlg.FileName)
    Add-MxBoardLine '================================================================'
    Add-MxBoardText ($txt.TrimEnd() + "`r`n")
    Update-MxBoardFlush
    $script:MxStatus.Text = "loaded $([math]::Round($txt.Length/1KB)) KB - press Analyze"
}

# ------------------------------------------------------------ input dialog -
function Show-MxInputDialog {
    param([string]$Title, [string]$Question, [string]$Default = '')

    $d = New-Object System.Windows.Forms.Form
    $d.Text            = "Matrise - $Title"
    $d.StartPosition   = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MinimizeBox     = $false
    $d.MaximizeBox     = $false
    $d.ClientSize      = New-Object System.Drawing.Size(560, 170)
    $d.BackColor       = $script:MxBg
    $d.ForeColor       = $script:MxFg

    $lbl = New-MxLabel -Text $Question
    $lbl.SetBounds(14, 14, 532, 60)
    $d.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(14, 80, 532, 26)
    $tb.Text      = $Default
    $tb.BackColor = $script:MxBoardBg
    $tb.ForeColor = $script:MxFg
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = New-Object System.Drawing.Font('Consolas', 10)
    $d.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.SetBounds(360, 122, 88, 30); $ok.DialogResult = 'OK'
    $ok.FlatStyle = 'Flat'; $ok.BackColor = $script:MxPanel; $ok.ForeColor = $script:MxFg
    $d.Controls.Add($ok)

    $ca = New-Object System.Windows.Forms.Button
    $ca.Text = 'Cancel'; $ca.SetBounds(456, 122, 88, 30); $ca.DialogResult = 'Cancel'
    $ca.FlatStyle = 'Flat'; $ca.BackColor = $script:MxPanel; $ca.ForeColor = $script:MxFg
    $d.Controls.Add($ca)

    $d.AcceptButton = $ok
    $d.CancelButton = $ca
    $d.Add_Shown({ $tb.Focus(); $tb.SelectAll() })

    $r = $d.ShowDialog($script:MxForm)
    $val = $tb.Text
    $d.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $val }
    $null
}

function Show-MxNodeTip {
    param($Node)
    if (-not $Node -or -not $Node.Tag) { return }

    $title = ''
    $body  = ''
    switch ($Node.Tag.Kind) {
        'entry' {
            $title = $Node.Tag.Entry.Name
            $body  = Format-MatriseExplain -Entry $Node.Tag.Entry
        }
        'section' {
            $title = "$($Node.Tag.Group) / $($Node.Tag.Section)"
            $body  = Get-MatriseTip "section.$($Node.Tag.Section)"
        }
        'group' {
            $title = $Node.Tag.Group
            $body  = (Get-MatriseTip "group.$($Node.Tag.Group)") + "`r`n`r`n" + (Get-MatriseTip 'ui.tree')
        }
    }
    if (-not $body) { return }

    $script:MxTipText = $title + "`r`n`r`n" + $body
    # Anchored to the node rather than the pointer, so it lands in the same
    # place every time instead of wherever the mouse happened to stop.
    $x = [math]::Min(($Node.Bounds.Left + 28), 220)
    $y = $Node.Bounds.Bottom + 6
    $script:MxTipNode.Show($script:MxTipText, $script:MxTree, $x, $y, 32000)
}

# ============================================================= self test ==
# Drives the real window through a scripted pass. Run it with
#   .\Matrise.ps1 -SelfTest
# after changing anything in lib\, to prove the UI still wires up and that a
# command still makes it all the way from the tree to the board.

$script:MxSelfFail  = 0
$script:MxSelfTicks = 0
$script:MxSelfTimer = $null

function Write-MxCheck {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        Write-Host ("  PASS  {0,-16} {1}" -f $Name, $Detail)
    } else {
        Write-Host ("  FAIL  {0,-16} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:MxSelfFail++
    }
}

function Invoke-MxSelfTestPhase1 {
    Write-Host ''
    Write-Host 'MATRISE SELF TEST' -ForegroundColor Cyan

    Write-MxCheck 'window'    ($script:MxForm.Visible)                 "size $($script:MxForm.ClientSize)"
    Write-MxCheck 'tree'      ($script:MxTree.Nodes.Count -eq 3)       "$($script:MxTree.Nodes.Count) groups"
    Write-MxCheck 'splitters' ($script:MxSplit.SplitterDistance -gt 100) "left panel $($script:MxSplit.SplitterDistance)px"
    Write-MxCheck 'welcome'   ($script:MxRaw.Length -gt 500)           "$($script:MxRaw.Length) chars"

    $node = $script:MxTree.Nodes[0].Nodes[0].Nodes[0]
    $script:MxTree.SelectedNode = $node
    Write-MxCheck 'selection' ($script:MxHeadCmd.Text.Length -gt 5) "command box: $($script:MxHeadCmd.Text.Length) chars"

    # Every command must have a plain-English explanation to hover over.
    $tab   = Get-MatriseExplainTable
    $all   = Get-MatriseCatalog
    $noExp = @($all | Where-Object { -not $tab.ContainsKey($_.Id) })
    Write-MxCheck 'explanations' ($noExp.Count -eq 0) `
        "$($all.Count - $noExp.Count) of $($all.Count) commands$(if ($noExp.Count) { ' - missing: ' + (($noExp.Id) -join ', ') })"

    $tip = Format-MatriseExplain -Entry $node.Tag.Entry
    Write-MxCheck 'hover text' (($tip.Length -gt 120) -and ($tip -match 'WHAT IT DOES')) "$($tip.Length) chars"

    # A long command must be fully readable, not scrolled out of sight.
    $long = $null
    foreach ($sec in $script:MxTree.Nodes[0].Nodes) {
        foreach ($n in $sec.Nodes) { if ($n.Tag.Entry.Id -eq 'net.proxy') { $long = $n } }
    }
    if ($long) {
        $script:MxTree.SelectedNode = $long
        $needs = [System.Windows.Forms.TextRenderer]::MeasureText(
                    $script:MxHeadCmd.Text, $script:MxHeadCmd.Font,
                    (New-Object System.Drawing.Size(($script:MxHeadCmd.ClientSize.Width - 8), 4000)),
                    ([System.Windows.Forms.TextFormatFlags]::WordBreak)).Height
        $has = $script:MxHeadCmd.ClientSize.Height
        Write-MxCheck 'box grows' ($has -ge $needs) "$($script:MxHeadCmd.Text.Length)-char command needs ${needs}px, box is ${has}px"
    }

    $fx = Join-Path $script:MxWorkDir 'tests\sample-compromised.txt'
    if (Test-Path $fx) {
        Add-MxBoardText ([System.IO.File]::ReadAllText($fx))
        Update-MxBoardFlush
        Invoke-MxAnalyze -Quiet
        Write-MxCheck 'analysis'  (@($script:MxFindings).Count -gt 20) "$(@($script:MxFindings).Count) findings"
        Write-MxCheck 'find list' ($script:MxFindList.Items.Count -eq @($script:MxFindings).Count) "$($script:MxFindList.Items.Count) rows"
        $ev = $script:MxFindList.Columns[3].Width
        Write-MxCheck 'columns' ($ev -gt 200) "evidence column ${ev}px"

        $script:MxFind.Text = 'LISTENING'
        Write-MxCheck 'highlight' ($script:MxFindCount.Text -match '\d+ hits') "'$($script:MxFindCount.Text)'"

        $script:MxChk.Checked = $true
        $shown = $script:MxBoard.Lines.Count
        Write-MxCheck 'filter'    ($shown -lt $script:MxLineCount -and $shown -gt 1) "$shown of $($script:MxLineCount) lines"
        $script:MxChk.Checked = $false
        Write-MxCheck 'unfilter'  (-not $script:MxFiltered) 'board restored'

        Move-MxToLine -Line ([int]$script:MxFindings[0].Line)
        Write-MxCheck 'jump'      ($script:MxBoard.SelectionLength -gt 0) "selected $($script:MxBoard.SelectionLength) chars"
        $script:MxFind.Text = ''
    } else {
        Write-Host '  SKIP  fixture missing' -ForegroundColor Yellow
    }

    # Now the part that matters most: a real command, start to finish.
    $script:MxSelfBefore = $script:MxLineCount
    $arp = Get-MatriseCatalog | Where-Object { $_.Id -eq 'net.arp' }
    Start-MxEntry -Entry $arp

    $script:MxSelfTicks = 0
    $script:MxSelfTimer = New-Object System.Windows.Forms.Timer
    $script:MxSelfTimer.Interval = 400
    $script:MxSelfTimer.Add_Tick({ Invoke-MxSelfTestPhase2 })
    $script:MxSelfTimer.Start()
}

function Invoke-MxSelfTestPhase2 {
    $script:MxSelfTicks++
    $finished = ($script:MxCtx -and $script:MxCtx.State['Done'] -and $null -eq $script:MxCtx.Handle)
    if (-not $finished -and $script:MxSelfTicks -lt 60) { return }

    $script:MxSelfTimer.Stop()
    Write-MxCheck 'run finished' $finished "after $([math]::Round($script:MxSelfTicks * 0.4, 1))s"
    if ($finished) {
        $grew = ($script:MxLineCount - $script:MxSelfBefore)
        Write-MxCheck 'output'   ($grew -gt 5) "$grew lines appended"
        Write-MxCheck 'exit code' ($script:MxCtx.State['ExitCode'] -eq 0) "exit $($script:MxCtx.State['ExitCode'])"
        Write-MxCheck 'banner'   ($script:MxRaw.ToString() -match 'COMMAND:') 'command echoed onto the board'
    }

    Write-Host ''
    if ($script:MxSelfFail -eq 0) { Write-Host 'SELF TEST PASSED' -ForegroundColor Green }
    else { Write-Host "SELF TEST FAILED - $($script:MxSelfFail) check(s)" -ForegroundColor Red }
    $script:MxForm.Close()
}

# ==========================================================================
function Show-MatriseWindow {
    param(
        [string]$WorkDir,
        # >0 drives the window through a scripted pass and closes it. Used by
        # .\Matrise.ps1 -SelfTest to prove the whole UI still wires up.
        [int]$SelfTestMs = 0
    )

    $script:MxWorkDir  = $WorkDir
    $script:MxElevated = Test-MatriseElevated
    $catalog = Get-MatriseCatalog

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $script:MxForm = $form
    $form.Text          = "Matrise - security and system helper" + $(if ($script:MxElevated) { '  [Administrator]' } else { '  [limited - not elevated]' })
    # Open big. On a 1080p screen that is roughly 90% of the desktop; on a
    # small laptop it shrinks to fit rather than hanging off the edge.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:MxLayout = Read-MxLayout
    $wantW = [int][math]::Min(1600, $wa.Width  * 0.92)
    $wantH = [int][math]::Min(1040, $wa.Height * 0.92)
    if ($script:MxLayout) {
        $wantW = Get-MxClamped $script:MxLayout.Width  $wantW 1000 $wa.Width
        $wantH = Get-MxClamped $script:MxLayout.Height $wantH 640  $wa.Height
    }
    $form.Size          = New-Object System.Drawing.Size($wantW, $wantH)
    $form.MinimumSize   = New-Object System.Drawing.Size(1000, 640)
    if ($script:MxLayout -and $script:MxLayout.Maximized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    }
    $form.StartPosition = 'CenterScreen'
    $form.BackColor     = $script:MxBg
    $form.ForeColor     = $script:MxFg
    $form.KeyPreview    = $true

    $script:MxTip = New-Object System.Windows.Forms.ToolTip
    $script:MxTip.AutoPopDelay   = 32000
    $script:MxTip.InitialDelay   = 400
    $script:MxTip.ReshowDelay    = 200

    # A separate component for the hover explanations, because ToolTipTitle is
    # set on the component rather than per control.
    $script:MxTipNode = New-Object System.Windows.Forms.ToolTip
    $script:MxTipNode.AutoPopDelay = 32000
    $script:MxTipNode.InitialDelay = 350
    $script:MxTipNode.ReshowDelay  = 150

    Initialize-MxTipTheme $script:MxTip
    Initialize-MxTipTheme $script:MxTipNode

    # ---------------------------------------------------------- main split --
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock          = 'Fill'
    $split.SplitterWidth = 6
    # A visible divider, so it is obvious these panels can be dragged.
    $split.BackColor     = [System.Drawing.Color]::FromArgb(58, 64, 76)
    $script:MxSplit = $split

    # ---------------------------------------------------------------- tree --
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock       = 'Fill'
    $tree.BackColor  = $script:MxPanel
    $tree.ForeColor  = $script:MxFg
    $tree.BorderStyle = 'None'
    $tree.Font       = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $tree.HideSelection = $false
    $tree.ItemHeight = 22
    $tree.ShowLines  = $false
    $tree.ShowPlusMinus = $true
    $tree.ShowRootLines = $true
    $script:MxTree = $tree

    foreach ($g in @('Network', 'Computer', 'Security')) {
        $gn = $tree.Nodes.Add($g.ToUpper())
        $gn.ForeColor = $script:MxAccent
        $gn.NodeFont  = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        $gn.Tag = @{ Kind = 'group'; Group = $g }

        foreach ($s in @('Diagnose', 'Hunt', 'Fix')) {
            $items = @($catalog | Where-Object { $_.Group -eq $g -and $_.Section -eq $s })
            if ($items.Count -eq 0) { continue }
            $sn = $gn.Nodes.Add("$s ($($items.Count))")
            $sn.ForeColor = $script:MxDim
            $sn.Tag = @{ Kind = 'section'; Group = $g; Section = $s; Items = $items }

            foreach ($e in $items) {
                $label = $e.Name
                if ($e.Admin -and -not $script:MxElevated) { $label += '  *' }
                $n = $sn.Nodes.Add($label)
                $n.Tag = @{ Kind = 'entry'; Entry = $e }
                switch ($e.Impact) {
                    'fix'   { $n.ForeColor = $script:MxFix }
                    'heavy' { $n.ForeColor = $script:MxHeavy }
                    default { $n.ForeColor = $script:MxFg }
                }
            }
        }
        $gn.Expand()
    }
    $split.Panel1.Controls.Add($tree)

    # ---------------------------------------------------------- right side --
    $rsplit = New-Object System.Windows.Forms.SplitContainer
    $rsplit.Dock          = 'Fill'
    $rsplit.Orientation   = 'Horizontal'
    $rsplit.SplitterWidth = 6
    $rsplit.BackColor     = [System.Drawing.Color]::FromArgb(58, 64, 76)
    $script:MxRSplit = $rsplit

    # --- board area -------------------------------------------------------
    $boardHost = New-Object System.Windows.Forms.Panel
    $boardHost.Dock = 'Fill'
    $boardHost.BackColor = $script:MxBg

    $board = New-Object System.Windows.Forms.RichTextBox
    $board.Dock        = 'Fill'
    $board.BackColor   = $script:MxBoardBg
    $board.ForeColor   = $script:MxFg
    $board.Font        = New-Object System.Drawing.Font('Consolas', 9.5)
    $board.BorderStyle = 'None'
    $board.WordWrap    = $false
    $board.DetectUrls  = $false
    $board.ReadOnly    = $false
    $board.HideSelection = $false
    $board.ScrollBars  = 'Both'
    $board.MaxLength   = [int]::MaxValue
    $script:MxBoard = $board

    # --- header: which command, and the literal line it runs --------------
    $head = New-Object System.Windows.Forms.Panel
    $script:MxHead = $head
    $head.Dock = 'Top'
    $head.Height = 150
    $head.BackColor = $script:MxPanel
    $head.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 6)

    $hName = New-MxLabel -Text 'Select a command on the left' -Size 11 -Bold $true
    $hName.Dock = 'Top'; $hName.Height = 22
    $script:MxHeadName = $hName

    $hDesc = New-MxLabel -Text '' -Size 9 -Color $script:MxDim
    $hDesc.Dock = 'Top'; $hDesc.Height = 38
    $script:MxHeadDesc = $hDesc

    $hCmd = New-Object System.Windows.Forms.TextBox
    $hCmd.Dock       = 'Fill'
    $hCmd.Multiline  = $true
    $hCmd.ReadOnly   = $true
    $hCmd.ScrollBars = 'Vertical'
    $hCmd.BackColor  = $script:MxBoardBg
    $hCmd.ForeColor  = $script:MxHit
    $hCmd.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $hCmd.BorderStyle = 'FixedSingle'
    $script:MxHeadCmd = $hCmd
    $script:MxTip.SetToolTip($hCmd, (Get-MatriseTip 'ui.cmdbox'))

    $head.Controls.Add($hCmd)
    $head.Controls.Add($hDesc)
    $head.Controls.Add($hName)

    # --- find bar ---------------------------------------------------------
    $findBar = New-Object System.Windows.Forms.Panel
    $findBar.Dock = 'Top'
    $findBar.Height = 34
    $findBar.BackColor = $script:MxBg
    $findBar.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 2)

    $fl = New-MxLabel -Text 'Find' -Size 9 -Color $script:MxDim
    $fl.SetBounds(8, 9, 32, 20)
    $script:MxTip.SetToolTip($fl, (Get-MatriseTip 'ui.find'))
    $findBar.Controls.Add($fl)

    $find = New-Object System.Windows.Forms.TextBox
    $find.SetBounds(44, 5, 300, 24)
    $find.BackColor   = $script:MxPanel
    $find.ForeColor   = $script:MxFg
    $find.BorderStyle = 'FixedSingle'
    $find.Font        = New-Object System.Drawing.Font('Consolas', 10)
    $script:MxFind = $find
    $script:MxTip.SetToolTip($find, (Get-MatriseTip 'ui.find'))
    $findBar.Controls.Add($find)

    $fcount = New-MxLabel -Text '' -Size 9 -Color $script:MxHit
    $fcount.SetBounds(352, 9, 90, 20)
    $script:MxFindCount = $fcount
    $findBar.Controls.Add($fcount)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text      = 'Filter to matching lines only'
    $chk.SetBounds(450, 7, 210, 22)
    $chk.ForeColor = $script:MxFg
    $chk.FlatStyle = 'Flat'
    $script:MxChk = $chk
    $script:MxTip.SetToolTip($chk, (Get-MatriseTip 'ui.filter'))
    $findBar.Controls.Add($chk)

    $wrap = New-Object System.Windows.Forms.CheckBox
    $wrap.Text      = 'Wrap'
    $wrap.SetBounds(668, 7, 66, 22)
    $wrap.ForeColor = $script:MxFg
    $wrap.FlatStyle = 'Flat'
    $script:MxWrap = $wrap
    $script:MxTip.SetToolTip($wrap, (Get-MatriseTip 'ui.wrap'))
    $findBar.Controls.Add($wrap)

    $boardHost.Controls.Add($board)
    $boardHost.Controls.Add($findBar)
    $boardHost.Controls.Add($head)
    $rsplit.Panel1.Controls.Add($boardHost)

    # --- findings ---------------------------------------------------------
    $fsplit = New-Object System.Windows.Forms.SplitContainer
    $fsplit.Dock          = 'Fill'
    $fsplit.SplitterWidth = 6
    $fsplit.BackColor     = [System.Drawing.Color]::FromArgb(58, 64, 76)
    $script:MxFSplit = $fsplit

    $flist = New-Object System.Windows.Forms.ListView
    $flist.Dock          = 'Fill'
    $flist.View          = 'Details'
    $flist.FullRowSelect = $true
    $flist.GridLines     = $false
    $flist.HideSelection = $false
    $flist.MultiSelect   = $false
    $flist.BackColor     = $script:MxPanel
    $flist.ForeColor     = $script:MxFg
    $flist.BorderStyle   = 'None'
    $flist.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    [void]$flist.Columns.Add('Severity', 72)
    [void]$flist.Columns.Add('Line', 52)
    [void]$flist.Columns.Add('Finding', 300)
    [void]$flist.Columns.Add('Evidence', 420)
    $flist.OwnerDraw = $true
    $flist.Add_DrawColumnHeader({
        param($sender, $e)
        $bg = New-Object System.Drawing.SolidBrush($script:MxBg)
        $e.Graphics.FillRectangle($bg, $e.Bounds)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $fmt.Trimming      = [System.Drawing.StringTrimming]::EllipsisCharacter
        $fmt.FormatFlags   = [System.Drawing.StringFormatFlags]::NoWrap
        $rect = New-Object System.Drawing.RectangleF(
            ([single]($e.Bounds.X + 6)), ([single]$e.Bounds.Y),
            ([single]($e.Bounds.Width - 8)), ([single]$e.Bounds.Height))
        $fg = New-Object System.Drawing.SolidBrush($script:MxDim)
        $e.Graphics.DrawString($e.Header.Text, $e.Font, $fg, $rect, $fmt)
        $pen = New-Object System.Drawing.Pen($script:MxPanel)
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
        $bg.Dispose(); $fg.Dispose(); $pen.Dispose(); $fmt.Dispose()
    })
    # Rows keep the default renderer so the per-severity ForeColor still applies.
    $flist.Add_DrawItem({ param($sender, $e) $e.DrawDefault = $true })
    $flist.Add_DrawSubItem({ param($sender, $e) $e.DrawDefault = $true })
    $script:MxFindList = $flist
    $fsplit.Panel1.Controls.Add($flist)

    $why = New-Object System.Windows.Forms.TextBox
    $why.Dock        = 'Fill'
    $why.Multiline   = $true
    $why.ReadOnly    = $true
    $why.ScrollBars  = 'Vertical'
    $why.BackColor   = $script:MxPanel
    $why.ForeColor   = $script:MxFg
    $why.BorderStyle = 'None'
    $why.Font        = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $why.Text        = @(
        'Findings appear here after you press Analyze.',
        '',
        'Click any finding in the list on the left and this panel explains,',
        'in normal words, what was seen, why it matters, and how to tell a',
        'real problem from a false alarm.',
        '',
        'Hover over anything in this window for an explanation of what it does.'
    ) -join "`r`n"
    $script:MxTip.SetToolTip($why, (Get-MatriseTip 'ui.why'))
    $script:MxWhy = $why
    $fsplit.Panel2.Controls.Add($why)

    $rsplit.Panel2.Controls.Add($fsplit)
    $split.Panel2.Controls.Add($rsplit)

    # ------------------------------------------------------------- toolbar --
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock          = 'Top'
    $bar.Height        = 40
    $bar.BackColor     = $script:MxPanel
    $bar.Padding       = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
    $bar.WrapContents  = $false
    $bar.AutoScroll    = $true

    $btnRun = New-MxButton -Text 'Run' -Width 66 -Tip (Get-MatriseTip 'ui.run') -OnClick {
        $node = $script:MxTree.SelectedNode
        if (-not $node -or -not $node.Tag) { $script:MxStatus.Text = 'pick a command first'; return }
        if ($node.Tag.Kind -eq 'entry') { Start-MxEntry -Entry $node.Tag.Entry; return }
        if ($node.Tag.Kind -eq 'section') {
            $safe = @($node.Tag.Items | Where-Object { $_.Impact -eq 'read' -and -not $_.Prompt })
            if ($safe.Count -eq 0) { $script:MxStatus.Text = 'nothing runs unattended in this section'; return }
            $script:MxStatus.Text = "queued $($safe.Count) read-only commands"
            Start-MxBatch -Entries $safe
            return
        }
        $script:MxStatus.Text = 'pick a command or a section'
    }
    $script:MxBtnRun = $btnRun

    $btnCmd = New-MxButton -Text 'Open in CMD' -Width 106 -Tip (Get-MatriseTip 'ui.opencmd') -OnClick {
        $node = $script:MxTree.SelectedNode
        if (-not $node -or -not $node.Tag -or $node.Tag.Kind -ne 'entry') { $script:MxStatus.Text = 'pick a command first'; return }
        $e = Get-MxResolvedEntry -Entry $node.Tag.Entry
        if (-not $e) { return }
        if (-not (Test-MxConfirm -Entry $e)) { return }
        Open-MatriseInConsole -Entry $e -WorkDir $script:MxWorkDir
        $script:MxStatus.Text = 'opened a console window'
    }

    $btnStop = New-MxButton -Text 'Stop' -Width 60 -Tip (Get-MatriseTip 'ui.stop') -OnClick {
        Stop-MatriseRun -Context $script:MxCtx
        $script:MxBatch.Clear()
        $script:MxStatus.Text = 'stopping...'
    }
    $btnStop.Enabled = $false
    $script:MxBtnStop = $btnStop

    $sep1 = New-Object System.Windows.Forms.Label
    $sep1.Text = '|'; $sep1.Width = 14; $sep1.Height = 26; $sep1.ForeColor = $script:MxDim
    $sep1.TextAlign = 'MiddleCenter'

    $btnCopy  = New-MxButton -Text 'Copy board' -Width 96 -Tip (Get-MatriseTip 'ui.copy') -OnClick { Copy-MxBoard }
    $btnPaste = New-MxButton -Text 'Paste in'   -Width 80 -Tip (Get-MatriseTip 'ui.paste') -OnClick { Add-MxFromClipboard }
    $btnLoad  = New-MxButton -Text 'Load file'  -Width 82 -Tip (Get-MatriseTip 'ui.load') -OnClick { Open-MxFile }
    $btnSave  = New-MxButton -Text 'Save report'-Width 96 -Tip (Get-MatriseTip 'ui.save') -OnClick { Save-MxReport }
    $btnClear = New-MxButton -Text 'Clear'      -Width 62 -Tip (Get-MatriseTip 'ui.clear') -OnClick {
        if ($script:MxRaw.Length -gt 0) {
            $r = [System.Windows.Forms.MessageBox]::Show('Clear the board? Anything not saved is lost.', 'Matrise',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Clear-MxBoard
        $script:MxStatus.Text = 'board cleared'
    }

    $sep2 = New-Object System.Windows.Forms.Label
    $sep2.Text = '|'; $sep2.Width = 14; $sep2.Height = 26; $sep2.ForeColor = $script:MxDim
    $sep2.TextAlign = 'MiddleCenter'

    $btnScan  = New-MxButton -Text 'Analyze' -Width 78 -Tip (Get-MatriseTip 'ui.analyze') -OnClick { Invoke-MxAnalyze }
    $btnAgent = New-MxButton -Text 'Ask Claude' -Width 98 -Tip (Get-MatriseTip 'ui.agent') -OnClick { Invoke-MxAgent }

    $btnChunk = New-MxButton -Text 'Copy next part' -Width 116 -Tip (Get-MatriseTip 'ui.chunk') -OnClick { Copy-MxNextChunk }
    $btnChunk.Visible = $false
    $script:MxBtnChunk = $btnChunk

    $autoCopy = New-Object System.Windows.Forms.CheckBox
    $autoCopy.Text = 'Auto-copy'; $autoCopy.Width = 88; $autoCopy.Height = 26
    $autoCopy.ForeColor = $script:MxFg; $autoCopy.FlatStyle = 'Flat'
    $script:MxTip.SetToolTip($autoCopy, (Get-MatriseTip 'ui.autocopy'))
    $script:MxAutoCopy = $autoCopy

    $autoScan = New-Object System.Windows.Forms.CheckBox
    $autoScan.Text = 'Auto-analyze'; $autoScan.Width = 106; $autoScan.Height = 26
    $autoScan.Checked = $true
    $autoScan.ForeColor = $script:MxFg; $autoScan.FlatStyle = 'Flat'
    $script:MxTip.SetToolTip($autoScan, (Get-MatriseTip 'ui.autoscan'))
    $script:MxAutoScan = $autoScan

    $bar.Controls.AddRange(@($btnRun, $btnCmd, $btnStop, $sep1,
                             $btnCopy, $btnPaste, $btnLoad, $btnSave, $btnClear, $sep2,
                             $btnScan, $btnAgent, $btnChunk, $autoCopy, $autoScan))

    # ----------------------------------------------------------- status bar -
    $status = New-Object System.Windows.Forms.StatusStrip
    $status.BackColor = $script:MxPanel
    $status.SizingGrip = $true

    $sMain = New-Object System.Windows.Forms.ToolStripStatusLabel
    $sMain.Text = 'ready'; $sMain.Spring = $true; $sMain.TextAlign = 'MiddleLeft'
    $sMain.ForeColor = $script:MxFg
    $script:MxStatus = $sMain

    $sFind = New-Object System.Windows.Forms.ToolStripStatusLabel
    $sFind.Text = '0 findings'; $sFind.ForeColor = $script:MxDim
    $script:MxStatFind = $sFind

    $sLines = New-Object System.Windows.Forms.ToolStripStatusLabel
    $sLines.Text = '0 lines'; $sLines.ForeColor = $script:MxDim
    $sLines.ToolTipText = Get-MatriseTip 'ui.board'
    $script:MxStatLines = $sLines

    $sAdmin = New-Object System.Windows.Forms.ToolStripStatusLabel
    if ($script:MxElevated) {
        $sAdmin.Text = 'ADMIN'; $sAdmin.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 140)
    } else {
        $sAdmin.Text = 'not elevated - * commands return partial data'
        $sAdmin.ForeColor = $script:MxFix
    }
    $sAdmin.ToolTipText = Get-MatriseTip 'ui.admin'

    [void]$status.Items.AddRange(@($sMain, $sFind, $sLines, $sAdmin))

    # Dock order matters: the Fill control must be added first so it ends up
    # last in the layout pass and receives whatever space is left over.
    $form.Controls.Add($split)
    $form.Controls.Add($bar)
    $form.Controls.Add($status)

    # ------------------------------------------------------------- events --
    $tree.Add_AfterSelect({
        $node = $script:MxTree.SelectedNode
        if (-not $node -or -not $node.Tag) { return }
        if ($node.Tag.Kind -eq 'entry') {
            $e = $node.Tag.Entry
            $script:MxHeadName.Text = $e.Name
            $tags = @()
            if ($e.Impact -ne 'read') { $tags += $e.Impact.ToUpper() }
            if ($e.Admin) { $tags += 'NEEDS ADMIN' }
            if ($e.Prompt) { $tags += 'ASKS FOR INPUT' }
            $suffix = $(if ($tags.Count) { '   [' + ($tags -join ' / ') + ']' } else { '' })
            $script:MxHeadDesc.Text = $e.Desc + $suffix
            $script:MxHeadCmd.Text  = ((Get-MatriseCommandLine -Entry $e) + "`r`n`r`n" + $e.Command) -replace "`r?`n", "`r`n"
            $script:MxHeadName.ForeColor = $(switch ($e.Impact) {
                'fix'   { $script:MxFix }
                'heavy' { $script:MxHeavy }
                default { $script:MxFg }
            })
            $plain = Format-MatriseExplain -Entry $e
            $script:MxTip.SetToolTip($script:MxHeadName, $plain)
            $script:MxTip.SetToolTip($script:MxHeadDesc, $plain)
            Update-MxHeadHeight
        }
        elseif ($node.Tag.Kind -eq 'section') {
            $n = @($node.Tag.Items).Count
            $safe = @($node.Tag.Items | Where-Object { $_.Impact -eq 'read' -and -not $_.Prompt }).Count
            $script:MxHeadName.Text = "$($node.Tag.Group) / $($node.Tag.Section)"
            $script:MxHeadName.ForeColor = $script:MxFg
            $script:MxHeadDesc.Text = "$n commands here. Press Run to execute the $safe read-only ones back to back and collect everything on one board."
            $script:MxHeadCmd.Text  = (@($node.Tag.Items) | ForEach-Object { "- $($_.Name)" }) -join "`r`n"
            Update-MxHeadHeight
        }
        else {
            $script:MxHeadName.Text = $node.Text
            $script:MxHeadName.ForeColor = $script:MxFg
            $script:MxHeadDesc.Text = 'Open a section and pick a command.'
            $script:MxHeadCmd.Text  = ''
        }
    })

    $tree.Add_NodeMouseHover({
        param($sender, $e)
        Show-MxNodeTip -Node $e.Node
    })
    $tree.Add_MouseLeave({ $script:MxTipNode.Hide($script:MxTree) })
    $tree.Add_NodeMouseClick({ $script:MxTipNode.Hide($script:MxTree) })

    $tree.Add_NodeMouseDoubleClick({
        param($s, $e)
        if ($e.Node.Tag -and $e.Node.Tag.Kind -eq 'entry') { Start-MxEntry -Entry $e.Node.Tag.Entry }
    })

    $find.Add_TextChanged({
        if ($script:MxChk.Checked) { Set-MxFilter $true } else { Invoke-MxHighlightAll $script:MxFind.Text }
    })

    $find.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            Invoke-MxFindNext -Backwards $e.Shift
            $e.SuppressKeyPress = $true
            $e.Handled = $true
        }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:MxFind.Text = ''
            $script:MxChk.Checked = $false
            $script:MxBoard.Focus()
        }
    })

    $chk.Add_CheckedChanged({ Set-MxFilter $script:MxChk.Checked })
    $wrap.Add_CheckedChanged({ $script:MxBoard.WordWrap = $wrap.Checked })

    $flist.Add_SelectedIndexChanged({
        if ($script:MxFindList.SelectedItems.Count -eq 0) { return }
        $f = $script:MxFindList.SelectedItems[0].Tag
        $script:MxWhy.Text = @(
            "[$($f.Severity)]  $($f.Title)",
            '',
            "line $($f.Line):",
            "  $($f.Evidence)",
            '',
            'WHY THIS MATTERS',
            $f.Why,
            '',
            "(rule: $($f.RuleId) - double-click the row to jump to that line on the board)"
        ) -join "`r`n"
    })

    $flist.Add_MouseMove({
        param($sender, $e)
        $it = $script:MxFindList.GetItemAt($e.X, $e.Y)
        $key = $(if ($it) { "row$($it.Index)" } else { 'none' })
        if ($key -eq $script:MxTipRow) { return }
        $script:MxTipRow = $key

        if (-not $it) {
            $script:MxTipText = "Findings`r`n`r`n" + (Get-MatriseTip 'ui.findings')
            $script:MxTipNode.Show($script:MxTipText, $script:MxFindList, ($e.X + 20), ($e.Y + 20), 32000)
            return
        }
        $f = $it.Tag
        $body = @(
            ("Found on line {0}:" -f $f.Line),
            (Format-MatriseWrap -Text $f.Evidence -Width 64),
            '',
            'WHY THIS MATTERS',
            (Format-MatriseWrap -Text $f.Why -Width 64),
            '',
            'Double-click this row to jump to that line on the board.'
        ) -join "`r`n"
        $script:MxTipText = "[$($f.Severity)]  $($f.Title)`r`n`r`n" + $body
        $script:MxTipNode.Show($script:MxTipText, $script:MxFindList, ($e.X + 20), ($e.Y + 20), 32000)
    })
    $flist.Add_MouseLeave({
        $script:MxTipNode.Hide($script:MxFindList)
        $script:MxTipRow = ''
    })

    $flist.Add_DoubleClick({
        if ($script:MxFindList.SelectedItems.Count -eq 0) { return }
        Move-MxToLine -Line ([int]$script:MxFindList.SelectedItems[0].Tag.Line)
    })

    $form.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $script:MxFind.Focus(); $script:MxFind.SelectAll()
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F3) {
            Invoke-MxFindNext -Backwards $e.Shift
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
            $btnRun.PerformClick()
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })

    # Drain the runner queue on a timer. This is the only place output moves
    # from the background runspace into the control, which keeps every UI
    # touch on the UI thread.
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $script:MxTimer = $timer
    $timer.Add_Tick({
        if (-not $script:MxCtx) { return }
        $q = $script:MxCtx.Queue
        $n = 0
        while ($q.Count -gt 0 -and $n -lt 4000) {
            Add-MxBoardLine ([string]$q.Dequeue())
            $n++
        }
        Update-MxBoardFlush

        if ($script:MxCtx.State['Started'] -and $script:MxCtx.State['Running']) {
            $el = [math]::Round(((Get-Date) - $script:MxCtx.State['Started']).TotalSeconds)
            $script:MxStatus.Text = "running: $($script:MxEntry.Name)   ${el}s"
        }
        if ($script:MxCtx.State['Done'] -and $q.Count -eq 0) {
            Complete-MxRun
        }
    })

    $form.Add_Shown({
        $L = $script:MxLayout
        try {
            $script:MxSplit.Panel1MinSize = 240
            $script:MxSplit.Panel2MinSize = 480
            $script:MxSplit.SplitterDistance = Get-MxClamped $(if ($L) { $L.SplitMain }) `
                340 240 ($script:MxSplit.Width - 480)
        } catch { }
        try {
            $script:MxRSplit.Panel1MinSize = 220
            $script:MxRSplit.Panel2MinSize = 140
            $script:MxRSplit.SplitterDistance = Get-MxClamped $(if ($L) { $L.SplitBoard }) `
                ([int]($script:MxRSplit.Height * 0.64)) 220 ($script:MxRSplit.Height - 140)
        } catch { }
        try {
            $script:MxFSplit.Panel1MinSize = 300
            $script:MxFSplit.Panel2MinSize = 260
            $script:MxFSplit.SplitterDistance = Get-MxClamped $(if ($L) { $L.SplitFind }) `
                ([int]($script:MxFSplit.Width * 0.62)) 300 ($script:MxFSplit.Width - 260)
        } catch { }
        if ($L -and $L.Wrap) { $script:MxBoard.WordWrap = $true; $script:MxWrap.Checked = $true }

        Update-MxFindColumns
        Update-MxHeadHeight
        $script:MxLayoutReady = $true

        # Land on the command the welcome text points at, rather than making
        # the user hunt for it through two collapsed levels.
        foreach ($g in $script:MxTree.Nodes) {
            if ($g.Tag.Group -ne 'Security') { continue }
            foreach ($sec in $g.Nodes) {
                if ($sec.Tag.Section -ne 'Hunt') { continue }
                $sec.Expand()
                if ($sec.Nodes.Count -gt 0) { $script:MxTree.SelectedNode = $sec.Nodes[0] }
            }
        }
        $script:MxTree.Select()
    })

    $form.Add_Resize({
        if (-not $script:MxLayoutReady) { return }
        Update-MxFindColumns
        Update-MxHeadHeight
    })
    $fsplit.Add_SplitterMoved({ Update-MxFindColumns })
    $rsplit.Add_SplitterMoved({ if ($script:MxLayoutReady) { Update-MxHeadHeight } })

    $form.Add_FormClosing({
        if ($script:MxCtx -and $script:MxCtx.State['Running']) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "A command is still running. Stop it and close?", 'Matrise',
                [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true; return }
            Stop-MatriseRun -Context $script:MxCtx
        }
        Save-MxLayout
        $script:MxTimer.Stop()
        Close-MatriseRun -Context $script:MxCtx
    })

    # ------------------------------------------------------------- welcome --
    Add-MxBoardLine '  __  __       _        _'
    Add-MxBoardLine ' |  \/  | __ _| |_ _ __(_)___  ___'
    Add-MxBoardLine ' | |\/| |/ _` | __| ''__| / __|/ _ \'
    Add-MxBoardLine ' | |  | | (_| | |_| |  | \__ \  __/'
    Add-MxBoardLine ' |_|  |_|\__,_|\__|_|  |_|___/\___|   security and system helper'
    Add-MxBoardLine ''
    Add-MxBoardLine "  machine   : $env:COMPUTERNAME        user: $env:USERNAME"
    Add-MxBoardLine "  elevated  : $script:MxElevated"
    Add-MxBoardLine "  commands  : $(@($catalog).Count) across Network, Computer and Security"
    Add-MxBoardLine ''
    Add-MxBoardLine '  HOW THIS WORKS'
    Add-MxBoardLine '    1. Pick a command on the left. The exact line it will run is shown above,'
    Add-MxBoardLine '       so you always know what is about to happen.'
    Add-MxBoardLine '    2. Run it. Output lands here on the board and stays here - every command'
    Add-MxBoardLine '       you run appends, so you build one searchable record of the whole session.'
    Add-MxBoardLine '    3. Ctrl+F searches the board. Tick "Filter to matching lines only" to strip'
    Add-MxBoardLine '       a huge dump down to just the lines you care about.'
    Add-MxBoardLine '    4. Analyze runs the offline rule engine. Findings appear below with a'
    Add-MxBoardLine '       plain-language reason; double-click one to jump to the line.'
    Add-MxBoardLine '    5. Ask Claude sends the whole board for a second opinion.'
    Add-MxBoardLine ''
    Add-MxBoardLine '  COLOUR CODE IN THE TREE'
    Add-MxBoardLine '    white  = read-only, safe to run any time'
    Add-MxBoardLine '    amber  = changes your system, asks first'
    Add-MxBoardLine '    red    = slow, or needs a reboot'
    Add-MxBoardLine '    *      = returns partial data unless you run Matrise as Administrator'
    Add-MxBoardLine ''
    Add-MxBoardLine '  START WITH: Security > Hunt > FULL SWEEP'
    Add-MxBoardLine ''
    Update-MxBoardFlush

    if ($SelfTestMs -gt 0) {
        $script:MxSelfFail = 0
        $st = New-Object System.Windows.Forms.Timer
        $st.Interval = $SelfTestMs
        $st.Add_Tick({ $st.Stop(); Invoke-MxSelfTestPhase1 })
        $st.Start()
    }

    [void]$form.ShowDialog()
    $form.Dispose()
}
