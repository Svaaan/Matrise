# Matrise - security and system helper for Windows
#
#   .\Matrise.ps1                      open the window
#   .\Matrise.ps1 -Analyze <file>      run the rule engine over a file, print, exit
#   .\Matrise.ps1 -List                print the command catalog, exit
#
# Normally you launch this through Matrise.bat, which elevates first.

[CmdletBinding()]
param(
    [string]$Analyze,
    [switch]$List,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:MATRISE_HOME = $root

. (Join-Path $root 'lib\Explain.ps1')
. (Join-Path $root 'lib\Catalog.ps1')
. (Join-Path $root 'lib\Runner.ps1')
. (Join-Path $root 'lib\Analyzer.ps1')
. (Join-Path $root 'lib\Agent.ps1')

# ---- headless: analyze a file ------------------------------------------
if ($Analyze) {
    if (-not (Test-Path $Analyze)) { Write-Error "No such file: $Analyze"; exit 1 }
    $text = [System.IO.File]::ReadAllText((Resolve-Path $Analyze))
    $findings = Invoke-MatriseAnalysis -Text $text
    Write-Output (Format-MatriseFindings -Findings $findings)
    exit $(if (@($findings | Where-Object { $_.Severity -in 'Critical', 'High' }).Count -gt 0) { 2 } else { 0 })
}

# ---- headless: list the catalog ----------------------------------------
if ($List) {
    Get-MatriseCatalog |
        Sort-Object Group, Section, Name |
        Format-Table @{n='Group';e={$_.Group}},
                     @{n='Section';e={$_.Section}},
                     @{n='Impact';e={$_.Impact}},
                     @{n='Admin';e={if ($_.Admin) {'yes'} else {''}}},
                     @{n='Name';e={$_.Name}} -AutoSize
    exit 0
}

# ---- window -------------------------------------------------------------
try {
    . (Join-Path $root 'lib\Gui.ps1')
    Clear-MatriseConsoleScripts -WorkDir $root
    if ($SelfTest) { Show-MatriseWindow -WorkDir $root -SelfTestMs 1200 }
    else           { Show-MatriseWindow -WorkDir $root }
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
