# Matrise - security and system helper for Windows
#
#   .\Matrise.ps1                        open the window
#   .\Matrise.ps1 -Target WS-4471        open the window aimed at another machine
#
#   .\Matrise.ps1 -Analyze <file>        run the rule engine over a file, print, exit
#   .\Matrise.ps1 -List                  print the catalog with each policy decision
#   .\Matrise.ps1 -SelfTest              drive the window through a scripted pass
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
    [string]$ExportJea,
    [switch]$Requests,
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
        Write-Error "Request store not reachable: '$store'. Check the policy file and the network."
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
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Matrise - startup error',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch {
        Write-Host $msg -ForegroundColor Red
    }
    exit 1
}
