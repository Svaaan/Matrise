# Matrise - Hover explanations
#
# A hand-built popup rather than the WinForms ToolTip.
#
# The native control was the wrong tool: it ignores owner-drawing in several
# situations so the panel kept coming out in the system light theme, and it
# owns its own show / fade / reshow / reposition logic, which is why the panel
# drifted around instead of sitting on the thing being explained.
#
# This is a borderless, never-activated window that appears at a position we
# choose, stays there, and disappears the moment the pointer leaves.

if (-not ('MxPopupForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;

public class MxPopupForm : Form
{
    public MxPopupForm()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.UserPaint, true);
    }

    // Never take focus: the main window must stay active while this is up.
    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle    |= 0x08000000; // WS_EX_NOACTIVATE
            cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
            return cp;
        }
    }
}
'@
}

# ------------------------------------------------------------------ look ---
$script:MxPopBg     = [System.Drawing.Color]::FromArgb(34, 38, 46)
$script:MxPopBorder = [System.Drawing.Color]::FromArgb(88, 166, 255)
$script:MxPopTitle  = [System.Drawing.Color]::FromArgb(126, 187, 255)
$script:MxPopHead   = [System.Drawing.Color]::FromArgb(146, 155, 168)
$script:MxPopBody   = [System.Drawing.Color]::FromArgb(222, 226, 232)
$script:MxPopWarn   = [System.Drawing.Color]::FromArgb(255, 184, 92)
$script:MxPopSafe   = [System.Drawing.Color]::FromArgb(124, 222, 146)

$script:MxPopFont     = New-Object System.Drawing.Font('Segoe UI', 9)
$script:MxPopFontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# ----------------------------------------------------------------- state ---
$script:MxPop        = $null
$script:MxPopLines   = @()
$script:MxHoverText  = ''
$script:MxHoverPoint = New-Object System.Drawing.Point(0, 0)
$script:MxHoverKey   = ''
$script:MxHoverTimer = $null

function Get-MxPopLineStyle {
    param([string]$Line, [int]$Index)
    if ($Index -eq 0)                                { return @{ Font = $script:MxPopFontBold; Color = $script:MxPopTitle } }
    if ($Line -cmatch '^[A-Z][A-Z ]{3,}$')           { return @{ Font = $script:MxPopFontBold; Color = $script:MxPopHead } }
    if ($Line -cmatch '^(CAREFUL|NEEDS ADMINISTRATOR|ASKS YOU FIRST)') { return @{ Font = $script:MxPopFont; Color = $script:MxPopWarn } }
    if ($Line -cmatch '^SAFE')                       { return @{ Font = $script:MxPopFont; Color = $script:MxPopSafe } }
    @{ Font = $script:MxPopFont; Color = $script:MxPopBody }
}

function Initialize-MxHover {
    if ($script:MxPop) { return }

    $pop = New-Object MxPopupForm
    $pop.FormBorderStyle = 'None'
    $pop.ShowInTaskbar   = $false
    $pop.StartPosition   = 'Manual'
    $pop.TopMost         = $true
    $pop.BackColor       = $script:MxPopBg
    $pop.Visible         = $false

    $pop.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.Clear($script:MxPopBg)
        $pen = New-Object System.Drawing.Pen ($script:MxPopBorder)
        $g.DrawRectangle($pen, 0, 0, ($script:MxPop.Width - 1), ($script:MxPop.Height - 1))
        $pen.Dispose()

        $y = 10
        for ($i = 0; $i -lt $script:MxPopLines.Count; $i++) {
            $st = Get-MxPopLineStyle -Line $script:MxPopLines[$i] -Index $i
            [System.Windows.Forms.TextRenderer]::DrawText($g, $script:MxPopLines[$i], $st.Font,
                (New-Object System.Drawing.Point(13, $y)), $st.Color)
            $y += $script:MxPopFont.Height
        }
    })

    $script:MxPop = $pop

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 320
    $t.Add_Tick({
        $script:MxHoverTimer.Stop()
        if ($script:MxHoverText) { Show-MxPop -Text $script:MxHoverText -At $script:MxHoverPoint }
    })
    $script:MxHoverTimer = $t
}

function Measure-MxPop {
    param($Lines)
    $w = 0
    foreach ($l in $Lines) {
        $lw = [System.Windows.Forms.TextRenderer]::MeasureText($l, $script:MxPopFontBold).Width
        if ($lw -gt $w) { $w = $lw }
    }
    New-Object System.Drawing.Size (($w + 28), (($Lines.Count * $script:MxPopFont.Height) + 20))
}

# Places the panel at the requested spot, nudged only as far as needed to stay
# on screen. It does not follow the pointer.
function Show-MxPop {
    param([string]$Text, [System.Drawing.Point]$At)
    if (-not $script:MxPop -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $script:MxPopLines = @($Text -split "`r?`n")
    $sz = Measure-MxPop $script:MxPopLines
    $wa = [System.Windows.Forms.Screen]::FromPoint($At).WorkingArea

    $x = [math]::Min($At.X, ($wa.Right - $sz.Width - 6))
    $x = [math]::Max($x, ($wa.Left + 4))
    $y = $At.Y
    if (($y + $sz.Height) -gt $wa.Bottom) { $y = $At.Y - $sz.Height - 22 }  # flip above the item
    $y = [math]::Max($y, ($wa.Top + 4))

    $script:MxPop.Bounds = New-Object System.Drawing.Rectangle $x, $y, $sz.Width, $sz.Height
    $script:MxPop.Invalidate()
    if (-not $script:MxPop.Visible) { $script:MxPop.Show() }
}

function Hide-MxPop {
    if ($script:MxHoverTimer) { $script:MxHoverTimer.Stop() }
    $script:MxHoverText = ''
    $script:MxHoverKey  = ''
    if ($script:MxPop -and $script:MxPop.Visible) { $script:MxPop.Hide() }
}

# Wait a moment before the first panel appears so it does not flash while the
# pointer is just passing through. Once one is up, moving to the next item
# swaps instantly rather than waiting again.
function Request-MxPop {
    param([string]$Text, [System.Drawing.Point]$At)
    if ([string]::IsNullOrWhiteSpace($Text)) { Hide-MxPop; return }
    $script:MxHoverText  = $Text
    $script:MxHoverPoint = $At
    if ($script:MxPop -and $script:MxPop.Visible) {
        Show-MxPop -Text $Text -At $At
    } else {
        $script:MxHoverTimer.Stop()
        $script:MxHoverTimer.Start()
    }
}

# --------------------------------------------------------------- wiring ----
# Anchored under the control's bottom-left corner, so the panel always appears
# in the same place relative to the thing it explains.
function Register-MxHover {
    param($Control, [string]$Text)
    if (-not $Control -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $Control.Add_MouseEnter({
        $p = $Control.PointToScreen((New-Object System.Drawing.Point(0, ($Control.Height + 5))))
        Request-MxPop -Text $Text -At $p
    })
    $Control.Add_MouseLeave({ Hide-MxPop })
}

# Toolbar and status-bar items are ToolStripItems, not Controls, so their
# screen position has to be resolved through the strip that owns them.
function Register-MxHoverItem {
    param($Item, $Strip, [string]$Text)
    if (-not $Item -or [string]::IsNullOrWhiteSpace($Text)) { return }

    $Item.Add_MouseEnter({
        $p = $Strip.PointToScreen((New-Object System.Drawing.Point($Item.Bounds.Left, $Item.Bounds.Top)))
        Request-MxPop -Text $Text -At $p
    })
    $Item.Add_MouseLeave({ Hide-MxPop })
}

function Close-MxHover {
    if ($script:MxHoverTimer) { $script:MxHoverTimer.Stop(); $script:MxHoverTimer.Dispose(); $script:MxHoverTimer = $null }
    if ($script:MxPop) { $script:MxPop.Hide(); $script:MxPop.Dispose(); $script:MxPop = $null }
}
