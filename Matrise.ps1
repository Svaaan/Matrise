# Matrise - security and system helper for Windows
#
#   .\Matrise.ps1                        open the window
#   .\Matrise.ps1 -Target WS-4471        open the window aimed at another machine
#
#   .\Matrise.ps1 -Analyze <file>        run the rule engine over a file, print, exit
#   .\Matrise.ps1 -List                  print the catalog with each policy decision
#   .\Matrise.ps1 -SelfTest              drive the window through a scripted pass
#   .\Matrise.ps1 -TestRemote <host>     prove the whole remote path end to end
#
#   .\Matrise.ps1 -ExportJea <dir>       generate the JEA endpoint from catalog + policy
#   .\Matrise.ps1 -Requests              list access requests
#   .\Matrise.ps1 -Approve <id> [-Minutes 60] [-Comment "..."]
#   .\Matrise.ps1 -Deny    <id>          [-Comment "..."]
#
# Normally you launch this through Matrise.bat, which elevates first.

[CmdletBinding()]
param(
    [string]$Analyze,
    [switch]$List,
    [switch]$SelfTest,
    [string]$Target,
    [string]$TestRemote,
    [string]$ExportJea,
    [switch]$Requests,
    [switch]$Unblock,
    [string]$Approve,
    [string]$Deny,
    [int]$Minutes = 0,
    [string]$Comment = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:MATRISE_HOME = $root

. (Join-Path $root 'lib\Explain.ps1')
. (Join-Path $root 'lib\Hover.ps1')
. (Join-Path $root 'lib\Catalog.ps1')
. (Join-Path $root 'lib\Runner.ps1')
. (Join-Path $root 'lib\Analyzer.ps1')
. (Join-Path $root 'lib\Agent.ps1')
. (Join-Path $root 'lib\Target.ps1')
. (Join-Path $root 'lib\Peer.ps1')
. (Join-Path $root 'lib\Policy.ps1')
. (Join-Path $root 'lib\Requests.ps1')
. (Join-Path $root 'lib\Jea.ps1')

$policy = Import-MatrisePolicy -WorkDir $root

# ---- headless: analyze a file ------------------------------------------
if ($Analyze) {
    if (-not (Test-Path $Analyze)) { Write-Error "No such file: $Analyze"; exit 1 }
    $text = [System.IO.File]::ReadAllText((Resolve-Path $Analyze))
    $findings = Invoke-MatriseAnalysis -Text $text
    Write-Output (Format-MatriseFindings -Findings $findings)
    exit $(if (@($findings | Where-Object { $_.Severity -in 'Critical', 'High' }).Count -gt 0) { 2 } else { 0 })
}

# ---- headless: clear the downloaded-from-the-internet mark --------------
if ($Unblock) {
    $n = 0
    Get-ChildItem $root -Recurse -Include *.ps1, *.bat, *.json, *.md -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Get-Item $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
                Unblock-File $_.FullName -ErrorAction SilentlyContinue
                $n++
            }
        }
    Write-Output "Unblocked $n file(s) under $root."
    Write-Output 'Windows marks anything arriving by browser, email or zip as untrusted.'
    exit 0
}

# ---- headless: prove the remote path, start to finish -------------------
# Point it at another PC, or at this one's own name to loop back through WinRM
# and check the machinery before you involve anybody else.
if ($TestRemote) {
    $loopback = ($TestRemote -eq $env:COMPUTERNAME -or $TestRemote -eq 'localhost')
    Write-Output ''
    Write-Output "MATRISE REMOTE TEST -> $TestRemote$(if ($loopback) { '   (loopback through WinRM)' })"
    Write-Output ('=' * 64)

    $cred = $null
    if (-not $loopback) {
        Write-Output ''
        Write-Output 'Credentials for that machine. Press Cancel to try your current account.'
        try { $cred = Get-Credential -Message "Sign in to $TestRemote" } catch { }
    }

    $t = New-MatriseTarget -Name $TestRemote -Credential $cred -ForceRemote
    $report = Test-MatriseTarget -Target $t
    Write-Output (Format-MatriseTargetReport -Report $report -Target $t)

    if ($t.Status -ne 'ok') {
        Write-Output 'Stopping here - the connection check did not pass. Fix the FAIL above first.'
        exit 1
    }

    Write-Output 'Connection is good. Running one harmless command over it...'
    Write-Output ''

    $probe = [pscustomobject]@{
        Id = 'test.remote'; Group = 'Test'; Section = 'Test'
        Name = 'Remote round trip'; Desc = 'hostname + logged-on user on the far end'
        Shell = 'ps'
        Command = '"ran on : $env:COMPUTERNAME"' + "`r`n" + '"as     : $env:USERNAME"' + "`r`n" +
                  '"os     : " + (Get-CimInstance Win32_OperatingSystem).Caption'
        Impact = 'read'; Admin = $false; Timeout = 90; Prompt = ''; PromptDefault = ''
    }

    $ctx = New-MatriseRunContext
    Start-MatriseRun -Context $ctx -Entry $probe -WorkDir $root -Target $t | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((-not $ctx.State['Done']) -or ($ctx.Queue.Count -gt 0)) {
        while ($ctx.Queue.Count -gt 0) { Write-Output ("   " + $ctx.Queue.Dequeue()) }
        if ((Get-Date) -gt $deadline) { Write-Output '   *** timed out ***'; break }
        Start-Sleep -Milliseconds 150
    }
    Close-MatriseRun -Context $ctx

    Write-Output ''
    if ($ctx.State['ExitCode'] -eq 0) {
        Write-Output 'REMOTE PATH WORKS. The machine name above should be the far end, not this one.'
        exit 0
    }
    Write-Output "REMOTE PATH FAILED (exit $($ctx.State['ExitCode'])). See the message above."
    exit 1
}

# ---- headless: the catalog, with what policy says about each -----------
if ($List) {
    Write-Output (Format-MatrisePolicySummary -Policy $policy)
    Write-Output ''
    Get-MatriseCatalog |
        Sort-Object Group, Section, Name |
        Select-Object @{n='Group';e={$_.Group}},
                      @{n='Section';e={$_.Section}},
                      @{n='Impact';e={$_.Impact}},
                      @{n='Admin';e={if ($_.Admin) {'yes'} else {''}}},
                      @{n='Policy';e={(Get-MatrisePolicyDecision -Entry $_ -Policy $policy).Action}},
                      @{n='Name';e={$_.Name}} |
        Format-Table -AutoSize
    exit 0
}

# ---- headless: generate the JEA endpoint -------------------------------
if ($ExportJea) {
    $sg = 'CORP\IT-Support-Endpoint'
    $eg = 'CORP\IT-Support-Endpoint-Elevated'
    if ($policy.PSObject.Properties['jeaSupportGroup']  -and $policy.jeaSupportGroup)  { $sg = $policy.jeaSupportGroup }
    if ($policy.PSObject.Properties['jeaElevatedGroup'] -and $policy.jeaElevatedGroup) { $eg = $policy.jeaElevatedGroup }

    $res = Export-MatriseJea -Catalog (Get-MatriseCatalog) -Policy $policy -OutDir $ExportJea `
                             -SupportGroup $sg -ElevatedGroup $eg
    Write-Output "JEA endpoint written to: $($res.OutDir)"
    Write-Output "  exposed to $sg : $($res.Base)"
    Write-Output "  exposed to $eg : $($res.Elevated)"
    Write-Output "  excluded by policy : $(@($res.Excluded).Count)"
    foreach ($x in $res.Excluded) { Write-Output "     - $($x.Id)" }
    Write-Output ''
    Write-Output 'Read README.txt and MatriseSupport.psrc in that folder before deploying.'
    exit 0
}

# ---- headless: the request queue ---------------------------------------
if ($Requests) {
    $store = Get-MatriseRequestStore -Policy $policy
    if (-not (Test-MatriseStoreReachable $store)) {
        Write-Output (Get-MatriseNoStoreMessage -Policy $policy)
        exit 1
    }
    Write-Output "Request store : $store"
    Write-Output "You can approve : $(Test-MatriseCanApprove -Policy $policy)"
    Write-Output ''
    $all = Get-MatriseRequests -Policy $policy
    if (@($all).Count -eq 0) { Write-Output '(no requests)'; exit 0 }
    $all | Select-Object @{n='Id';e={$_.id}},
                         @{n='Status';e={$_.status}},
                         @{n='By';e={$_.requestedBy}},
                         @{n='Target';e={$_.target}},
                         @{n='Command';e={$_.entryId}},
                         @{n='Raised';e={$_.createdUtc}} |
          Format-Table -AutoSize
    exit 0
}

if ($Approve -or $Deny) {
    $id       = $(if ($Approve) { $Approve } else { $Deny })
    $decision = $(if ($Approve) { 'approved' } else { 'denied' })
    try {
        $req = Set-MatriseRequestDecision -Policy $policy -Id $id -Decision $decision `
                                          -Minutes $Minutes -Comment $Comment
        Write-Output (Format-MatriseRequestThread -Request $req)
        Write-MatriseAudit -WorkDir $root -Policy $policy -Action "request-$decision" `
            -Entry ([pscustomobject]@{ Id = $req.entryId; Name = $req.entryName
                                       Impact = $req.impact; Command = $req.command }) `
            -Target $null -Permission $null -Note "request $id" | Out-Null
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
    exit 0
}

# ---- window -------------------------------------------------------------
try {
    . (Join-Path $root 'lib\Gui.ps1')
    . (Join-Path $root 'lib\GuiRequests.ps1')
    Clear-MatriseConsoleScripts -WorkDir $root
    $t = $(if ($Target) { New-MatriseTarget -Name $Target } else { New-MatriseTarget })
    if ($SelfTest) { Show-MatriseWindow -WorkDir $root -SelfTestMs 1200 -Policy $policy -Target $t }
    else           { Show-MatriseWindow -WorkDir $root -Policy $policy -Target $t }
}
catch {
    $msg = "Matrise failed to start.`r`n`r`n$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)"

    # Print it first, always. A modal dialog in a hidden window waits forever
    # for a click nobody can give, which turns a clear error into a hang.
    Write-Host $msg -ForegroundColor Red
    try {
        $logDir = Join-Path $root 'audit'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Add-Content -Path (Join-Path $logDir 'startup-errors.log') `
            -Value ("=== $((Get-Date).ToString('o')) ===`r`n$msg`r`n") -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }

    if (-not $SelfTest) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'Matrise - startup error',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        } catch { }
    }
    exit 1
}
