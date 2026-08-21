# Matrise - Agent bridge
#
# Hands the board over to Claude for a second opinion.
#
# Two routes, in order of preference:
#   1. The Claude Code CLI, if it is installed. Fully automatic, answer comes
#      straight back into the board.
#   2. Clipboard hand-off. Matrise builds the whole prompt, splits it into
#      paste-sized chunks, and you paste it into claude.ai yourself.
#
# The local rule engine in Analyzer.ps1 always runs first either way, so you
# get findings with no network call at all.

function Find-MatriseAgentCli {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    $candidates = @(
        "$env:APPDATA\npm\claude.cmd",
        "$env:APPDATA\npm\claude.ps1",
        "$env:LOCALAPPDATA\Programs\claude\claude.exe",
        "$env:USERPROFILE\.local\bin\claude.exe",
        "$env:USERPROFILE\.claude\local\claude.exe",
        "$env:ProgramFiles\Claude\claude.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $null
}

# Windows console output is full of column padding. Squeezing runs of spaces
# and dropping blank runs cuts the payload roughly in half with no loss of
# meaning, which matters when you are pasting by hand.
function Compress-MatriseText {
    param([string]$Text)
    $t = $Text -replace '[ \t]{3,}', '  '
    $t = $t -replace '(\r?\n){3,}', "`r`n`r`n"
    $t.Trim()
}

function New-MatriseAgentPrompt {
    param(
        [string]$Text,
        $Findings,
        [string]$Context = '',
        [int]$MaxDataChars = 120000
    )

    $data = Compress-MatriseText -Text $Text
    $truncated = $false
    if ($data.Length -gt $MaxDataChars) {
        $data = $data.Substring(0, $MaxDataChars)
        $truncated = $true
    }

    $local = 'The local rule engine found nothing.'
    if ($Findings -and @($Findings).Count -gt 0) {
        $local = (@($Findings) | ForEach-Object {
            "- [$($_.Severity)] line $($_.Line): $($_.Title)  --  $($_.Evidence)"
        }) -join "`r`n"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('You are a Windows security and systems analyst. Below is diagnostic output')
    [void]$sb.AppendLine('collected from a Windows machine by a tool called Matrise. Review it and tell')
    [void]$sb.AppendLine('the owner what, if anything, is wrong.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('What I need from you:')
    [void]$sb.AppendLine('1. VERDICT - one short paragraph: is this machine healthy, suspicious, or compromised?')
    [void]$sb.AppendLine('2. FINDINGS - ranked most serious first. For each one give:')
    [void]$sb.AppendLine('     - what you saw (quote the exact line)')
    [void]$sb.AppendLine('     - why it matters')
    [void]$sb.AppendLine('     - how confident you are, and what would confirm or rule it out')
    [void]$sb.AppendLine('3. FALSE ALARMS - anything below that looks alarming but is actually normal,')
    [void]$sb.AppendLine('   and why. Be specific; this section is as useful as the findings.')
    [void]$sb.AppendLine('4. NEXT COMMANDS - the exact Windows commands to run next to narrow it down.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Rules: do not invent detail that is not in the data. If the output is')
    [void]$sb.AppendLine('truncated or a section is missing, say so rather than guessing. Prefer the')
    [void]$sb.AppendLine('boring explanation over the exciting one, but do not soften a real problem.')
    [void]$sb.AppendLine('')
    if ($Context) {
        [void]$sb.AppendLine('OWNER NOTES / SYMPTOMS:')
        [void]$sb.AppendLine($Context)
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('WHAT THE LOCAL RULE ENGINE ALREADY FLAGGED (treat as hints, not conclusions;')
    [void]$sb.AppendLine('it is a regex matcher and it does get things wrong):')
    [void]$sb.AppendLine($local)
    [void]$sb.AppendLine('')
    if ($truncated) {
        [void]$sb.AppendLine("NOTE: the raw output below was truncated at $MaxDataChars characters.")
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('----- RAW OUTPUT BEGINS -----')
    [void]$sb.AppendLine($data)
    [void]$sb.AppendLine('----- RAW OUTPUT ENDS -----')
    $sb.ToString()
}

# Collection getters return a plain enumerated array, never ", $out".
# The comma form survives assignment but makes the ordinary idiom
#     @(Get-Something).Count
# report 1 no matter what, because the pipeline sees a single object that
# happens to be an array. Both idioms have to work.
#
# Splits a long prompt into paste-sized pieces, each labelled so the model
# knows to wait for the rest before answering.
function Split-MatriseForClipboard {
    param([string]$Text, [int]$MaxChars = 45000)

    if ($Text.Length -le $MaxChars) { return @(, $Text) }

    $chunks = New-Object System.Collections.ArrayList
    $lines  = $Text -split "`r?`n"
    $cur    = New-Object System.Text.StringBuilder

    foreach ($l in $lines) {
        if ($cur.Length + $l.Length + 2 -gt $MaxChars -and $cur.Length -gt 0) {
            [void]$chunks.Add($cur.ToString())
            $cur = New-Object System.Text.StringBuilder
        }
        [void]$cur.AppendLine($l)
    }
    if ($cur.Length -gt 0) { [void]$chunks.Add($cur.ToString()) }

    $total = $chunks.Count
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $total; $i++) {
        $n = $i + 1
        if ($n -lt $total) {
            $header = "[Matrise data - part $n of $total. Do not answer yet, reply only 'received' and wait for the remaining parts.]`r`n`r`n"
        } else {
            $header = "[Matrise data - part $n of $total. This is the last part. Now give me the full analysis.]`r`n`r`n"
        }
        [void]$out.Add($header + $chunks[$i])
    }
    $out.ToArray()
}

# Builds a catalog-shaped entry so an agent run streams through the same
# runner, progress bar and Stop button as everything else.
function New-MatriseAgentEntry {
    param([string]$CliPath, [string]$PromptFile)

    $cmd = "type `"$PromptFile`" | `"$CliPath`" -p --output-format text"

    [pscustomobject]@{
        Id            = 'agent.analyze'
        Group         = 'Agent'
        Section       = 'Analyze'
        Name          = 'Claude analysis of the board'
        Desc          = 'Sends the board contents to the Claude Code CLI and streams the answer back.'
        Shell         = 'cmd'
        Command       = $cmd
        Impact        = 'read'
        Admin         = $false
        Timeout       = 600
        Prompt        = ''
        PromptDefault = ''
    }
}

function Save-MatriseAgentPrompt {
    param([string]$Prompt, [string]$WorkDir)
    $dir = Join-Path $WorkDir 'reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("agent-prompt-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($file, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
    $file
}
