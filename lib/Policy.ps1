# Matrise - Policy, grants and audit.
#
# This is GOVERNANCE, not a security boundary. Matrise is PowerShell: anyone who
# can run it can edit the policy or skip Matrise entirely. A client-side block
# list stops an honest operator from a mistake and produces an audit trail; it
# does not stop a determined one, and must never be sold to Security as if it
# did. The real boundary is the endpoint - see Jea.ps1, generated from this same
# file so the list shown and the list enforced cannot drift apart.

$script:MatrisePolicy = $null

function Get-MatrisePolicyPath {
    param([string]$WorkDir)
    if ($env:MATRISE_POLICY) { return $env:MATRISE_POLICY }
    Join-Path $WorkDir 'policy.json'
}

function New-MatriseDefaultPolicy {
    [pscustomobject]@{
        version       = 1
        policyName    = 'unmanaged (no policy file found)'
        contact       = ''
        defaultAction = 'allow'
        rules         = @()
        requestStore  = ''
        grantStore    = ''
        auditLog      = ''
        Source        = '(none)'
        IsManaged     = $false
    }
}

function Import-MatrisePolicy {
    param([string]$WorkDir)

    $path = Get-MatrisePolicyPath -WorkDir $WorkDir
    if (-not $path -or -not (Test-Path $path)) {
        $script:MatrisePolicy = New-MatriseDefaultPolicy
        return $script:MatrisePolicy
    }

    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        # A broken policy file must not silently become "allow everything".
        $p = New-MatriseDefaultPolicy
        $p.policyName    = "UNREADABLE POLICY at $path"
        $p.defaultAction = 'block'
        $p.Source        = $path
        $p.IsManaged     = $true
        $script:MatrisePolicy = $p
        return $p
    }

    $p = [pscustomobject]@{
        version       = $raw.version
        policyName    = $(if ($raw.policyName) { $raw.policyName } else { 'unnamed policy' })
        contact       = $raw.contact
        defaultAction = $(if ($raw.defaultAction) { $raw.defaultAction } else { 'allow' })
        rules         = @($raw.rules)
        requestStore  = $raw.requestStore
        grantStore    = $raw.grantStore
        auditLog      = $raw.auditLog
        Source        = $path
        IsManaged     = $true
    }
    $script:MatrisePolicy = $p
    $p
}

function Get-MatrisePolicy { $script:MatrisePolicy }

# Most specific rule wins: an explicit id beats a pattern, a pattern beats a
# blanket impact rule. Anything not matched falls to defaultAction.
function Get-MatrisePolicyDecision {
    param($Entry, $Policy = $null)

    if (-not $Policy) { $Policy = $script:MatrisePolicy }
    if (-not $Policy) { return [pscustomobject]@{ Action = 'allow'; Reason = 'no policy loaded'; Rule = '' } }

    $best = $null
    $bestRank = 99
    foreach ($r in $Policy.rules) {
        if (-not $r) { continue }
        $rank = 99
        $hit  = $false
        switch ($r.match) {
            'id'      { $hit = ($Entry.Id -eq $r.value);                     $rank = 0 }
            'pattern' { $hit = ($Entry.Command -match $r.value);             $rank = 1 }
            'group'   { $hit = ($Entry.Group -eq $r.value);                  $rank = 2 }
            'section' { $hit = ($Entry.Section -eq $r.value);                $rank = 2 }
            'impact'  { $hit = ($Entry.Impact -eq $r.value);                 $rank = 3 }
            'admin'   { $hit = ([bool]$Entry.Admin -eq [bool]$r.value);      $rank = 3 }
        }
        if ($hit -and $rank -lt $bestRank) { $best = $r; $bestRank = $rank }
    }

    if ($best) {
        return [pscustomobject]@{
            Action = $best.action
            Reason = $(if ($best.reason) { $best.reason } else { "matched $($best.match) = $($best.value)" })
            Rule   = "$($best.match):$($best.value)"
        }
    }
    [pscustomobject]@{ Action = $Policy.defaultAction; Reason = 'no rule matched; policy default'; Rule = 'default' }
}

# ---------------------------------------------------------------- grants ---
# A grant is a time-boxed permission to run one blocked command, written by
# whoever approves the request. Matrise honours it; JEA is what enforces it.

function Get-MatriseGrantStore {
    param($Policy)
    if ($Policy -and $Policy.grantStore) { return $Policy.grantStore }
    ''
}

function Get-MatriseActiveGrants {
    param($Policy, [string]$User = '')

    $store = Get-MatriseGrantStore -Policy $Policy
    if (-not $store -or -not (Test-Path $store)) { return @() }
    if (-not $User) { $User = "$env:USERDOMAIN\$env:USERNAME" }

    $now = Get-Date
    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem $store -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { $g = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($g.status -ne 'approved') { continue }
        if ($g.grantedTo -and $g.grantedTo -ne $User) { continue }
        $exp = $null
        try { $exp = [datetime]$g.expiresUtc } catch { continue }
        if ($exp.ToUniversalTime() -lt $now.ToUniversalTime()) { continue }
        [void]$out.Add($g)
    }
    $out.ToArray()
}

function Test-MatriseGrant {
    param([string]$EntryId, $Policy, [string]$User = '', [string]$TargetName = '')
    foreach ($g in (Get-MatriseActiveGrants -Policy $Policy -User $User)) {
        if ($g.entryId -ne $EntryId) { continue }
        if ($g.target -and $TargetName -and $g.target -ne '*' -and $g.target -ne $TargetName) { continue }
        return $g
    }
    $null
}

# The single question the UI asks before it lets anything run.
function Resolve-MatriseRunPermission {
    param($Entry, $Policy = $null, [string]$TargetName = '', [string]$User = '')

    if (-not $Policy) { $Policy = $script:MatrisePolicy }
    $decision = Get-MatrisePolicyDecision -Entry $Entry -Policy $Policy

    if ($decision.Action -eq 'allow') {
        return [pscustomobject]@{
            Allowed = $true; Action = 'allow'; Reason = $decision.Reason
            Rule = $decision.Rule; Grant = $null
        }
    }

    $grant = Test-MatriseGrant -EntryId $Entry.Id -Policy $Policy -User $User -TargetName $TargetName
    if ($grant) {
        return [pscustomobject]@{
            Allowed = $true; Action = 'granted'
            Reason  = "temporary approval by $($grant.approvedBy), expires $($grant.expiresUtc) UTC"
            Rule    = $decision.Rule; Grant = $grant
        }
    }

    [pscustomobject]@{
        Allowed = $false
        Action  = $decision.Action           # 'block' or 'requireApproval'
        Reason  = $decision.Reason
        Rule    = $decision.Rule
        Grant   = $null
    }
}

# ----------------------------------------------------------------- audit ---
# Written before execution, not after, so an attempt that hangs or crashes is
# still on the record. Local always; the shared copy is best-effort.

function Write-MatriseAudit {
    param(
        [string]$WorkDir,
        $Policy,
        [string]$Action,
        $Entry,
        $Target,
        $Permission,
        [string]$Note = ''
    )

    $rec = [pscustomobject]@{
        timeUtc    = (Get-Date).ToUniversalTime().ToString('o')
        operator   = "$env:USERDOMAIN\$env:USERNAME"
        console    = $env:COMPUTERNAME
        action     = $Action
        entryId    = $(if ($Entry) { $Entry.Id } else { '' })
        entryName  = $(if ($Entry) { $Entry.Name } else { '' })
        impact     = $(if ($Entry) { $Entry.Impact } else { '' })
        command    = $(if ($Entry) { $Entry.Command } else { '' })
        target     = $(if ($Target) { $Target.Name } else { 'localhost' })
        targetMode = $(if ($Target) { $Target.Mode } else { 'local' })
        policy     = $(if ($Policy) { $Policy.policyName } else { '' })
        decision   = $(if ($Permission) { $Permission.Action } else { '' })
        rule       = $(if ($Permission) { $Permission.Rule } else { '' })
        note       = $Note
    }

    $line = ($rec | ConvertTo-Json -Compress)

    try {
        $dir = Join-Path $WorkDir 'audit'
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
        $local = Join-Path $dir ("matrise-audit-{0}.jsonl" -f (Get-Date -Format 'yyyyMM'))
        Add-Content -Path $local -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }

    if ($Policy -and $Policy.auditLog) {
        try {
            $shared = Join-Path $Policy.auditLog ("{0}-{1}.jsonl" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMM'))
            Add-Content -Path $shared -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
    $rec
}

function Format-MatrisePolicySummary {
    param($Policy)
    if (-not $Policy) { return 'No policy loaded.' }
    if (-not $Policy.IsManaged) {
        return @(
            'UNMANAGED - no policy file found.',
            '',
            'Every command is available. That is correct for a standalone technician',
            'machine. In a managed environment, point MATRISE_POLICY at the policy',
            'file your Security team publishes, or drop policy.json next to the app.'
        ) -join "`r`n"
    }
    @(
        "Policy   : $($Policy.policyName)",
        "Source   : $($Policy.Source)",
        "Default  : $($Policy.defaultAction)",
        "Rules    : $(@($Policy.rules).Count)",
        "Contact  : $($Policy.contact)"
    ) -join "`r`n"
}
