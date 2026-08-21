# Matrise - Access requests, approvals and the conversation attached to them
#
# When policy blocks a command and the operator genuinely needs it, they raise
# a request. Security approves it for a bounded window, or declines, and the
# two of them talk it through on the request itself.
#
# ---------------------------------------------------------------------------
# WHY A FILE SHARE AND NOT A SERVICE
#
# Two directories on an SMB share, with different ACLs:
#
#   \\share\matrise\requests\   IT Support: create + append comments
#                              Security   : full control
#   \\share\matrise\grants\     IT Support: READ ONLY
#                              Security   : full control
#
# The ACL on the grants folder is the actual control. An operator cannot write
# a grant for themselves because the file system will not let them - not
# because this script declines to. That is a real boundary, enforced by
# Windows, auditable through file system auditing, and it needs no server, no
# listening port and no application-control exception.
#
# WHY NOT PEER-TO-PEER CHAT
#
# It was asked for, and I would advise against it. A direct socket between two
# workstations means a listener on an endpoint, a firewall exception, a new
# authentication scheme to get wrong, and a conversation nobody can audit -
# for a capability Teams already provides. What is genuinely missing is not
# chat; it is chat ATTACHED TO THE REQUEST, so the reasoning lives next to the
# decision forever. That is what the comment thread below is. It costs one
# JSON file and inherits the share's ACLs and auditing.
# ---------------------------------------------------------------------------

function Get-MatriseRequestStore {
    param($Policy)
    if ($Policy -and $Policy.requestStore) { return $Policy.requestStore }
    ''
}

function Test-MatriseStoreReachable {
    param([string]$Path)
    if (-not $Path) { return $false }
    try { return (Test-Path $Path -ErrorAction Stop) } catch { return $false }
}

# Truthful answer to "can I approve", by asking the file system rather than
# trusting a group name. Writing is the privilege that matters.
function Test-MatriseCanApprove {
    param($Policy)
    $store = $Policy.grantStore
    if (-not (Test-MatriseStoreReachable $store)) { return $false }
    $probe = Join-Path $store (".matrise-write-probe-{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -Path $probe -Value 'probe' -ErrorAction Stop
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function New-MatriseRequestId {
    "REQ-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
}

function New-MatriseRequest {
    param(
        $Policy,
        $Entry,
        [string]$TargetName,
        [string]$Justification,
        [int]$RequestedMinutes = 60,
        $Permission = $null
    )

    $store = Get-MatriseRequestStore -Policy $Policy
    if (-not (Test-MatriseStoreReachable $store)) {
        throw "The request store is not reachable: '$store'. Check the policy file and that you are on the corporate network."
    }

    $id = New-MatriseRequestId
    $req = [pscustomobject]@{
        id               = $id
        createdUtc       = (Get-Date).ToUniversalTime().ToString('o')
        requestedBy      = "$env:USERDOMAIN\$env:USERNAME"
        console          = $env:COMPUTERNAME
        entryId          = $Entry.Id
        entryName        = $Entry.Name
        impact           = $Entry.Impact
        command          = $Entry.Command
        target           = $(if ($TargetName) { $TargetName } else { 'localhost' })
        justification    = $Justification
        requestedMinutes = $RequestedMinutes
        policyRule       = $(if ($Permission) { $Permission.Rule } else { '' })
        policyReason     = $(if ($Permission) { $Permission.Reason } else { '' })
        status           = 'pending'
        decidedBy        = ''
        decidedUtc       = ''
        expiresUtc       = ''
        comments         = @()
    }

    $path = Join-Path $store "$id.json"
    $req | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8 -ErrorAction Stop
    $req
}

function Get-MatriseRequests {
    param($Policy, [string]$Status = '', [string]$User = '', [int]$Newest = 200)

    $store = Get-MatriseRequestStore -Policy $Policy
    if (-not (Test-MatriseStoreReachable $store)) { return @() }

    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem $store -Filter 'REQ-*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First $Newest)) {
        try { $r = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($Status -and $r.status -ne $Status) { continue }
        if ($User   -and $r.requestedBy -ne $User) { continue }
        [void]$out.Add($r)
    }
    , $out
}

function Get-MatriseRequest {
    param($Policy, [string]$Id)
    $store = Get-MatriseRequestStore -Policy $Policy
    $p = Join-Path $store "$Id.json"
    if (-not (Test-Path $p)) { return $null }
    try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null }
}

function Save-MatriseRequest {
    param($Policy, $Request)
    $store = Get-MatriseRequestStore -Policy $Policy
    $p = Join-Path $store "$($Request.id).json"
    $Request | ConvertTo-Json -Depth 6 | Set-Content -Path $p -Encoding UTF8 -ErrorAction Stop
    $Request
}

# The conversation. Re-read before appending so two people typing at once do
# not overwrite each other's messages.
function Add-MatriseRequestComment {
    param($Policy, [string]$Id, [string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $req = Get-MatriseRequest -Policy $Policy -Id $Id
    if (-not $req) { throw "Request $Id not found." }

    $comment = [pscustomobject]@{
        utc  = (Get-Date).ToUniversalTime().ToString('o')
        who  = "$env:USERDOMAIN\$env:USERNAME"
        text = $Text
    }
    $req.comments = @($req.comments) + $comment
    Save-MatriseRequest -Policy $Policy -Request $req
}

# Approving writes TWO files: the decision on the request, and a separate grant
# in the grants folder. They are separate so the ACLs can be, which is the
# whole point - support can read grants but never write one.
function Set-MatriseRequestDecision {
    param(
        $Policy,
        [string]$Id,
        [ValidateSet('approved', 'denied')] [string]$Decision,
        [int]$Minutes = 0,
        [string]$Comment = ''
    )

    $req = Get-MatriseRequest -Policy $Policy -Id $Id
    if (-not $req) { throw "Request $Id not found." }
    if ($req.status -ne 'pending') { throw "Request $Id was already $($req.status)." }

    if ($Minutes -le 0) { $Minutes = [int]$req.requestedMinutes }
    if ($Minutes -le 0) { $Minutes = 60 }

    $now = (Get-Date).ToUniversalTime()
    $req.status    = $Decision
    $req.decidedBy = "$env:USERDOMAIN\$env:USERNAME"
    $req.decidedUtc = $now.ToString('o')
    if ($Decision -eq 'approved') { $req.expiresUtc = $now.AddMinutes($Minutes).ToString('o') }
    if ($Comment) {
        $req.comments = @($req.comments) + [pscustomobject]@{
            utc = $now.ToString('o'); who = $req.decidedBy; text = $Comment
        }
    }
    Save-MatriseRequest -Policy $Policy -Request $req | Out-Null

    if ($Decision -eq 'approved') {
        if (-not (Test-MatriseStoreReachable $Policy.grantStore)) {
            throw "Decision saved, but the grant store '$($Policy.grantStore)' is not reachable, so no grant was issued."
        }
        $grant = [pscustomobject]@{
            grantId     = $req.id
            entryId     = $req.entryId
            entryName   = $req.entryName
            grantedTo   = $req.requestedBy
            target      = $req.target
            approvedBy  = $req.decidedBy
            approvedUtc = $req.decidedUtc
            expiresUtc  = $req.expiresUtc
            status      = 'approved'
            policy      = $Policy.policyName
        }
        $gp = Join-Path $Policy.grantStore "$($req.id).json"
        $grant | ConvertTo-Json -Depth 5 | Set-Content -Path $gp -Encoding UTF8 -ErrorAction Stop
    }
    $req
}

function Format-MatriseRequestThread {
    param($Request)
    if (-not $Request) { return '' }

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("REQUEST $($Request.id)   [$($Request.status.ToUpper())]")
    [void]$lines.Add('')
    [void]$lines.Add("  command    : $($Request.entryName)  ($($Request.entryId))")
    [void]$lines.Add("  target     : $($Request.target)")
    [void]$lines.Add("  raised by  : $($Request.requestedBy) on $($Request.console)")
    [void]$lines.Add("  raised at  : $($Request.createdUtc) UTC")
    [void]$lines.Add("  blocked by : $($Request.policyRule) - $($Request.policyReason)")
    [void]$lines.Add("  asked for  : $($Request.requestedMinutes) minutes")
    [void]$lines.Add('')
    [void]$lines.Add('  JUSTIFICATION')
    foreach ($l in ($Request.justification -split "`r?`n")) { [void]$lines.Add("    $l") }
    if ($Request.status -ne 'pending') {
        [void]$lines.Add('')
        [void]$lines.Add("  DECISION: $($Request.status) by $($Request.decidedBy) at $($Request.decidedUtc) UTC")
        if ($Request.expiresUtc) { [void]$lines.Add("  expires : $($Request.expiresUtc) UTC") }
    }
    [void]$lines.Add('')
    [void]$lines.Add('  CONVERSATION')
    if (-not @($Request.comments).Count) {
        [void]$lines.Add('    (nothing yet)')
    } else {
        foreach ($c in @($Request.comments)) {
            [void]$lines.Add("    [$($c.utc)] $($c.who):")
            foreach ($l in ($c.text -split "`r?`n")) { [void]$lines.Add("        $l") }
        }
    }
    $lines -join "`r`n"
}
