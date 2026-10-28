#requires -version 5.1
<#
  query.ps1 - read-only query interface over the local archive.

  Answers "what did I watch or save, between X and Y, by this uploader, in this
  partition, matching this word". Pure local: no network, no browser, and it
  never writes into DataRoot.

  Why it exists: the raw jsonl files are append-only and unsorted by time, so
  every downstream tool (share payload, dormancy check, AI draft) would
  otherwise re-implement the same filtering and get it subtly wrong.

  Examples:
    .\query.ps1 -From 2026-10-01 -Json
    .\query.ps1 -Up <uploader-name> -From 2026-09-01 -Limit 20 -Table
    .\query.ps1 -Source fav -Folder <folder-name> -Tag <partition> -Table
    .\query.ps1 -Title AI -Source both -Sort completion -Limit 50 -OutFile out.json
    .\query.ps1 -Text <keyword> -Source both -Limit 20 -Table
    .\query.ps1 -BuildIndex                    # build/refresh the text index
    .\query.ps1 -IndexInfo                     # size, rows, age, staleness
    .\query.ps1 -WithContent -Limit 20 -Table  # mark rows that have a content folder
    .\query.ps1 -ContentStats -Json            # size of the optional content layer

  -Text searches title, intro (favorites), uploader, folder and tag. The first
  run builds a compact index in <tool>\cache\; later runs scan that index and
  parse only the matching lines, so a text query does not re-read the 14k-row
  master table. -NoIndex forces the old full scan. The index never writes into
  DataRoot and is safe to delete at any time.

  Time filters accept yyyy-MM-dd, yyyy-MM-dd HH:mm, yyyy-MM-dd HH:mm:ss
  (also with slashes). A date-only -To includes the whole day.

  Output: a JSON envelope (schema 1) on stdout, or a table with -Table.
  Every item carries the same field names regardless of source, so a caller
  does not have to branch on history vs favorites.

  NOTE: pure ASCII on purpose. Windows PowerShell 5.1 decodes BOM-less .ps1 as
  GBK; one non-ASCII byte here would break parsing.
#>
[CmdletBinding()]
param(
    [string]$From = '',
    [string]$To = '',
    [string]$Up = '',
    [string]$Tag = '',
    [string]$Title = '',
    [string]$Text = '',
    [string]$Bvid = '',
    [string]$Folder = '',
    [ValidateSet('history', 'fav', 'both')]
    [string]$Source = 'history',
    [int]$Limit = 0,
    [ValidateSet('time', 'completion', 'duration')]
    [string]$Sort = 'time',
    [switch]$Ascending,
    [switch]$Table,
    [switch]$Json,
    [string]$OutList = '',
    [switch]$UrlFormat,
    [string]$OutFile = '',
    [string]$IndexDir = '',
    [Alias('RebuildIndex')]
    [switch]$BuildIndex,
    [switch]$IndexInfo,
    [switch]$NoIndex,
    [switch]$WithContent,
    [switch]$ContentStats
)

$ErrorActionPreference = 'Stop'
# --- encoding bootstrap -------------------------------------------------------
# A child PowerShell writes its output as UTF-8 while the parent decodes with
# the ANSI code page, which is how "access denied" turns into mojibake in an
# error dialog. Both sides agreeing on UTF-8 avoids that. A hidden process has
# no console, hence the catch.
try {
    $script:OutEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $script:OutEncoding
    $OutputEncoding = $script:OutEncoding
} catch { }
# -----------------------------------------------------------------------------

$Root = Split-Path -Parent $PSCommandPath
$ConfigFile = Join-Path $Root 'config.json'

$Cfg = $null
if (Test-Path $ConfigFile) {
    $Cfg = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}
if (-not $Cfg -or -not $Cfg.DataRoot) {
    Write-Host 'ERROR: config.json missing or has no DataRoot.'
    exit 2
}
$DataRoot = [string]$Cfg.DataRoot

# Directory names and file names live in config.json: this script stays ASCII.
function Get-DirName {
    param($C, [string]$Key, [string]$Fallback)
    if ($C -and $C.Dirs) {
        $p = $C.Dirs.PSObject.Properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $Fallback
}

function Get-Text {
    param($C, [string]$Key, [string]$Fallback)
    if ($C -and $C.Text) {
        $p = $C.Text.PSObject.Properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $Fallback
}

$DirHistory = Join-Path $DataRoot (Get-DirName $Cfg 'History' 'history')
$DirFav     = Join-Path $DataRoot (Get-DirName $Cfg 'Fav' 'favorites')
$DirDetail  = Join-Path $DataRoot (Get-DirName $Cfg 'Detail' 'details')
$MasterFile = Get-Text $Cfg 'masterFile' 'favorites-master.jsonl'
$LaterFile  = Get-Text $Cfg 'watchLaterFile' 'watch-later.jsonl'
$DetailPath = Join-Path $DirDetail 'details.jsonl'
# The content layer is optional and tool-agnostic: one folder per bvid, filled
# by whatever downloader/subtitle tool the owner chooses. This repo only defines
# the layout (docs/content-layer.md) and reads it; nothing here fetches anything.
$DirContent = Join-Path $DataRoot (Get-DirName $Cfg 'Content' 'content')

foreach ($d in @($DirHistory, $DirFav)) {
    if (-not (Test-Path $d)) {
        Write-Host ('ERROR: data directory missing: ' + $d)
        exit 3
    }
}

# ---------------------------------------------------------------- text index
# A compact sidecar for -Text. The master table is 8.9 MB of full rows; scanning
# it for a substring means parsing 14k JSON objects on every query. The index
# keeps only the fields a search needs, and the query parses just the lines that
# contain the term. It lives in the tool folder, never in DataRoot, and can be
# deleted at any time.
function Get-IndexKey {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

$IndexRoot = $IndexDir
if (-not $IndexRoot) { $IndexRoot = Join-Path $Root 'cache' }
elseif (-not [System.IO.Path]::IsPathRooted($IndexRoot)) { $IndexRoot = Join-Path $Root $IndexRoot }
$IndexRoot = [System.IO.Path]::GetFullPath($IndexRoot)
$script:IndexRoot = $IndexRoot
$script:IndexFile = Join-Path $IndexRoot ('query-index-' + (Get-IndexKey $DataRoot) + '.jsonl')
$script:IndexMetaFile = Join-Path $IndexRoot ('query-index-' + (Get-IndexKey $DataRoot) + '.meta.json')

function ConvertTo-JsonText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
}

function Get-IndexSources {
    $list = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem $DirHistory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ne $LaterFile } | Sort-Object Name)) {
        [void]$list.Add([pscustomobject]@{ p = $f.FullName; len = [int64]$f.Length; ticks = [int64]$f.LastWriteTimeUtc.Ticks })
    }
    $master = Join-Path $DirFav $MasterFile
    if (Test-Path $master) {
        $i = Get-Item $master
        [void]$list.Add([pscustomobject]@{ p = $i.FullName; len = [int64]$i.Length; ticks = [int64]$i.LastWriteTimeUtc.Ticks })
    }
    if (Test-Path $DetailPath) {
        $i = Get-Item $DetailPath
        [void]$list.Add([pscustomobject]@{ p = $i.FullName; len = [int64]$i.Length; ticks = [int64]$i.LastWriteTimeUtc.Ticks })
    }
    return @($list)
}

function Get-IndexMeta {
    if (-not (Test-Path $script:IndexMetaFile)) { return $null }
    try { return [System.IO.File]::ReadAllText($script:IndexMetaFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return $null }
}

function Test-IndexFresh {
    param($Meta)
    if (-not $Meta) { return $false }
    if ([int]$Meta.version -ne 1) { return $false }
    if ([string]$Meta.dataRoot -ne $DataRoot) { return $false }
    if (-not (Test-Path $script:IndexFile)) { return $false }
    $now = @(Get-IndexSources)
    $old = @($Meta.sources)
    if ($old.Count -ne $now.Count) { return $false }
    for ($i = 0; $i -lt $now.Count; $i++) {
        if (-not [string]::Equals([string]$old[$i].p, [string]$now[$i].p, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([int64]$old[$i].len -ne [int64]$now[$i].len) { return $false }
        if ([int64]$old[$i].ticks -ne [int64]$now[$i].ticks) { return $false }
    }
    return $true
}

function New-IndexLine {
    param(
        [string]$Source, [string]$Bvid, [int64]$Aid, [int64]$Time,
        [string]$Title, [string]$Up, [int64]$UpMid, [string]$Tag, [string]$Folder,
        [int]$Duration, $Progress, $Completion, [bool]$Done, [bool]$Invalid,
        [string]$Intro, [string]$Link
    )
    $pText = 'null'
    if ($null -ne $Progress) { $pText = [string][int]$Progress }
    $cText = 'null'
    if ($null -ne $Completion) {
        $cText = ([double]$Completion).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $doneText = 'false'
    if ($Done) { $doneText = 'true' }
    $invText = 'false'
    if ($Invalid) { $invText = 'true' }
    return ('{"s":"' + $Source + '","b":"' + (ConvertTo-JsonText $Bvid) + '","a":' + [string]$Aid +
            ',"t":' + [string]$Time + ',"ti":"' + (ConvertTo-JsonText $Title) + '","u":"' + (ConvertTo-JsonText $Up) +
            '","um":' + [string]$UpMid + ',"g":"' + (ConvertTo-JsonText $Tag) + '","f":"' + (ConvertTo-JsonText $Folder) +
            '","d":' + [string]$Duration + ',"p":' + $pText + ',"c":' + $cText + ',"done":' + $doneText +
            ',"inv":' + $invText + ',"i":"' + (ConvertTo-JsonText $Intro) + '","l":"' + (ConvertTo-JsonText $Link) + '"}')
}

function Build-SearchIndex {
    $detailMap = @{}
    if (Test-Path $DetailPath) {
        foreach ($line in [System.IO.File]::ReadLines($DetailPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            $b = [string]$o.bvid
            if ($b -and [string]$o.desc) { $detailMap[$b] = [string]$o.desc }
        }
    }

    $sources = @(Get-IndexSources)
    if (-not (Test-Path $script:IndexRoot)) { New-Item -ItemType Directory -Force -Path $script:IndexRoot | Out-Null }
    $tmp = $script:IndexFile + '.tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($tmp, $false, $utf8)
    $histRows = 0
    $favRows = 0
    try {
        foreach ($hf in @(Get-ChildItem $DirHistory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -ne $LaterFile } | Sort-Object Name)) {
            foreach ($line in [System.IO.File]::ReadLines($hf.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $r = $null
                try { $r = $line | ConvertFrom-Json } catch { continue }
                $bvid = [string]$r.bvid
                $intro = ''
                if ($bvid -and $detailMap.ContainsKey($bvid)) { $intro = [string]$detailMap[$bvid] }

                $dur = 0
                if ($null -ne $r.duration) { $dur = [int]$r.duration }
                $prog = $null
                if ($null -ne $r.progress) {
                    $p = [int]$r.progress
                    if ($p -ge 0) { $prog = $p }
                }
                $comp = $null
                if ($null -ne $r.completion) {
                    $comp = [double]$r.completion
                } elseif ($null -ne $prog -and $prog -gt 0 -and $dur -gt 0) {
                    $comp = [math]::Round([math]::Min(1.0, $prog / [double]$dur), 4)
                }
                $done = $false
                if ($null -ne $r.completed) { $done = [bool]$r.completed }
                elseif ($null -ne $comp) { $done = ($comp -ge 0.9) }

                $upMid = 0
                if ($null -ne $r.author_mid) { $upMid = [int64]$r.author_mid }
                $lineOut = New-IndexLine 'h' $bvid ([int64]$r.aid) ([int64]$r.view_at) ([string]$r.title) ([string]$r.author) $upMid ([string]$r.tag) '' $dur $prog $comp $done $false $intro ''
                $writer.WriteLine($lineOut)
                $histRows++
            }
        }

        $master = Join-Path $DirFav $MasterFile
        if (Test-Path $master) {
            foreach ($line in [System.IO.File]::ReadLines($master)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $r = $null
                try { $r = $line | ConvertFrom-Json } catch { continue }
                $bvid = [string]$r.bvid
                $intro = [string]$r.intro
                if ($bvid -and $detailMap.ContainsKey($bvid)) { $intro = [string]$detailMap[$bvid] }

                $dur = 0
                if ($null -ne $r.duration) { $dur = [int]$r.duration }
                $upMid = 0
                if ($null -ne $r.upper_mid) { $upMid = [int64]$r.upper_mid }
                $lineOut = New-IndexLine 'f' $bvid ([int64]$r.aid) ([int64]$r.fav_time) ([string]$r.title) ([string]$r.upper) $upMid '' ([string]$r.folder) $dur $null $null $false ([bool]$r.invalid) $intro ([string]$r.link)
                $writer.WriteLine($lineOut)
                $favRows++
            }
        }
    } finally {
        $writer.Dispose()
    }

    if (Test-Path $script:IndexFile) { Remove-Item -LiteralPath $script:IndexFile -Force }
    Move-Item -LiteralPath $tmp -Destination $script:IndexFile -Force
    $sizeBytes = (Get-Item $script:IndexFile).Length

    $meta = [ordered]@{
        version      = 1
        dataRoot     = $DataRoot
        built        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        rows         = $histRows + $favRows
        historyRows  = $histRows
        favRows      = $favRows
        detailRows   = $detailMap.Count
        indexBytes   = $sizeBytes
        sources      = $sources
    }
    [System.IO.File]::WriteAllText($script:IndexMetaFile, ($meta | ConvertTo-Json -Depth 5), $utf8)
    return [pscustomobject]$meta
}

function Write-IndexNote {
    param([string]$Message)
    try { [Console]::Error.WriteLine('[index] ' + $Message) } catch { }
}

# ---------------------------------------------------------------- management

if ($IndexInfo -or $BuildIndex) {
    if ($BuildIndex) {
        try {
            $meta = Build-SearchIndex
            if ($Json) {
                [pscustomobject]@{
                    schema = 1; action = 'build'; path = $script:IndexFile
                    rows = $meta.rows; historyRows = $meta.historyRows; favRows = $meta.favRows
                    detailRows = $meta.detailRows; bytes = $meta.indexBytes; built = $meta.built
                } | ConvertTo-Json -Depth 3
            } else {
                Write-Host ('index built: ' + $script:IndexFile)
                Write-Host ('rows: ' + $meta.rows + ' (history ' + $meta.historyRows + ', fav ' + $meta.favRows + ', detail ' + $meta.detailRows + ')')
                Write-Host ('size: ' + [math]::Round($meta.indexBytes / 1MB, 2) + ' MB')
            }
            exit 0
        } catch {
            Write-Host ('ERROR: index build failed: ' + $_.Exception.Message)
            exit 1
        }
    }

    $meta = Get-IndexMeta
    $exists = Test-Path $script:IndexFile
    $fresh = Test-IndexFresh $meta
    $sizeBytes = 0
    if ($exists) { $sizeBytes = (Get-Item $script:IndexFile).Length }
    if ($Json) {
        [pscustomobject]@{
            schema = 1; path = $script:IndexFile; exists = $exists; fresh = $fresh
            rows = $(if ($meta) { [int]$meta.rows } else { 0 })
            built = $(if ($meta) { [string]$meta.built } else { '' })
            bytes = $sizeBytes
            sources = $(if ($meta) { @($meta.sources).Count } else { 0 })
        } | ConvertTo-Json -Depth 3
    } else {
        Write-Host ('index : ' + $script:IndexFile)
        if (-not $exists) {
            Write-Host 'state : not built (run -BuildIndex)'
        } else {
            Write-Host ('state : ' + $(if ($fresh) { 'fresh' } else { 'STALE (next -Text rebuilds it)' }))
            Write-Host ('rows  : ' + $(if ($meta) { [int]$meta.rows } else { 0 }))
            Write-Host ('size  : ' + [math]::Round($sizeBytes / 1MB, 2) + ' MB')
            if ($meta) { Write-Host ('built : ' + [string]$meta.built) }
        }
    }
    exit 0
}

# ---------------------------------------------------------------- content layer
# Optional. When the folder is absent every row simply reports has_content=false
# and nothing else changes. Size is measured and reported, never enforced: this
# is the one part of the archive that cannot be re-collected, so the tool never
# deletes it on its own.
function Get-ContentStats {
    $st = [pscustomobject]@{
        path = $DirContent; exists = $false; items = 0; bytes = [int64]0
        newest = ''; oldest = ''; level = 'ok'
    }
    if (-not (Test-Path $DirContent)) { return $st }
    $st.exists = $true
    $dirs = @(Get-ChildItem -LiteralPath $DirContent -Directory -ErrorAction SilentlyContinue)
    $st.items = $dirs.Count
    $sum = [int64]0
    foreach ($f in @(Get-ChildItem -LiteralPath $DirContent -Recurse -File -ErrorAction SilentlyContinue)) {
        $sum += [int64]$f.Length
    }
    $st.bytes = $sum
    if ($dirs.Count -gt 0) {
        $times = @($dirs | Sort-Object LastWriteTime)
        $st.oldest = $times[0].LastWriteTime.ToString('yyyy-MM-dd')
        $st.newest = $times[$times.Count - 1].LastWriteTime.ToString('yyyy-MM-dd')
    }
    $gb = $st.bytes / 1GB
    if ($gb -ge 5) { $st.level = 'warn' } elseif ($gb -ge 1) { $st.level = 'notice' }
    return $st
}

if ($ContentStats) {
    $st = Get-ContentStats
    if ($Json) {
        [pscustomobject]@{
            schema = 1; path = $st.path; exists = $st.exists; items = $st.items
            bytes = $st.bytes; megabytes = [math]::Round($st.bytes / 1MB, 2)
            oldest = $st.oldest; newest = $st.newest; level = $st.level
        } | ConvertTo-Json -Depth 3
    } else {
        Write-Host ('content : ' + $st.path)
        if (-not $st.exists) {
            Write-Host 'state   : not used (optional; any external tool may fill it)'
        } else {
            Write-Host ('items   : ' + $st.items)
            Write-Host ('size    : ' + [math]::Round($st.bytes / 1MB, 2) + ' MB')
            if ($st.items -gt 0) { Write-Host ('range   : ' + $st.oldest + ' ~ ' + $st.newest) }
            Write-Host ('level   : ' + $st.level)
        }
    }
    exit 0
}

# ---------------------------------------------------------------- time parsing

function ConvertTo-Epoch {
    param([string]$Text, [bool]$EndOfDay)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $formats = @(
        'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd',
        'yyyy/MM/dd HH:mm:ss', 'yyyy/MM/dd HH:mm', 'yyyy/MM/dd',
        'yyyyMMdd'
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $clean = $Text.Trim()

    foreach ($fmt in $formats) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact($clean, $fmt, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) {
            # A bare date as upper bound must include that whole day.
            if ($EndOfDay -and ($fmt -notmatch 'HH')) { $dt = $dt.AddDays(1).AddSeconds(-1) }
            return ([DateTimeOffset]$dt).ToUnixTimeSeconds()
        }
    }
    return $null
}

$fromEpoch = $null
if ($From -ne '') {
    $fromEpoch = ConvertTo-Epoch $From $false
    if ($null -eq $fromEpoch) {
        Write-Host ('ERROR: cannot parse -From "' + $From + '". Use yyyy-MM-dd or yyyy-MM-dd HH:mm.')
        exit 2
    }
}
$toEpoch = $null
if ($To -ne '') {
    $toEpoch = ConvertTo-Epoch $To $true
    if ($null -eq $toEpoch) {
        Write-Host ('ERROR: cannot parse -To "' + $To + '". Use yyyy-MM-dd or yyyy-MM-dd HH:mm.')
        exit 2
    }
}
if ($null -ne $fromEpoch -and $null -ne $toEpoch -and $fromEpoch -gt $toEpoch) {
    Write-Host 'ERROR: -From is later than -To.'
    exit 2
}

# -Up accepts either a numeric UID or a name fragment.
$upMid = [int64](-1)
if ($Up -match '^[0-9]+$') { $upMid = [int64]$Up }

$wantHistory = ($Source -eq 'history' -or $Source -eq 'both')
$wantFav     = ($Source -eq 'fav' -or $Source -eq 'both')

# ---------------------------------------------------------------- match helpers

function Test-Common {
    param(
        [int64]$Time, [string]$Name, [int64]$NameMid, [string]$TagVal,
        [string]$TitleVal, [string]$BvidVal, [string]$FolderVal = '',
        [string]$IntroVal = '', [string]$Needle = ''
    )

    if ($null -ne $fromEpoch -and $Time -lt $fromEpoch) { return $false }
    if ($null -ne $toEpoch -and $Time -gt $toEpoch) { return $false }
    if ($Up -ne '') {
        if ($upMid -ge 0) {
            if ($NameMid -ne $upMid) { return $false }
        }
        elseif ($Name -notlike ('*' + $Up + '*')) { return $false }
    }
    if ($Tag -ne '' -and $TagVal -notlike ('*' + $Tag + '*')) { return $false }
    if ($Title -ne '' -and $TitleVal -notlike ('*' + $Title + '*')) { return $false }
    if ($Bvid -ne '' -and $BvidVal -ne $Bvid) { return $false }
    if ($Folder -ne '' -and $FolderVal -notlike ('*' + $Folder + '*')) { return $false }
    if ($Needle -ne '') {
        $hay = $TitleVal + "`n" + $IntroVal + "`n" + $Name + "`n" + $TagVal + "`n" + $FolderVal
        if ($hay.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

$items = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- index path
# -Text first tries the compact index. Only lines that contain the term are
# parsed as JSON, so the cost is one pass over ~8 MB of short records instead
# of 14k full master rows. Falls back to the full scan if the index cannot be
# built (read-only USB stick, no cache folder, etc.).

$usedIndex = $false
if ($Text -ne '' -and -not $NoIndex) {
    $meta = Get-IndexMeta
    if (-not (Test-IndexFresh $meta)) {
        try {
            $meta = Build-SearchIndex
            Write-IndexNote ('rebuilt: ' + [int]$meta.rows + ' rows')
        } catch {
            Write-IndexNote ('build failed, using full scan: ' + $_.Exception.Message)
            $meta = $null
        }
    }
    if (Test-IndexFresh $meta) {
        $usedIndex = $true
        $rawSafe = ($Text.IndexOfAny([char[]]@('"', '\')) -lt 0)
        foreach ($line in [System.IO.File]::ReadLines($script:IndexFile)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($rawSafe -and $line.IndexOf($Text, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $r = $null
            try { $r = $line | ConvertFrom-Json } catch { continue }

            $s = [string]$r.s
            if ($s -eq 'h') {
                if (-not $wantHistory) { continue }
            } elseif ($s -eq 'f') {
                if (-not $wantFav) { continue }
                # Favorites carry no partition tag; a -Tag filter cannot match them.
                if ($Tag -ne '') { continue }
            } else { continue }

            $t = [int64]$r.t
            $upName = [string]$r.u
            $upId = [int64]$r.um
            $tagVal = [string]$r.g
            $folderVal = [string]$r.f
            $titleVal = [string]$r.ti
            $introVal = [string]$r.i
            $bvidVal = [string]$r.b
            if (-not (Test-Common $t $upName $upId $tagVal $titleVal $bvidVal $folderVal $introVal $Text)) { continue }

            $dur = [int]$r.d
            $prog = $null
            if ($null -ne $r.p) { $prog = [int]$r.p }
            $comp = $null
            if ($null -ne $r.c) { $comp = [double]$r.c }
            $link = [string]$r.l
            if ($link -eq '' -and $bvidVal -ne '') { $link = 'https://www.bilibili.com/video/' + $bvidVal }

            [void]$items.Add([pscustomobject]@{
                source     = $(if ($s -eq 'h') { 'history' } else { 'fav' })
                time       = $t
                bvid       = $bvidVal
                aid        = [int64]$r.a
                title      = $titleVal
                up         = $upName
                up_mid     = $upId
                tag        = $tagVal
                folder     = $folderVal
                duration   = $dur
                progress   = $prog
                completion = $comp
                completed  = [bool]$r.done
                invalid    = [bool]$r.inv
                link       = $link
            })
        }
    }
}

if (-not $usedIndex) {

# Keep -NoIndex results consistent with the index: the index folds in the full
# description from details.jsonl when one exists, so the fallback does too.
$detailTextMap = @{}
if ($Text -ne '' -and (Test-Path $DetailPath)) {
    foreach ($line in [System.IO.File]::ReadLines($DetailPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $b = [string]$o.bvid
        if ($b -and [string]$o.desc) { $detailTextMap[$b] = [string]$o.desc }
    }
}

# ---------------------------------------------------------------- history rows

if ($wantHistory) {
    $histFiles = @(Get-ChildItem $DirHistory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -ne $LaterFile })
    foreach ($hf in $histFiles) {
        foreach ($line in [System.IO.File]::ReadLines($hf.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $rec = $null
            try { $rec = $line | ConvertFrom-Json } catch { continue }

            $t = [int64]$rec.view_at
            $authorName = [string]$rec.author
            $authorMid = 0
            if ($null -ne $rec.author_mid) { $authorMid = [int64]$rec.author_mid }

            $introVal = ''
            $bvidForText = [string]$rec.bvid
            if ($detailTextMap.ContainsKey($bvidForText)) { $introVal = [string]$detailTextMap[$bvidForText] }
            if (-not (Test-Common $t $authorName $authorMid ([string]$rec.tag) ([string]$rec.title) ([string]$rec.bvid) '' $introVal $Text)) { continue }

            $dur = 0
            if ($null -ne $rec.duration) { $dur = [int]$rec.duration }

            $prog = $null
            if ($null -ne $rec.progress) {
                $p = [int]$rec.progress
                if ($p -ge 0) { $prog = $p }
            }

            $comp = $null
            if ($null -ne $rec.completion) {
                $comp = [double]$rec.completion
            }
            elseif ($null -ne $prog -and $prog -gt 0 -and $dur -gt 0) {
                $comp = [math]::Round([math]::Min(1.0, $prog / [double]$dur), 4)
            }

            $done = $false
            if ($null -ne $rec.completed) { $done = [bool]$rec.completed }
            elseif ($null -ne $comp) { $done = ($comp -ge 0.9) }

            $bv = [string]$rec.bvid
            $link = ''
            if ($bv -ne '') { $link = 'https://www.bilibili.com/video/' + $bv }

            [void]$items.Add([pscustomobject]@{
                source     = 'history'
                time       = $t
                bvid       = $bv
                aid        = [int64]$rec.aid
                title      = [string]$rec.title
                up         = $authorName
                up_mid     = $authorMid
                tag        = [string]$rec.tag
                folder     = ''
                duration   = $dur
                progress   = $prog
                completion = $comp
                completed  = $done
                invalid    = $false
                link       = $link
            })
        }
    }
}

# ---------------------------------------------------------------- favorite rows

if ($wantFav) {
    $masterPath = Join-Path $DirFav $MasterFile
    if (Test-Path $masterPath) {
        foreach ($line in [System.IO.File]::ReadLines($masterPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $rec = $null
            try { $rec = $line | ConvertFrom-Json } catch { continue }

            $t = [int64]$rec.fav_time
            $upName = [string]$rec.upper
            $upId = 0
            if ($null -ne $rec.upper_mid) { $upId = [int64]$rec.upper_mid }
            $folderName = [string]$rec.folder

            $introVal = [string]$rec.intro
            $bvidForText = [string]$rec.bvid
            if ($detailTextMap.ContainsKey($bvidForText)) { $introVal = [string]$detailTextMap[$bvidForText] }
            if ($Folder -ne '' -and $folderName -notlike ('*' + $Folder + '*')) { continue }
            # Favorites carry no partition tag; a -Tag filter cannot match them.
            if ($Tag -ne '') { continue }
            if (-not (Test-Common $t $upName $upId '' ([string]$rec.title) ([string]$rec.bvid) $folderName $introVal $Text)) { continue }

            $dur = 0
            if ($null -ne $rec.duration) { $dur = [int]$rec.duration }

            $bv = [string]$rec.bvid
            $link = [string]$rec.link
            if ($link -eq '' -and $bv -ne '') { $link = 'https://www.bilibili.com/video/' + $bv }

            [void]$items.Add([pscustomobject]@{
                source     = 'fav'
                time       = $t
                bvid       = $bv
                aid        = [int64]$rec.aid
                title      = [string]$rec.title
                up         = $upName
                up_mid     = $upId
                tag        = ''
                folder     = $folderName
                duration   = $dur
                progress   = $null
                completion = $null
                completed  = $false
                invalid    = [bool]$rec.invalid
                link       = $link
            })
        }
    }
}

}  # end full-scan path

$matched = $items.Count

# ---------------------------------------------------------------- sort / limit

if ($matched -gt 0) {
    switch ($Sort) {
        'completion' { $sorted = @($items | Sort-Object -Property @{ Expression = { if ($null -eq $_.completion) { -1 } else { $_.completion } } }) }
        'duration'   { $sorted = @($items | Sort-Object -Property duration) }
        default      { $sorted = @($items | Sort-Object -Property time) }
    }
    if (-not $Ascending) { [array]::Reverse($sorted) }
}
else {
    $sorted = @()
}

$out = @($sorted)
if ($Limit -gt 0 -and $out.Count -gt $Limit) { $out = @($out | Select-Object -First $Limit) }

# Optional: mark rows that already have a content folder. One directory listing
# instead of one Test-Path per row, so this stays cheap even without -Limit.
if ($WithContent) {
    $have = @{}
    if (Test-Path $DirContent) {
        foreach ($d in @(Get-ChildItem -LiteralPath $DirContent -Directory -ErrorAction SilentlyContinue)) {
            $have[$d.Name] = $true
        }
    }
    foreach ($it in $out) {
        $hc = $false
        $bv = [string]$it.bvid
        if ($bv -ne '' -and $have.ContainsKey($bv)) { $hc = $true }
        $it | Add-Member -NotePropertyName has_content -NotePropertyValue $hc -Force
    }
}

# Hand a plain list to an external downloader (BBDown, yt-dlp, a userscript's
# batch panel). One id per line: no JSON, no quoting, trivially consumable.
if ($OutList -ne '') {
    $lines = New-Object System.Collections.ArrayList
    foreach ($item in $out) {
        $bv = [string]$item.bvid
        if ($bv -eq '') { continue }
        if ($UrlFormat) { [void]$lines.Add('https://www.bilibili.com/video/' + $bv) }
        else { [void]$lines.Add($bv) }
    }
    $full = $OutList
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $Root $full }
    $parentDir = Split-Path -Parent $full
    if ($parentDir -and -not (Test-Path $parentDir)) { New-Item -ItemType Directory -Force -Path $parentDir | Out-Null }
    $body = ''
    if ($lines.Count -gt 0) { $body = ($lines -join "`r`n") + "`r`n" }
    [System.IO.File]::WriteAllText($full, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('list: {0} id(s) -> {1}' -f $lines.Count, $full)
    exit 0
}

# ---------------------------------------------------------------- emit

$queryEcho = [ordered]@{
    from    = $From
    to      = $To
    up      = $Up
    tag     = $Tag
    title   = $Title
    bvid    = $Bvid
    folder  = $Folder
    source  = $Source
    sort    = $Sort
    ascending = [bool]$Ascending
    limit   = $Limit
}
# Only present when the switch is used, so default output stays byte-identical.
if ($Text) { $queryEcho.Insert(5, 'text', $Text) }
$queryEcho = [pscustomobject]$queryEcho

$envelope = [pscustomobject]@{
    schema    = 1
    generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    query     = $queryEcho
    matched   = $matched
    returned  = $out.Count
    items     = $out
}

if ($OutFile -ne '') {
    # NOTE: do not name this $json -- PowerShell is case-insensitive and would
    # assign into the [switch]$Json parameter, throwing a conversion error.
    $jsonText = $envelope | ConvertTo-Json -Depth 4
    $full = $OutFile
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $Root $full }
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($full, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('matched={0} returned={1} -> {2}' -f $matched, $out.Count, $full)
}
elseif ($Table) {
    if ($out.Count -eq 0) {
        Write-Host ('no match (source={0})' -f $Source)
    }
    else {
        $out | ForEach-Object {
            $tt = ''
            if ($_.time -gt 0) { $tt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$_.time).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
            $tl = [string]$_.title
            if ($tl.Length -gt 42) { $tl = $tl.Substring(0, 41) + '~' }
            $un = [string]$_.up
            if ($un.Length -gt 12) { $un = $un.Substring(0, 11) + '~' }
            $mm = [int][math]::Floor([int]$_.duration / 60)
            $pc = ''
            if ($null -ne $_.completion) { $pc = [string][math]::Round([double]$_.completion * 100) + '%' }
            [pscustomobject]@{
                time  = $tt
                src   = [string]$_.source
                title = $tl
                up    = $un
                min   = $mm
                done  = $pc
                bvid  = [string]$_.bvid
            }
        } | Format-Table -AutoSize | Out-String -Width 200
        Write-Host ('matched={0} returned={1}' -f $matched, $out.Count)
    }
}
else {
    $envelope | ConvertTo-Json -Depth 4
}

exit 0
