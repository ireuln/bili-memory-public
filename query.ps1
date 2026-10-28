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
    [string]$OutFile = ''
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
$MasterFile = Get-Text $Cfg 'masterFile' 'favorites-master.jsonl'
$LaterFile  = Get-Text $Cfg 'watchLaterFile' 'watch-later.jsonl'

foreach ($d in @($DirHistory, $DirFav)) {
    if (-not (Test-Path $d)) {
        Write-Host ('ERROR: data directory missing: ' + $d)
        exit 3
    }
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
    param([int64]$Time, [string]$Name, [int64]$NameMid, [string]$TagVal, [string]$TitleVal, [string]$BvidVal)

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
    return $true
}

$items = New-Object System.Collections.ArrayList

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

            if (-not (Test-Common $t $authorName $authorMid ([string]$rec.tag) ([string]$rec.title) ([string]$rec.bvid))) { continue }

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

            if ($Folder -ne '' -and $folderName -notlike ('*' + $Folder + '*')) { continue }
            # Favorites carry no partition tag; a -Tag filter cannot match them.
            if ($Tag -ne '') { continue }
            if (-not (Test-Common $t $upName $upId '' ([string]$rec.title) ([string]$rec.bvid))) { continue }

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

$queryEcho = [pscustomobject]@{
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
