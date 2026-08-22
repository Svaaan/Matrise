# Matrise - Screen viewing.
#
# Matrise does NOT stream the screen itself. Capture code (CopyFromScreen ->
# JPEG -> Base64) is byte-for-byte a RAT and Windows Defender blocks it via AMSI
# before it runs; building it in would force an antivirus exclusion, the very
# thing this tool's analyzer flags. Instead we hand off to Quick Assist:
# Microsoft-signed, built into Windows 11, with its own consent handshake, doing
# real-time sharing and control properly. Matrise just launches it and, over the
# connection it already has, tells the far PC what to do.

function Test-MatriseQuickAssist {
    $appx = Get-AppxPackage -Name 'MicrosoftCorporationII.QuickAssist' -ErrorAction SilentlyContinue
    $uri  = (Test-Path 'Registry::HKEY_CLASSES_ROOT\ms-quick-assist')
    $exe  = Test-Path "$env:SystemRoot\System32\quickassist.exe"
    [pscustomobject]@{
        Present = [bool]($appx -or $uri -or $exe)
        Version = $(if ($appx) { [string]$appx.Version } else { '' })
        ViaUri  = [bool]$uri
        ViaExe  = [bool]$exe
    }
}

function Start-MatriseQuickAssist {
    $qa = Test-MatriseQuickAssist
    if (-not $qa.Present) {
        throw ("Quick Assist is not installed on this PC. Get it free from the Microsoft " +
               "Store (search 'Quick Assist'), or open Start and type 'Quick Assist'.")
    }
    # The URI is the modern, reliable entry point; the exe is the old fallback.
    if ($qa.ViaUri) {
        Start-Process 'ms-quick-assist:' -ErrorAction Stop
    }
    elseif ($qa.ViaExe) {
        Start-Process "$env:SystemRoot\System32\quickassist.exe" -ErrorAction Stop
    }
    else {
        Start-Process 'explorer.exe' 'shell:AppsFolder\MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe!App' -ErrorAction Stop
    }
    'launched'
}

# The lines shown on the board when screen sharing is started, kept here so the
# window code stays about wiring rather than wording.
function Get-MatriseScreenShareBrief {
    param([string]$TargetName)
    $them = $(if ($TargetName) { $TargetName } else { 'the other PC' })
    @(
        '================================================================',
        '  SCREEN SHARING - via Windows Quick Assist',
        '================================================================',
        '',
        'Matrise does not stream the screen itself - doing that would make it',
        "look identical to spyware, and antivirus would block it. Instead it",
        'opens Quick Assist, which is built into Windows and does this properly.',
        '',
        'ON THIS PC (you, the helper):',
        '  1. Quick Assist has opened. Sign in with your Microsoft account if',
        '     it asks - this is Microsoft''s app, not Matrise.',
        '  2. Choose "Help someone" and copy the security code it shows.',
        '',
        "ON $($them.ToUpper()):",
        '  3. They open Quick Assist (Start, type Quick Assist) and enter your',
        '     code, then choose to share their screen.',
        $(if ($TargetName) {
            '     Matrise has put a message on their screen telling them this.'
          } else { '' }),
        '',
        'From then on you see their screen live, and can take control if they',
        'allow it. Close Quick Assist when you are done.',
        ''
    ) -join "`r`n"
}

# What to pop on the far PC's screen, over the connection Matrise already has,
# so the person there knows to open Quick Assist and what to expect.
function Get-MatriseScreenShareAlert {
    @(
        "$env:USERNAME wants to see your screen to help you.",
        '',
        'Open Quick Assist:  press Start, type  Quick Assist , open it.',
        'Enter the code they read out to you, then choose Share screen.',
        '',
        'You can stop sharing at any time by closing Quick Assist.',
        'Nothing is shared until you enter their code and agree.'
    ) -join "`r`n"
}
