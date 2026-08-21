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

# Remote execution goes through PowerShell Remoting from inside the worker
# runspace rather than by spawning a child process. That keeps the credential
# as a live PSCredential object - it is never written to a temp file, never
# appears on a command line, and never lands in a process listing.
$script:MatriseRemoteWorker = {
    param($shell, $command, $queue, $state, $timeoutSec, $targetName, $credential, $useSsl, $configName)

    function Emit($line) { $queue.Enqueue($line) }

    try {
        $state['Running'] = $true

        $icm = @{
            ComputerName = $targetName
            ErrorAction  = 'Stop'
        }
        if ($credential) { $icm['Credential'] = $credential }
        if ($useSsl)     { $icm['UseSSL'] = $true }
        if ($configName) { $icm['ConfigurationName'] = $configName }

        if ($shell -eq 'cmd') {
            $icm['ScriptBlock'] = {
                param($c)
                & "$env:SystemRoot\System32\cmd.exe" /d /c $c 2>&1
            }
            $icm['ArgumentList'] = @($command)
        }
        else {
            # Built on the far side so the body runs as a script, not as text
            # pasted into another string.
            $icm['ScriptBlock'] = {
                param($body)
                $ErrorActionPreference = 'Continue'
                $ProgressPreference = 'SilentlyContinue'
                $FormatEnumerationLimit = -1
                & ([scriptblock]::Create($body)) 2>&1
            }
            $icm['ArgumentList'] = @($command)
        }

        Emit "Connecting to $targetName ..."
        $deadline = (Get-Date).AddSeconds($timeoutSec)

        Invoke-Command @icm | ForEach-Object {
            if ($null -ne $_) {
                foreach ($l in (($_ | Out-String -Width 400) -split "`r?`n")) { Emit $l }
            }
            if ($state['Cancelled']) { throw 'cancelled-by-user' }
            if ((Get-Date) -gt $deadline) { throw "timed-out-after-$timeoutSec-seconds" }
        }

        $state['ExitCode'] = 0
    }
    catch {
        $m = $_.Exception.Message
        Emit ''
        if ($m -eq 'cancelled-by-user') {
            Emit '*** STOPPED BY USER ***'
        }
        elseif ($m -like 'timed-out-*') {
            Emit "*** TIMED OUT after $timeoutSec seconds ***"
        }
        else {
            Emit "*** REMOTE EXECUTION FAILED ***"
            Emit $m
            Emit ''
            if ($m -match 'Access is denied') {
                Emit 'Your account is not permitted to run commands on that machine.'
                Emit 'In a managed estate that permission comes from an AD group, not'
                Emit 'from a local account. Ask for the endpoint support group.'
            }
            elseif ($m -match 'cannot find the computer|WinRM|not resolve') {
                Emit 'The machine did not answer on WinRM. Use "Test connection" for a'
                Emit 'step by step check of DNS, the port and authentication.'
            }
            elseif ($m -match 'not recognized|CommandNotFound') {
                Emit 'The endpoint accepted the connection but refused the command.'
                Emit 'If you are connecting to a constrained (JEA) endpoint, that is it'
                Emit 'working as intended: the command is not on the approved list.'
            }
        }
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
        [string]$WorkDir,
        $Target = $null
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

    if ($Target -and $Target.Mode -eq 'remote') {
        [void]$ps.AddScript($script:MatriseRemoteWorker)
        [void]$ps.AddArgument($Entry.Shell)
        [void]$ps.AddArgument($Entry.Command)
        [void]$ps.AddArgument($Context.Queue)
        [void]$ps.AddArgument($Context.State)
        [void]$ps.AddArgument($Entry.Timeout)
        [void]$ps.AddArgument($Target.Name)
        [void]$ps.AddArgument($Target.Credential)
        [void]$ps.AddArgument($Target.UseSsl)
        [void]$ps.AddArgument($Target.ConfigName)
    }
    else {
        [void]$ps.AddScript($script:MatriseWorker)
        [void]$ps.AddArgument($Entry.Shell)
        [void]$ps.AddArgument($Entry.Command)
        [void]$ps.AddArgument($Context.Queue)
        [void]$ps.AddArgument($Context.State)
        [void]$ps.AddArgument($Entry.Timeout)
        [void]$ps.AddArgument($WorkDir)
    }

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
