# Matrise - JEA generation
#
# Turns the catalog plus the policy file into a Just Enough Administration
# endpoint, so the allow list stops being advisory and becomes something the
# endpoint enforces.
#
# What this buys, concretely:
#
#   * The operator connects to a RestrictedRemoteServer session. The language
#     mode is NoLanguage. They cannot type an arbitrary command, because there
#     is no command line to type it into - only the functions generated here.
#   * Commands run under RunAsVirtualAccount, a temporary local administrator
#     on the endpoint. The operator's own account therefore does not need to be
#     a local admin anywhere. That single change removes the standing privilege
#     that most endpoint-support models leak.
#   * Every session is transcribed to disk by the endpoint itself, not by us.
#
# Two role capability files are produced:
#
#   MatriseSupport          the 'allow' commands - day to day
#   MatriseSupportElevated  allow + requireApproval - the hard nuts
#
# Time-boxed elevation is done the way AD already does it: the elevated role is
# mapped to a group whose membership is temporary (AD PAM shadow groups, or
# Entra PIM). Matrise's own grant file drives what the console offers and keeps
# the paper trail; the group membership is what the endpoint actually honours.
# Do not let anyone tell you the client-side grant is the control.

function ConvertTo-MatriseFunctionName {
    param([string]$Id)
    $parts = $Id -split '[^A-Za-z0-9]+' | Where-Object { $_ }
    $tc = ($parts | ForEach-Object {
        $_.Substring(0, 1).ToUpper() + $(if ($_.Length -gt 1) { $_.Substring(1).ToLower() } else { '' })
    }) -join ''
    "Invoke-Matrise$tc"
}

function New-MatriseJeaFunction {
    param($Entry)

    $fn = ConvertTo-MatriseFunctionName -Id $Entry.Id
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("function $fn {")
    [void]$sb.AppendLine("    <#")
    [void]$sb.AppendLine("      .SYNOPSIS")
    [void]$sb.AppendLine("        $($Entry.Name)")
    [void]$sb.AppendLine("      .DESCRIPTION")
    [void]$sb.AppendLine("        $($Entry.Desc)")
    [void]$sb.AppendLine("        Matrise id : $($Entry.Id)")
    [void]$sb.AppendLine("        Impact     : $($Entry.Impact)")
    [void]$sb.AppendLine("    #>")
    [void]$sb.AppendLine("    [CmdletBinding()]")

    if ($Entry.Prompt) {
        [void]$sb.AppendLine("    param(")
        [void]$sb.AppendLine("        # $($Entry.Prompt)")
        # Anything reaching a shell is constrained at the parameter, not by
        # hoping the caller behaves. A JEA endpoint is exactly where an
        # unvalidated string turns into arbitrary execution.
        [void]$sb.AppendLine("        [Parameter(Mandatory)]")
        [void]$sb.AppendLine("        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._:\\*-]{0,200}$')]")
        [void]$sb.AppendLine("        [string]`$Value")
        [void]$sb.AppendLine("    )")
    } else {
        [void]$sb.AppendLine("    param()")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    `$ErrorActionPreference = 'Continue'")
    [void]$sb.AppendLine("    `$ProgressPreference = 'SilentlyContinue'")
    [void]$sb.AppendLine("")

    if ($Entry.Shell -eq 'cmd') {
        [void]$sb.AppendLine("    `$matriseCmd = @'")
        [void]$sb.AppendLine($Entry.Command)
        [void]$sb.AppendLine("'@")
        if ($Entry.Prompt) {
            [void]$sb.AppendLine("    `$matriseCmd = `$matriseCmd.Replace('%INPUT%', `$Value)")
        }
        [void]$sb.AppendLine("    & `"`$env:SystemRoot\System32\cmd.exe`" /d /c `$matriseCmd 2>&1")
    }
    else {
        $body = $Entry.Command
        if ($Entry.Prompt) {
            # In the catalog the placeholder always sits inside a single-quoted
            # PowerShell string, so swapping the whole quoted token for the
            # parameter keeps it a value and never becomes code.
            $body = $body.Replace("'%INPUT%'", '$Value')
        }
        foreach ($line in ($body -split "`r?`n")) { [void]$sb.AppendLine("    $line") }
    }

    [void]$sb.AppendLine("}")
    [void]$sb.AppendLine("")
    [pscustomobject]@{ Name = $fn; Text = $sb.ToString() }
}

function Export-MatriseJea {
    param(
        [Parameter(Mandatory)] $Catalog,
        $Policy,
        [Parameter(Mandatory)] [string]$OutDir,
        [string]$SupportGroup  = 'CORP\IT-Support-Endpoint',
        [string]$ElevatedGroup = 'CORP\IT-Support-Endpoint-Elevated'
    )

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $moduleDir = Join-Path $OutDir 'Matrise.Endpoint'
    $rcDir     = Join-Path $moduleDir 'RoleCapabilities'
    New-Item -ItemType Directory -Path $rcDir -Force | Out-Null

    $base     = New-Object System.Collections.ArrayList   # allow
    $elevated = New-Object System.Collections.ArrayList   # allow + requireApproval
    $excluded = New-Object System.Collections.ArrayList   # block
    $funcs    = New-Object System.Text.StringBuilder

    [void]$funcs.AppendLine('# Matrise endpoint functions - GENERATED, do not edit by hand.')
    [void]$funcs.AppendLine('# Regenerate with Export-MatriseJea after changing the catalog or policy.')
    [void]$funcs.AppendLine("# Generated from policy: $(if ($Policy) { $Policy.policyName } else { 'none' })")
    [void]$funcs.AppendLine('')

    foreach ($e in $Catalog) {
        $decision = Get-MatrisePolicyDecision -Entry $e -Policy $Policy
        if ($decision.Action -eq 'block') {
            [void]$excluded.Add([pscustomobject]@{ Id = $e.Id; Name = $e.Name; Reason = $decision.Reason })
            continue
        }
        $f = New-MatriseJeaFunction -Entry $e
        [void]$funcs.Append($f.Text)
        [void]$elevated.Add($f.Name)
        if ($decision.Action -eq 'allow') { [void]$base.Add($f.Name) }
    }

    $psm1 = Join-Path $moduleDir 'Matrise.Endpoint.psm1'
    [System.IO.File]::WriteAllText($psm1, $funcs.ToString(), (New-Object System.Text.UTF8Encoding($false)))

    $allNames = @($elevated) | ForEach-Object { "'$_'" }
    $psd1Text = @(
        '@{',
        "    RootModule        = 'Matrise.Endpoint.psm1'",
        "    ModuleVersion     = '1.0.0'",
        "    GUID              = '$([guid]::NewGuid())'",
        "    Author            = 'Matrise'",
        "    Description       = 'Matrise endpoint functions exposed through JEA. Generated.'",
        "    PowerShellVersion = '5.1'",
        "    FunctionsToExport = @($($allNames -join ', '))",
        "    CmdletsToExport   = @()",
        "    VariablesToExport = @()",
        "    AliasesToExport   = @()",
        '}'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $moduleDir 'Matrise.Endpoint.psd1'), $psd1Text,
        (New-Object System.Text.UTF8Encoding($false)))

    function Write-Rc {
        param([string]$Path, $Names, [string]$Desc)
        $q = @($Names) | ForEach-Object { "'$_'" }
        $txt = @(
            '@{',
            "    GUID             = '$([guid]::NewGuid())'",
            "    Author           = 'Matrise'",
            "    Description      = '$Desc'",
            "    ModulesToImport  = 'Matrise.Endpoint'",
            '',
            '    # Only these are callable. There is no shell, no Invoke-Expression,',
            '    # and no way to reach anything not named here.',
            "    VisibleFunctions = @($($q -join ",`r`n                          "))",
            '    VisibleCmdlets   = @()',
            '    VisibleAliases   = @()',
            '}'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($Path, $txt, (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-Rc -Path (Join-Path $rcDir 'MatriseSupport.psrc')         -Names $base `
             -Desc 'Matrise - day to day endpoint support commands'
    Write-Rc -Path (Join-Path $rcDir 'MatriseSupportElevated.psrc') -Names $elevated `
             -Desc 'Matrise - includes commands that require Security approval'

    $pssc = @(
        '@{',
        "    SchemaVersion       = '2.0.0.0'",
        "    GUID                = '$([guid]::NewGuid())'",
        "    Author              = 'Matrise'",
        "    Description         = 'Matrise constrained endpoint for IT support'",
        '',
        '    # No arbitrary language. The operator can call the generated',
        '    # functions and nothing else.',
        "    SessionType         = 'RestrictedRemoteServer'",
        "    LanguageMode        = 'NoLanguage'",
        '',
        '    # Commands run as a temporary local admin created per session, so',
        '    # the operator does not need admin rights on the endpoint at all.',
        '    RunAsVirtualAccount = $true',
        '',
        '    # The endpoint records the session itself. Not optional.',
        "    TranscriptDirectory = 'C:\ProgramData\Matrise\Transcripts'",
        '',
        '    RoleDefinitions     = @{',
        "        '$SupportGroup'  = @{ RoleCapabilities = 'MatriseSupport' }",
        "        '$ElevatedGroup' = @{ RoleCapabilities = 'MatriseSupportElevated' }",
        '    }',
        '}'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'MatriseSupport.pssc'), $pssc,
        (New-Object System.Text.UTF8Encoding($false)))

    $install = @(
        '# Matrise - endpoint install. Deploy through Software Center / Intune as a',
        '# PowerShell script. Runs as SYSTEM, needs no interactive logon.',
        '#',
        '# If the estate enforces AllSigned (it should), sign Matrise.Endpoint.psm1,',
        '# the .psd1 and both .psrc files with your internal code-signing cert',
        '# BEFORE packaging. Unsigned files will simply refuse to load and the',
        '# endpoint will look broken for reasons nothing reports clearly.',
        '',
        '$ErrorActionPreference = ''Stop''',
        '$src = Split-Path -Parent $MyInvocation.MyCommand.Path',
        '$dest = "$env:ProgramFiles\WindowsPowerShell\Modules\Matrise.Endpoint"',
        '',
        'New-Item -ItemType Directory -Path $dest -Force | Out-Null',
        'Copy-Item "$src\Matrise.Endpoint\*" $dest -Recurse -Force',
        '',
        'if (-not (Get-PSSessionConfiguration -Name Matrise -ErrorAction SilentlyContinue)) {',
        '    Register-PSSessionConfiguration -Name Matrise -Path "$src\MatriseSupport.pssc" -Force',
        '} else {',
        '    Set-PSSessionConfiguration -Name Matrise -Path "$src\MatriseSupport.pssc" -Force',
        '}',
        '',
        'Restart-Service WinRM',
        'Write-Output "Matrise JEA endpoint registered. Connect with:"',
        'Write-Output "  Enter-PSSession -ComputerName <host> -ConfigurationName Matrise"'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'Install-MatriseJea.ps1'), $install,
        (New-Object System.Text.UTF8Encoding($false)))

    $readme = @(
        'MATRISE JEA ENDPOINT - GENERATED',
        '================================',
        '',
        "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Policy    : $(if ($Policy) { $Policy.policyName } else { 'none (everything allowed)' })",
        "Catalog   : $(@($Catalog).Count) commands",
        '',
        "  exposed to $SupportGroup       : $(@($base).Count)",
        "  exposed to $ElevatedGroup : $(@($elevated).Count)",
        "  excluded entirely (policy block)         : $(@($excluded).Count)",
        '',
        'EXCLUDED COMMANDS (not present on the endpoint at all)',
        '-----------------------------------------------------'
    )
    if (@($excluded).Count -eq 0) {
        $readme += '  (none)'
    } else {
        foreach ($x in $excluded) { $readme += ("  {0,-22} {1}" -f $x.Id, $x.Reason) }
    }
    $readme += @(
        '',
        'REVIEW THIS BEFORE DEPLOYING',
        '----------------------------',
        'MatriseSupport.psrc is the list your endpoints will accept. Read it. It is',
        'meant to be reviewed by a human on the Security side, which is why it is',
        'generated as plain readable PowerShell data rather than something opaque.',
        '',
        'The elevated role should be mapped to a group with time-boxed membership',
        '(AD PAM shadow group, or Entra PIM) rather than standing membership. That,',
        'not the client, is what makes an approval expire.'
    )
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'README.txt'), ($readme -join "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))

    [pscustomobject]@{
        OutDir   = $OutDir
        Base     = @($base).Count
        Elevated = @($elevated).Count
        Excluded = @($excluded)
    }
}
