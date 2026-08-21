# Matrise - Command runner
#
# Runs a catalog entry in a background runspace so the GUI never freezes.
# Output lines land in a synchronized queue that the UI drains on a timer.

function New-MatriseRunContext {
    $q = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $state = [hashtable]::Synchronized(@{
        Running   = $false
        Done      = $false
        ExitCode  = $null
        ProcId    = 0
        Started   = $null
        Label     = ''
        Cancelled = $false
    })
    [pscustomobject]@{ Queue = $q; State = $state; Runspace = $null; Handle = $null; Shell = $null }
}

# The literal command line Matrise hands to the OS, shown in the UI and written
# into the report header so nothing ever runs behind your back.
function Get-MatriseCommandLine {
    param($Entry)
    if ($Entry.Shell -eq 'cmd') {
        return "cmd.exe /d /c $($Entry.Command)"
    }
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"<script below>`""
}

$script:MatriseWorker = {
    param($shell, $command, $queue, $state, $timeoutSec, $workDir)

    function Emit($line) { $queue.Enqueue($line) }

    try {
        $state['Running'] = $true

        $tempScript = $null
        $psi = New-Object System.Diagnostics.ProcessStartInfo

        if ($shell -eq 'ps') {
            $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("matrise-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
            $header = @(
                '$ErrorActionPreference = ''Continue''',
                '$ProgressPreference = ''SilentlyContinue''',
                '$FormatEnumerationLimit = -1',
                ''
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($tempScript, $header + $command, [System.Text.Encoding]::UTF8)
            $psi.FileName  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tempScript`""
        }
        else {
            $psi.FileName  = "$env:SystemRoot\System32\cmd.exe"
            $psi.Arguments = "/d /c $command"
        }

        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = $true
        $psi.WorkingDirectory       = $workDir

        # Console tools emit in the OEM code page. Decode with the same one or
        # box-drawing characters and accented names arrive as garbage.
        try {
            $oem = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
            $enc = [System.Text.Encoding]::GetEncoding($oem)
            $psi.StandardOutputEncoding = $enc
            $psi.StandardErrorEncoding  = $enc
        } catch { }

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $state['ProcId'] = $proc.Id

        # Close stdin immediately: anything that tries to read input gets EOF
        # instead of hanging forever in a window nobody can see.
        try { $proc.StandardInput.Close() } catch { }

        # Drain stderr on the thread pool so a chatty error stream can never
        # deadlock the pipe while we are blocked reading stdout.
        $errTask = $proc.StandardError.ReadToEndAsync()

        $deadline = (Get-Date).AddSeconds($timeoutSec)

        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -ne $line) { Emit $line }

            if ($state['Cancelled']) {
                try { $proc.Kill() } catch { }
                Emit ''
                Emit '*** STOPPED BY USER ***'
                break
            }
            if ((Get-Date) -gt $deadline) {
                try { $proc.Kill() } catch { }
                Emit ''
                Emit "*** TIMED OUT after $timeoutSec seconds - process killed ***"
                break
            }
        }

        if (-not $state['Cancelled']) { [void]$proc.WaitForExit(5000) }

        $err = ''
        try { $err = $errTask.Result } catch { }
        if ($err -and $err.Trim().Length -gt 0) {
            Emit ''
            Emit '--- stderr ---'
            foreach ($l in ($err -split "`r?`n")) { Emit $l }
        }

        try { $state['ExitCode'] = $proc.ExitCode } catch { $state['ExitCode'] = -1 }
        $proc.Dispose()
        if ($tempScript -and (Test-Path $tempScript)) {
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Emit ''
        Emit "*** MATRISE RUNNER ERROR: $($_.Exception.Message) ***"
        $state['ExitCode'] = -1
    }
    finally {
        $state['Running'] = $false
        $state['Done']    = $true
    }
}

function Start-MatriseRun {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] $Entry,
        [string]$WorkDir
    )

    $Context.State['Running']   = $false
    $Context.State['Done']      = $false
    $Context.State['ExitCode']  = $null
    $Context.State['ProcId']    = 0
    $Context.State['Cancelled'] = $false
    $Context.State['Started']   = Get-Date
    $Context.State['Label']     = $Entry.Name

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:MatriseWorker)
    [void]$ps.AddArgument($Entry.Shell)
    [void]$ps.AddArgument($Entry.Command)
    [void]$ps.AddArgument($Context.Queue)
    [void]$ps.AddArgument($Context.State)
    [void]$ps.AddArgument($Entry.Timeout)
    [void]$ps.AddArgument($WorkDir)

    $Context.Runspace = $rs
    $Context.Shell    = $ps
    $Context.Handle   = $ps.BeginInvoke()
    $Context
}

function Stop-MatriseRun {
    param($Context)
    if (-not $Context) { return }
    $Context.State['Cancelled'] = $true
    $procId = $Context.State['ProcId']
    if ($procId -gt 0) {
        # Kill the whole tree: netsh, sfc and dism all spawn children that
        # happily outlive the parent we started.
        try { Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" `
                -ArgumentList "/PID", $procId, "/T", "/F" -WindowStyle Hidden -Wait } catch { }
    }
}

function Close-MatriseRun {
    param($Context)
    if (-not $Context) { return }
    try { if ($Context.Shell)    { $Context.Shell.Dispose() } } catch { }
    try { if ($Context.Runspace) { $Context.Runspace.Close(); $Context.Runspace.Dispose() } } catch { }
    $Context.Shell    = $null
    $Context.Runspace = $null
    $Context.Handle   = $null
}

# Escape a string so a batch file 'echo' prints it literally.
function ConvertTo-MatriseBatEcho {
    param([string]$Text)
    $t = $Text -replace '\^', '^^'
    $t = $t -replace '&', '^&'
    $t = $t -replace '<', '^<'
    $t = $t -replace '>', '^>'
    $t = $t -replace '\|', '^|'
    $t = $t -replace '%', '%%'
    $t
}

# Opens the command in a REAL, visible console window that stays open, so you
# can watch it live and scroll/copy in the terminal itself.
function Open-MatriseInConsole {
    param($Entry, [string]$WorkDir)

    $dir = Join-Path $WorkDir 'reports\_console'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safe  = ($Entry.Id -replace '[^A-Za-z0-9._-]', '_')

    if ($Entry.Shell -eq 'cmd') {
        $bat = Join-Path $dir "$stamp-$safe.bat"
        $lines = @(
            '@echo off',
            "title Matrise - $($Entry.Name)",
            'echo ================================================================',
            "echo  MATRISE  ^|  $(ConvertTo-MatriseBatEcho $Entry.Name)",
            'echo ================================================================',
            'echo.',
            "echo COMMAND:",
            "echo   $(ConvertTo-MatriseBatEcho $Entry.Command)",
            'echo.',
            'echo ----------------------------------------------------------------',
            'echo.',
            $Entry.Command,
            'echo.',
            'echo ----------------------------------------------------------------',
            'echo Finished. This window stays open - type exit to close it.'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($bat, $lines, [System.Text.Encoding]::Default)
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/k", "`"$bat`""
    }
    else {
        $ps1 = Join-Path $dir "$stamp-$safe.ps1"
        $body = @(
            "`$ErrorActionPreference = 'Continue'",
            "`$ProgressPreference = 'SilentlyContinue'",
            "`$Host.UI.RawUI.WindowTitle = 'Matrise - $($Entry.Name)'",
            "Write-Host '================================================================' -ForegroundColor Cyan",
            "Write-Host '  MATRISE  |  $($Entry.Name)' -ForegroundColor Cyan",
            "Write-Host '================================================================' -ForegroundColor Cyan",
            "Write-Host ''",
            "Write-Host 'COMMAND:' -ForegroundColor Yellow",
            "`$matriseCmdText = @'",
            $Entry.Command,
            "'@",
            "`$matriseCmdText -split ""``r?``n"" | ForEach-Object { Write-Host ('   ' + `$_) -ForegroundColor DarkGray }",
            "Write-Host ''",
            "Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray",
            "Write-Host ''",
            '',
            $Entry.Command,
            '',
            "Write-Host ''",
            "Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray",
            "Write-Host 'Finished. This window stays open - type exit to close it.' -ForegroundColor Green"
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($ps1, $body, [System.Text.Encoding]::UTF8)
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$ps1`""
    }
}

# Console scripts are kept so you can inspect exactly what ran; drop old ones.
function Clear-MatriseConsoleScripts {
    param([string]$WorkDir, [int]$OlderThanDays = 2)
    $dir = Join-Path $WorkDir 'reports\_console'
    if (-not (Test-Path $dir)) { return }
    $cut = (Get-Date).AddDays(-$OlderThanDays)
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Test-MatriseElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
