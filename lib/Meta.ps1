# Matrise - File inspector.
#
# Drop or pick a local file and pull everything the file quietly carries: where
# it came from (mark of the web), whether it is signed, its fingerprints, hidden
# data streams, and type-specific metadata (photo EXIF + GPS, Office document
# properties and macros, program version info). Nothing leaves the machine - it
# is all read locally with built-in .NET, no dependencies, no upload.
#
# The report is written to the board so it is searchable, and it carries a few
# plain marker phrases (DOWNLOADED FROM THE INTERNET, CONTAINS MACROS, UNSIGNED
# PROGRAM, GPS LOCATION, HIDDEN STREAM, SIGNATURE INVALID) that the offline
# analyzer keys on to flag a suspicious file.

# ---------------------------------------------------------------- helpers ---
function Format-MatriseBytes {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes bytes" }
    $u = 'KB','MB','GB','TB'; $n = [double]$Bytes; $i = -1
    do { $n = $n / 1024; $i++ } while ($n -ge 1024 -and $i -lt 3)
    "{0:0.0} {1} ({2:N0} bytes)" -f $n, $u[$i], $Bytes
}

function Get-MatriseFileKind {
    param([string]$Ext)
    switch ($Ext.ToLower()) {
        '.exe' { 'Program (executable)'; break }
        '.dll' { 'Program library (DLL)'; break }
        '.sys' { 'Driver'; break }
        '.scr' { 'Screensaver (executable)'; break }
        '.msi' { 'Windows installer package'; break }
        '.ps1' { 'PowerShell script'; break }
        '.bat' { 'Batch script'; break }
        '.cmd' { 'Batch script'; break }
        '.vbs' { 'VBScript'; break }
        '.js'  { 'JScript'; break }
        '.lnk' { 'Shortcut'; break }
        '.docx'{ 'Word document'; break }
        '.docm'{ 'Word document (macro-enabled)'; break }
        '.xlsx'{ 'Excel workbook'; break }
        '.xlsm'{ 'Excel workbook (macro-enabled)'; break }
        '.pptx'{ 'PowerPoint presentation'; break }
        '.pptm'{ 'PowerPoint presentation (macro-enabled)'; break }
        '.pdf' { 'PDF document'; break }
        '.jpg' { 'JPEG image'; break }
        '.jpeg'{ 'JPEG image'; break }
        '.tif' { 'TIFF image'; break }
        '.tiff'{ 'TIFF image'; break }
        '.png' { 'PNG image'; break }
        '.gif' { 'GIF image'; break }
        '.zip' { 'ZIP archive'; break }
        default { if ($Ext) { "$($Ext.TrimStart('.').ToUpper()) file" } else { 'File (no extension)' } }
    }
}

function Test-MatriseIsPE  { param([string]$Ext) @('.exe','.dll','.sys','.scr','.ocx','.cpl') -contains $Ext.ToLower() }
function Test-MatriseIsOffice { param([string]$Ext) @('.docx','.docm','.xlsx','.xlsm','.pptx','.pptm') -contains $Ext.ToLower() }
function Test-MatriseIsImage  { param([string]$Ext) @('.jpg','.jpeg','.tif','.tiff') -contains $Ext.ToLower() }

# --------------------------------------------------------- mark of the web --
# Windows tags files saved from the internet with a Zone.Identifier alternate
# data stream. It records the zone and often the exact URL and referrer - the
# single most useful thing to know about a suspicious attachment.
function Get-MatriseMotw {
    param([string]$Path)
    $out = [ordered]@{ Present = $false; Zone = ''; ZoneId = ''; HostUrl = ''; Referrer = '' }
    try {
        $z = Get-Content -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction Stop
    } catch { return [pscustomobject]$out }
    $out.Present = $true
    foreach ($line in $z) {
        if ($line -match '^\s*ZoneId\s*=\s*(\d+)') {
            $out.ZoneId = $Matches[1]
            $out.Zone = switch ($Matches[1]) {
                '0' { 'Local machine' } '1' { 'Local intranet' } '2' { 'Trusted site' }
                '3' { 'Internet' } '4' { 'Restricted site' } default { "Zone $($Matches[1])" }
            }
        }
        elseif ($line -match '^\s*HostUrl\s*=\s*(.+)$')     { $out.HostUrl  = $Matches[1].Trim() }
        elseif ($line -match '^\s*ReferrerUrl\s*=\s*(.+)$') { $out.Referrer = $Matches[1].Trim() }
    }
    [pscustomobject]$out
}

# Other alternate data streams (besides the default :$DATA and Zone.Identifier)
# are a classic place to stash data or a second executable out of plain sight.
function Get-MatriseAltStreams {
    param([string]$Path)
    $streams = @()
    try {
        $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop |
            Where-Object { $_.Stream -ne ':$DATA' -and $_.Stream -ne 'Zone.Identifier' })
    } catch { }
    $streams
}

# ------------------------------------------------------------- signature ----
function Get-MatriseSignatureInfo {
    param([string]$Path)
    $out = [ordered]@{ Status = 'Unknown'; Signer = ''; TimeStamp = '' }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $out.Status = [string]$s.Status
        if ($s.SignerCertificate) {
            $subj = $s.SignerCertificate.Subject
            if ($subj -match 'CN=("([^"]+)"|([^,]+))') { $out.Signer = ($Matches[2], $Matches[3] -ne '' | Select-Object -First 1) }
            else { $out.Signer = $subj }
        }
        if ($s.TimeStamperCertificate) { $out.TimeStamp = 'countersigned (trusted timestamp)' }
    } catch { $out.Status = "could not check ($($_.Exception.Message))" }
    [pscustomobject]$out
}

# --------------------------------------------------------------- image EXIF -
function Get-MatriseExif {
    param([string]$Path)
    $out = [ordered]@{ Make=''; Model=''; Software=''; Taken=''; Gps='' }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        # Read via a memory copy so the file is not left locked.
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream (,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms, $false, $false)
        $ids = @{}
        foreach ($p in $img.PropertyItems) { $ids[$p.Id] = $p }
        $asc = { param($p) if ($p) { ([System.Text.Encoding]::ASCII.GetString($p.Value)).Trim([char]0).Trim() } else { '' } }
        $out.Make     = & $asc $ids[0x010F]
        $out.Model    = & $asc $ids[0x0110]
        $out.Software = & $asc $ids[0x0131]
        $dt = & $asc $ids[0x9003]; if (-not $dt) { $dt = & $asc $ids[0x0132] }
        $out.Taken = $dt

        # GPS: latitude (id 2) and longitude (id 4) are each three rationals
        # (degrees, minutes, seconds); refs (id 1/3) give the hemisphere.
        $rat = {
            param($p, $i)
            $o = $i * 8
            $num = [System.BitConverter]::ToUInt32($p.Value, $o)
            $den = [System.BitConverter]::ToUInt32($p.Value, $o + 4)
            if ($den -eq 0) { 0 } else { [double]$num / $den }
        }
        if ($ids.ContainsKey(2) -and $ids.ContainsKey(4)) {
            $latP = $ids[2]; $lonP = $ids[4]
            $lat = (& $rat $latP 0) + (& $rat $latP 1)/60 + (& $rat $latP 2)/3600
            $lon = (& $rat $lonP 0) + (& $rat $lonP 1)/60 + (& $rat $lonP 2)/3600
            $latRef = (& $asc $ids[1]); $lonRef = (& $asc $ids[3])
            if ($latRef -match 'S') { $lat = -$lat }
            if ($lonRef -match 'W') { $lon = -$lon }
            if ($lat -ne 0 -or $lon -ne 0) { $out.Gps = "{0:0.000000}, {1:0.000000}" -f $lat, $lon }
        }
        $img.Dispose(); $ms.Dispose()
    } catch { }
    [pscustomobject]$out
}

# ----------------------------------------------------- Office document props -
# .docx/.xlsx/.pptx are ZIPs; the properties live in docProps/*.xml, and a
# macro project shows up as a vbaProject.bin entry.
function Get-MatriseOfficeProps {
    param([string]$Path)
    $out = [ordered]@{ Author=''; LastSavedBy=''; Application=''; Company=''; Created=''; Modified=''; Revision=''; Title=''; HasMacros=$false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $read = {
                param($name)
                $e = $zip.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
                if (-not $e) { return $null }
                $sr = New-Object System.IO.StreamReader ($e.Open())
                $t = $sr.ReadToEnd(); $sr.Close(); [xml]$t
            }
            $core = & $read 'docProps/core.xml'
            if ($core) {
                $ns = $core.coreProperties
                $out.Author      = [string]$ns.creator
                $out.LastSavedBy = [string]$ns.lastModifiedBy
                $out.Created     = [string]$ns.created.'#text'; if (-not $out.Created) { $out.Created = [string]$ns.created }
                $out.Modified    = [string]$ns.modified.'#text'; if (-not $out.Modified) { $out.Modified = [string]$ns.modified }
                $out.Revision    = [string]$ns.revision
                $out.Title       = [string]$ns.title
            }
            $app = & $read 'docProps/app.xml'
            if ($app) {
                $out.Application = [string]$app.Properties.Application
                $out.Company     = [string]$app.Properties.Company
            }
            $out.HasMacros = [bool]($zip.Entries | Where-Object { $_.FullName -match 'vbaProject\.bin$' })
        } finally { $zip.Dispose() }
    } catch { }
    [pscustomobject]$out
}

# --------------------------------------------------------------------- PDF ---
# The /Info dictionary is usually plain text; read it best-effort without a PDF
# library. Compressed metadata will simply not match, which is fine.
function Get-MatrisePdfProps {
    param([string]$Path)
    $out = [ordered]@{ Author=''; Title=''; Creator=''; Producer=''; Created=''; Modified='' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $txt = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($bytes)
        $grab = {
            param($key)
            if ($txt -match ('/' + $key + '\s*\(((?:\\\)|[^)])*)\)')) { return ($Matches[1] -replace '\\([()\\])', '$1') }
            ''
        }
        $out.Author   = & $grab 'Author'
        $out.Title    = & $grab 'Title'
        $out.Creator  = & $grab 'Creator'
        $out.Producer = & $grab 'Producer'
        $cd = & $grab 'CreationDate'; $md = & $grab 'ModDate'
        $fmt = {
            param($d)  # D:YYYYMMDDHHmmSS...
            if ($d -match 'D:(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?') {
                "{0}-{1}-{2} {3}:{4}:{5}" -f $Matches[1],$Matches[2],$Matches[3],
                    ($Matches[4] -replace '^$','00'),($Matches[5] -replace '^$','00'),($Matches[6] -replace '^$','00')
            } else { $d }
        }
        $out.Created  = & $fmt $cd
        $out.Modified = & $fmt $md
    } catch { }
    [pscustomobject]$out
}

# ---------------------------------------------------------------- PE header --
function Get-MatrisePeInfo {
    param([string]$Path)
    $out = [ordered]@{ Company=''; Product=''; Description=''; OriginalName=''; FileVersion=''; Compiled='' }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $out.Company      = [string]$vi.CompanyName
        $out.Product      = [string]$vi.ProductName
        $out.Description  = [string]$vi.FileDescription
        $out.OriginalName = [string]$vi.OriginalFilename
        $out.FileVersion  = [string]$vi.FileVersion
    } catch { }
    try {
        # Compile timestamp from the COFF header: DOS e_lfanew at 0x3C points to
        # "PE\0\0"; TimeDateStamp is a Unix time 8 bytes past that.
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            $fs.Position = $peOff
            if ($br.ReadUInt16() -eq 0x4550) {   # 'PE'
                $fs.Position = $peOff + 8
                $stamp = $br.ReadUInt32()
                if ($stamp -gt 0 -and $stamp -lt 0xF0000000) {
                    $dt = ([datetimeoffset]::FromUnixTimeSeconds($stamp)).UtcDateTime
                    $out.Compiled = $dt.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
                }
            }
        } finally { $fs.Close() }
    } catch { }
    [pscustomobject]$out
}

# =========================================================================
#  The report the board shows (and the analyzer reads)
# =========================================================================
function Get-MatriseFileMetaReport {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return "  File not found: $Path" }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item.PSIsContainer) { return "  That is a folder, not a file: $Path" }

    $ext  = $item.Extension
    $L = New-Object System.Collections.Generic.List[string]
    $add = { param($t) $L.Add([string]$t) }

    & $add '================================================================'
    & $add ("  FILE INSPECTED: {0}" -f $item.FullName)
    & $add '================================================================'
    & $add ''

    # --- identity ---
    & $add 'IDENTITY'
    & $add ("  Name        : {0}" -f $item.Name)
    & $add ("  Type        : {0}" -f (Get-MatriseFileKind -Ext $ext))
    & $add ("  Size        : {0}" -f (Format-MatriseBytes -Bytes $item.Length))
    & $add ("  Created     : {0}" -f $item.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))
    & $add ("  Modified    : {0}" -f $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    & $add ("  Accessed    : {0}" -f $item.LastAccessTime.ToString('yyyy-MM-dd HH:mm:ss'))
    & $add ("  Attributes  : {0}" -f $item.Attributes)
    try { & $add ("  Owner       : {0}" -f (Get-Acl -LiteralPath $Path -ErrorAction Stop).Owner) } catch { }
    & $add ''

    # --- fingerprints ---
    & $add 'FINGERPRINTS'
    foreach ($algo in 'SHA256','SHA1','MD5') {
        try { & $add ("  {0,-7}: {1}" -f $algo, (Get-FileHash -LiteralPath $Path -Algorithm $algo -ErrorAction Stop).Hash) }
        catch { & $add ("  {0,-7}: (could not read)" -f $algo) }
    }
    & $add ''

    # --- origin / mark of the web ---
    $motw = Get-MatriseMotw -Path $Path
    & $add 'ORIGIN (mark of the web)'
    if ($motw.Present) {
        & $add '  DOWNLOADED FROM THE INTERNET - Windows tagged this as saved from a remote source.'
        & $add ("  Zone        : {0} ({1})" -f $motw.Zone, $motw.ZoneId)
        if ($motw.HostUrl)  { & $add ("  From URL    : {0}" -f $motw.HostUrl) }
        if ($motw.Referrer) { & $add ("  Referrer    : {0}" -f $motw.Referrer) }
    } else {
        & $add '  No mark of the web - not tagged as downloaded (local, copied, or the tag was stripped).'
    }
    & $add ''

    # --- signature ---
    $sig = Get-MatriseSignatureInfo -Path $Path
    & $add 'SIGNATURE'
    switch -Regex ($sig.Status) {
        'Valid'        { & $add ("  Signed by {0} - signature valid." -f $(if ($sig.Signer) { '"' + $sig.Signer + '"' } else { 'a certificate' })) }
        'HashMismatch' { & $add '  SIGNATURE INVALID - the file was changed after it was signed (hash mismatch).' }
        'NotSigned'    {
            if (Test-MatriseIsPE -Ext $ext) { & $add '  UNSIGNED PROGRAM - this executable is not digitally signed.' }
            else { & $add '  Not signed (normal for most non-program files).' }
        }
        default {
            # UnknownError etc: only meaningful for signable code. For a plain
            # document or image, "not signed" is the honest, non-alarming answer.
            if (Test-MatriseIsPE -Ext $ext) { & $add ("  Signature could not be verified ({0})." -f $sig.Status) }
            else { & $add '  Not signed (normal for most non-program files).' }
        }
    }
    if ($sig.TimeStamp) { & $add ("  {0}" -f $sig.TimeStamp) }
    & $add ''

    # --- hidden streams ---
    $ads = Get-MatriseAltStreams -Path $Path
    if (@($ads).Count) {
        & $add 'HIDDEN DATA STREAMS'
        foreach ($s in $ads) { & $add ("  HIDDEN STREAM: {0} ({1} bytes)" -f $s.Stream, $s.Length) }
        & $add ''
    }

    # --- type-specific ---
    if (Test-MatriseIsImage -Ext $ext) {
        $x = Get-MatriseExif -Path $Path
        if ($x.Make -or $x.Model -or $x.Taken -or $x.Software -or $x.Gps) {
            & $add 'PHOTO (EXIF)'
            if ($x.Make -or $x.Model) { & $add ("  Camera      : {0} {1}" -f $x.Make, $x.Model) }
            if ($x.Taken)    { & $add ("  Taken       : {0}" -f $x.Taken) }
            if ($x.Software) { & $add ("  Software    : {0}" -f $x.Software) }
            if ($x.Gps)      { & $add ("  GPS LOCATION: {0}   <-- this photo records where it was taken" -f $x.Gps) }
            & $add ''
        }
    }
    elseif (Test-MatriseIsOffice -Ext $ext) {
        $o = Get-MatriseOfficeProps -Path $Path
        & $add 'DOCUMENT PROPERTIES'
        if ($o.Title)       { & $add ("  Title        : {0}" -f $o.Title) }
        if ($o.Author)      { & $add ("  Author       : {0}" -f $o.Author) }
        if ($o.LastSavedBy) { & $add ("  Last saved by: {0}" -f $o.LastSavedBy) }
        if ($o.Application) { & $add ("  Application  : {0}" -f $o.Application) }
        if ($o.Company)     { & $add ("  Company      : {0}" -f $o.Company) }
        if ($o.Created)     { & $add ("  Created      : {0}" -f $o.Created) }
        if ($o.Modified)    { & $add ("  Modified     : {0}" -f $o.Modified) }
        if ($o.Revision)    { & $add ("  Revisions    : {0}" -f $o.Revision) }
        if ($o.HasMacros)   { & $add '  CONTAINS MACROS - this document carries a VBA macro project (vbaProject.bin).' }
        & $add ''
    }
    elseif ($ext -eq '.pdf') {
        $pdf = Get-MatrisePdfProps -Path $Path
        if ($pdf.Author -or $pdf.Title -or $pdf.Creator -or $pdf.Producer -or $pdf.Created) {
            & $add 'DOCUMENT PROPERTIES'
            if ($pdf.Title)    { & $add ("  Title       : {0}" -f $pdf.Title) }
            if ($pdf.Author)   { & $add ("  Author      : {0}" -f $pdf.Author) }
            if ($pdf.Creator)  { & $add ("  Created with: {0}" -f $pdf.Creator) }
            if ($pdf.Producer) { & $add ("  Producer    : {0}" -f $pdf.Producer) }
            if ($pdf.Created)  { & $add ("  Created     : {0}" -f $pdf.Created) }
            if ($pdf.Modified) { & $add ("  Modified    : {0}" -f $pdf.Modified) }
            & $add ''
        }
    }
    elseif (Test-MatriseIsPE -Ext $ext) {
        $pe = Get-MatrisePeInfo -Path $Path
        & $add 'PROGRAM INFO'
        if ($pe.Description)  { & $add ("  Description  : {0}" -f $pe.Description) }
        if ($pe.Company)      { & $add ("  Company      : {0}" -f $pe.Company) }
        if ($pe.Product)      { & $add ("  Product      : {0}" -f $pe.Product) }
        if ($pe.OriginalName) { & $add ("  Original name: {0}" -f $pe.OriginalName) }
        if ($pe.FileVersion)  { & $add ("  Version      : {0}" -f $pe.FileVersion) }
        if ($pe.Compiled)     { & $add ("  Compiled     : {0}" -f $pe.Compiled) }
        & $add ''
    }

    ($L -join "`r`n")
}
