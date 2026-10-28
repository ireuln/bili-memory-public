#requires -version 5.1
<#
  share.ps1 - build a share payload from the local archive.

  Produces two things, both pure local (no browser, no network, read-only):
    1. card.html  - one self-contained HTML page (covers embedded as base64),
                    so it opens offline and can be screenshotted for posting.
    2. payload/   - a small, documented data package (jsonl + summary + manifest)
                    that another person or another AI can read without the repo.

  The post text is written next to the card as post.txt, ready to paste.

  Examples:
    .\share.ps1                          # last 30 days
    .\share.ps1 -Period 2026-10          # a calendar month
    .\share.ps1 -Period 2026             # a whole year
    .\share.ps1 -From 2026-10-01 -To 2026-10-15 -IncludeFavorites
    .\share.ps1 -Period 2026-10 -NoTitles -OnlyPack

  Privacy: the payload never contains DMs, login state, cookies or cover
  images. Titles are included by default; -NoTitles redacts them.

  NOTE: pure ASCII on purpose. All Chinese text lives in config.json or in
  share\*.html / *.txt / *.md templates; PS 5.1 decodes BOM-less .ps1 as GBK.
#>
[CmdletBinding()]
param(
    [string]$Period = 'last30d',
    [string]$From = '',
    [string]$To = '',
    [string]$OutRoot = '',
    [int]$TopN = 5,
    [int]$MaxCovers = 12,
    [switch]$NoTitles,
    [switch]$NoCovers,
    [switch]$NoPng,
    [switch]$IncludeFavorites,
    [switch]$OnlyCard,
    [switch]$OnlyPack,
    [switch]$Open
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

# A light watermark on the rendered card. Text comes from config.json so this
# file stays ASCII; the point is that a card re-shared elsewhere still carries
# the project name, without covering the user's own content.
$WmOn = $true
if ($Cfg -and $Cfg.PSObject.Properties['CardWatermark'] -and $null -ne $Cfg.CardWatermark) {
    $WmOn = [bool]$Cfg.CardWatermark
}
$WmText = 'bili-memory'
if ($Cfg -and $Cfg.PSObject.Properties['WatermarkText'] -and $Cfg.WatermarkText) {
    $WmText = [string]$Cfg.WatermarkText
}
$cardPng = $null
if (-not $Cfg -or -not $Cfg.DataRoot) {
    Write-Host 'ERROR: config.json missing or has no DataRoot.'
    exit 2
}
. (Join-Path $Root 'lib\ui-lang.ps1')
$Cfg = Merge-UiLanguage -Cfg $Cfg -Root $Root
$DataRoot = [string]$Cfg.DataRoot

$EdgeExe = if ($Cfg.BrowserExe) { [string]$Cfg.BrowserExe } else { 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }
if (-not (Test-Path $EdgeExe)) { $EdgeExe = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }

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

# All user-facing wording comes from config.json's Share block.
$Lbl = @{
    Headline      = 'Watched {0} hours'
    Lead          = '{0} records over {1} days, {2}% completed on average.'
    Empty         = 'No watch records in this period.'
    RedactedTitle = '...'
    UnknownUp     = 'unknown'
    NoHighlight   = '-'
    Footer        = 'local archive, no network, no DMs'
}
if ($Cfg.Share) {
    foreach ($p in $Cfg.Share.PSObject.Properties) {
        if ($Lbl.ContainsKey($p.Name)) { $Lbl[$p.Name] = [string]$p.Value }
    }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Cover thumbnails usually have the title text baked into the image, so
# redacting titles while still shipping covers would defeat the purpose.
if ($NoTitles -and -not $NoCovers) {
    $NoCovers = $true
    Write-Host 'note: -NoTitles implies -NoCovers, because cover images contain the title.'
}

# ---------------------------------------------------------------- period

$today = (Get-Date).Date
$fromDate = $null
$toDate = $null
$label = ''

if ($From -ne '' -and $To -ne '') {
    $parsedFrom = [datetime]::MinValue
    $parsedTo = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($From.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedFrom)) {
        Write-Host ('ERROR: cannot parse -From "' + $From + '", use yyyy-MM-dd.'); exit 2
    }
    if (-not [datetime]::TryParseExact($To.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedTo)) {
        Write-Host ('ERROR: cannot parse -To "' + $To + '", use yyyy-MM-dd.'); exit 2
    }
    $fromDate = $parsedFrom
    $toDate = $parsedTo
    $label = $parsedFrom.ToString('yyyyMMdd') + '-' + $parsedTo.ToString('yyyyMMdd')
}
elseif ($Period -match '^\d{4}-\d{2}$') {
    $first = [datetime]::ParseExact($Period, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
    $fromDate = $first
    $toDate = $first.AddMonths(1).AddDays(-1)
    $label = $Period
}
elseif ($Period -match '^\d{4}$') {
    $first = [datetime]::ParseExact($Period, 'yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    $fromDate = $first
    $toDate = $first.AddYears(1).AddDays(-1)
    $label = $Period
}
elseif ($Period -match '^last(\d{1,3})d$') {
    $n = [int]$Matches[1]
    if ($n -lt 1) { Write-Host 'ERROR: -Period lastNd needs N >= 1.'; exit 2 }
    $fromDate = $today.AddDays(-1 * ($n - 1))
    $toDate = $today
    $label = 'last' + $n + 'd-' + $today.ToString('yyyyMMdd')
}
else {
    Write-Host ('ERROR: -Period "' + $Period + '" not understood. Use last30d, yyyy-MM or yyyy.')
    exit 2
}

if ($fromDate -gt $toDate) { Write-Host 'ERROR: -From is later than -To.'; exit 2 }

$fromStr = $fromDate.ToString('yyyy-MM-dd')
$toStr = $toDate.ToString('yyyy-MM-dd')
$periodText = $fromStr + ' ~ ' + $toStr
$dayCount = [int](($toDate - $fromDate).TotalDays) + 1

# ---------------------------------------------------------------- load rows
# Reuse query.ps1 instead of re-implementing jsonl parsing: one contract, one
# place to fix sorting and completion fallbacks.

$QueryScript = Join-Path $Root 'query.ps1'
if (-not (Test-Path $QueryScript)) { Write-Host 'ERROR: query.ps1 not found next to share.ps1.'; exit 2 }

# HIPS products (and some locked-down profiles) deny a background script that
# writes into %TEMP%; GetTempFileName then throws "access to the path is
# denied" and the whole card fails. Try a few writable places in turn instead
# of assuming the temp folder works.
function New-ScratchPath {
    $candidates = New-Object System.Collections.ArrayList
    try { [void]$candidates.Add([System.IO.Path]::GetTempPath()) } catch { }
    [void]$candidates.Add($Root)
    if ($DataRoot) { [void]$candidates.Add($DataRoot) }

    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        try {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $path = Join-Path $dir ('share-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
            [System.IO.File]::WriteAllText($path, '', (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }
        catch { continue }
    }
    throw 'no writable scratch directory (tried the temp folder, the tool folder and DataRoot). A security product may be blocking writes; whitelist the tool folder.'
}

function Read-Query {
    param([string]$SourceKind)

    $tmp = New-ScratchPath
    try {
        & $QueryScript -From $fromStr -To $toStr -Source $SourceKind -Json -OutFile $tmp 6>$null | Out-Null
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw ('query.ps1 exited ' + $code) }
        $text = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'query.ps1 produced an empty file' }
        return ($text | ConvertFrom-Json)
    }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

$q = Read-Query 'history'
$items = @($q.items)
$count = $items.Count

# ---------------------------------------------------------------- statistics

$secs = 0
$compSum = 0.0
$compN = 0
$daySet = @{}
$upMap = @{}
$tagMap = @{}
$hl = $null
$hlProg = -1

foreach ($it in $items) {
    if ($null -ne $it.progress -and $it.progress -gt 0) { $secs += [int64]$it.progress }
    if ($null -ne $it.completion) { $compSum += [double]$it.completion; $compN++ }

    if ([int64]$it.time -gt 0) {
        $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$it.time).ToLocalTime().ToString('yyyy-MM-dd')
        $daySet[$d] = $true
    }

    $upName = [string]$it.up
    if ($upName -eq '') { $upName = $Lbl.UnknownUp }
    if (-not $upMap.ContainsKey($upName)) { $upMap[$upName] = @{ secs = 0; n = 0 } }
    $upMap[$upName].n++
    if ($null -ne $it.progress -and $it.progress -gt 0) { $upMap[$upName].secs += [int64]$it.progress }

    $tagName = [string]$it.tag
    if ($tagName -ne '') {
        if (-not $tagMap.ContainsKey($tagName)) { $tagMap[$tagName] = 0 }
        $tagMap[$tagName]++
    }

    if ($null -ne $it.progress -and [int64]$it.progress -gt $hlProg) {
        $hlProg = [int64]$it.progress
        $hl = $it
    }
}

$hours = [math]::Round($secs / 3600.0, 1)
$avgComp = 0
if ($compN -gt 0) { $avgComp = [math]::Round(100.0 * $compSum / $compN, 0) }
$activeDays = $daySet.Count

$upSorted = @($upMap.GetEnumerator() | Sort-Object { $_.Value.secs } -Descending | Select-Object -First $TopN)
$tagSorted = @($tagMap.GetEnumerator() | Sort-Object { $_.Value } -Descending | Select-Object -First $TopN)

$favCount = 0
$favItems = @()
if ($IncludeFavorites) {
    $fq = Read-Query 'fav'
    $favItems = @($fq.items)
    $favCount = $favItems.Count
}

# ---------------------------------------------------------------- helpers

function Esc {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = $Text.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    $s = $s.Replace('"', '&quot;')
    return $s
}

function Get-Sha256 {
    param([string]$Path)
    $algo = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $hash = $algo.ComputeHash($fs)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $fs.Dispose()
        $algo.Dispose()
    }
}

function Fill {
    param([string]$Text, [hashtable]$Map)
    $out = $Text
    foreach ($k in $Map.Keys) { $out = $out.Replace('{{' + $k + '}}', [string]$Map[$k]) }
    return $out
}

# Render the card to PNG with the same Edge the collector already requires, so
# the result can be posted without opening a browser by hand.
function Save-CardPng {
    param([string]$HtmlPath, [string]$OutPng, [string]$EdgeExe)

    if (-not (Test-Path $EdgeExe)) { return $false }

    # A throwaway profile keeps this from colliding with the collector's
    # dedicated profile (which is locked while a run is in progress).
    $ud = Join-Path $env:TEMP ('dsh-share-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    try {
        $proc = Start-Process -FilePath $EdgeExe -PassThru -Wait -WindowStyle Hidden -ArgumentList @(
            '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
            ('--user-data-dir=' + $ud), '--window-size=900,2400', ('--screenshot=' + $OutPng), $uri
        )
    }
    catch { return $false }
    finally { Remove-Item $ud -Recurse -Force -ErrorAction SilentlyContinue }

    return (Test-Path $OutPng)
}

# Headless screenshots are viewport-sized, so cut the empty tail. Sampling
# every Nth pixel keeps this fast enough for PowerShell.
function Trim-CardPng {
    param([string]$Path, [int]$Step = 12)

    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap($Path)
    try {
        $w = $bmp.Width
        $h = $bmp.Height
        $bg = $bmp.GetPixel(2, 2)
        $last = $h - 1

        for ($y = $h - 1; $y -ge 0; $y--) {
            $found = $false
            for ($x = 0; $x -lt $w; $x += $Step) {
                $c = $bmp.GetPixel($x, $y)
                if ($c.R -ne $bg.R -or $c.G -ne $bg.G -or $c.B -ne $bg.B) { $found = $true; break }
            }
            if ($found) { $last = $y; break }
        }

        $newH = [math]::Min($h, $last + 40)
        if ($newH -ge $h) { return $false }

        $crop = New-Object System.Drawing.Bitmap($w, $newH)
        $g = [System.Drawing.Graphics]::FromImage($crop)
        $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $newH)), (New-Object System.Drawing.Rectangle(0, 0, $w, $newH)), [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $bmp.Dispose()
        $crop.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $crop.Dispose()
        return $true
    }
    catch { return $false }
    finally {
        try { $bmp.Dispose() } catch { }
    }
}

# Draw a small, low-opacity project mark in the corner. Kept deliberately
# weak: the card belongs to the user, the watermark only has to survive a
# re-upload. A one-pixel dark shadow keeps it readable on light and dark cards.
function Add-CardWatermark {
    param([string]$Path, [string]$Text, [int]$Alpha = 96)

    if (-not $Text) { return $false }
    Add-Type -AssemblyName System.Drawing
    $bmp = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap($Path)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $px = [int][Math]::Max(12, [Math]::Round($bmp.Width / 90))
        $font = New-Object System.Drawing.Font('Microsoft YaHei', $px, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $size = $g.MeasureString($Text, $font)
        $x = [int]($bmp.Width - $size.Width - 18)
        $y = [int]($bmp.Height - $size.Height - 12)
        if ($x -lt 4) { $x = 4 }
        if ($y -lt 4) { $y = 4 }

        $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
        $g.DrawString($Text, $font, $shadow, ($x + 1), ($y + 1))
        $shadow.Dispose()

        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($Alpha, 255, 255, 255))
        $g.DrawString($Text, $font, $brush, $x, $y)
        $brush.Dispose()
        $font.Dispose()
        $g.Dispose()

        # GDI+ locks the file it decoded from: saving to the same path throws
        # "A generic error occurred in GDI+". Write a sibling file, then swap.
        $tmp = $Path + '.wm.tmp'
        $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $bmp = $null
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    }
    catch { return $false }
    finally {
        try { if ($bmp) { $bmp.Dispose() } } catch { }
    }
}

# ---------------------------------------------------------------- build card
$genText = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$headline = ''
$lead = ''
if ($count -gt 0) {
    $headline = ($Lbl.Headline -f $hours)
    $lead = ($Lbl.Lead -f $count, $activeDays, $avgComp)
}
else {
    $headline = $Lbl.Empty
    $lead = ''
}

$upRows = New-Object System.Text.StringBuilder
$maxUpSecs = 0
if ($upSorted.Count -gt 0) { $maxUpSecs = [int64]$upSorted[0].Value.secs }
foreach ($e in $upSorted) {
    $w = 0
    if ($maxUpSecs -gt 0) { $w = [int][math]::Round(100.0 * [int64]$e.Value.secs / $maxUpSecs) }
    if ($w -lt 2 -and $e.Value.secs -gt 0) { $w = 2 }
    $h = [math]::Round([int64]$e.Value.secs / 3600.0, 1)
    [void]$upRows.Append('<div class="row"><span class="nm">' + (Esc $e.Key) + '</span>' +
        '<span class="bar"><i style="width:' + $w + '%"></i></span>' +
        '<span class="val">' + $h + 'h</span></div>')
}

$tagRows = New-Object System.Text.StringBuilder
$maxTag = 0
if ($tagSorted.Count -gt 0) { $maxTag = [int]$tagSorted[0].Value }
foreach ($e in $tagSorted) {
    $w = 0
    if ($maxTag -gt 0) { $w = [int][math]::Round(100.0 * [int]$e.Value / $maxTag) }
    if ($w -lt 2) { $w = 2 }
    [void]$tagRows.Append('<div class="row"><span class="nm">' + (Esc $e.Key) + '</span>' +
        '<span class="bar t"><i style="width:' + $w + '%"></i></span>' +
        '<span class="val">' + [int]$e.Value + '</span></div>')
}

$hlTitle = $Lbl.NoHighlight
$hlUp = ''
$hlMeta = ''
if ($hl) {
    $hlTitle = [string]$hl.title
    if ($NoTitles) { $hlTitle = $Lbl.RedactedTitle }
    $hlUp = [string]$hl.up
    if ($hlUp -eq '') { $hlUp = $Lbl.UnknownUp }
    $mins = [int][math]::Floor([int]$hl.duration / 60)
    $hlMeta = ([math]::Round([int64]$hlProg / 60.0, 0)).ToString() + ' / ' + $mins + ' min'
}

# covers: embedded as base64 so the card stays a single file
$coverHtml = ''
if (-not $NoCovers -and $MaxCovers -gt 0) {
    $coverDir = Join-Path $DataRoot (Get-DirName $Cfg 'Cover' 'covers')
    if (Test-Path $coverDir) {
        $coverMap = @{}
        foreach ($cf in Get-ChildItem $coverDir -Recurse -File -Filter '*.jpg' -ErrorAction SilentlyContinue) {
            $key = [System.IO.Path]::GetFileNameWithoutExtension($cf.Name)
            if (-not $coverMap.ContainsKey($key)) { $coverMap[$key] = $cf.FullName }
        }
        $cand = @($items | Where-Object { $_.bvid -and $coverMap.ContainsKey([string]$_.bvid) } |
                  Sort-Object -Property @{ Expression = { if ($null -eq $_.progress) { -1 } else { [int64]$_.progress } } })
        [array]::Reverse($cand)
        $picked = @($cand | Select-Object -First $MaxCovers)

        $imgBuf = New-Object System.Text.StringBuilder
        foreach ($cv in $picked) {
            try {
                $path = [string]$coverMap[[string]$cv.bvid]
                $bytes = [System.IO.File]::ReadAllBytes($path)
                if ($bytes.Length -gt 600000) { continue }
                $b64 = [Convert]::ToBase64String($bytes)
                [void]$imgBuf.Append('<img src="data:image/jpeg;base64,' + $b64 + '" alt="">')
            }
            catch { }
        }
        $coverHtml = $imgBuf.ToString()
    }
}

$cardTpl = Join-Path $Root 'share\card.html'
$cardMap = @{
    TITLE     = (Esc ($headline + ' | ' + $periodText))
    PERIOD    = (Esc $periodText)
    HEADLINE  = (Esc $headline)
    LEAD      = (Esc $lead)
    M_HOURS   = $hours
    M_COUNT   = $count
    M_COMP    = $avgComp
    M_DAYS    = $activeDays
    HL_TITLE  = (Esc $hlTitle)
    HL_UP     = (Esc $hlUp)
    HL_META   = (Esc $hlMeta)
    TOPUP_ROWS = $upRows.ToString()
    TAG_ROWS  = $tagRows.ToString()
    COVERS    = $coverHtml
    FOOTER    = (Esc $Lbl.Footer)
    GENERATED = $genText
}

$cardHtml = Fill ([System.IO.File]::ReadAllText($cardTpl, [System.Text.Encoding]::UTF8)) $cardMap

# Drop whole sections that have no data, instead of leaving empty headings.
$dropRules = @(
    @{ Begin = '<!--HIGHLIGHT:BEGIN-->'; End = '<!--HIGHLIGHT:END-->'; Has = ($null -ne $hl) },
    @{ Begin = '<!--TOPUP:BEGIN-->';     End = '<!--TOPUP:END-->';     Has = ($upSorted.Count -gt 0) },
    @{ Begin = '<!--TAGS:BEGIN-->';      End = '<!--TAGS:END-->';      Has = ($tagSorted.Count -gt 0) },
    @{ Begin = '<!--COVERS:BEGIN-->';    End = '<!--COVERS:END-->';    Has = ($coverHtml -ne '') }
)
foreach ($rule in $dropRules) {
    if (-not $rule.Has) {
        $pattern = [regex]::Escape($rule.Begin) + '.*?' + [regex]::Escape($rule.End)
        $cardHtml = [regex]::Replace($cardHtml, $pattern, '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    }
}

# ---------------------------------------------------------------- build post text

$topUpName = '-'
$topUpHours = 0
if ($upSorted.Count -gt 0) {
    $topUpName = [string]$upSorted[0].Key
    $topUpHours = [math]::Round([int64]$upSorted[0].Value.secs / 3600.0, 1)
}
$topTags = '-'
if ($tagSorted.Count -gt 0) {
    $topTags = (@($tagSorted | Select-Object -First 3 | ForEach-Object { [string]$_.Key }) -join ' / ')
}
$hlTitleText = $hlTitle
$hlMin = 0
if ($hl) { $hlMin = [int][math]::Round([int64]$hlProg / 60.0, 0) }

$postTpl = Join-Path $Root 'share\post.txt'
$postMap = @{
    PERIOD      = $periodText
    DAYS        = $dayCount
    HOURS       = $hours
    COUNT       = $count
    COMP        = $avgComp
    TOPUP       = $topUpName
    TOPUP_HOURS = $topUpHours
    TOPTAGS     = $topTags
    HL_TITLE    = $hlTitleText
    HL_MIN      = $hlMin
}
$postText = Fill ([System.IO.File]::ReadAllText($postTpl, [System.Text.Encoding]::UTF8)) $postMap
if ($count -eq 0) { $postText = $Lbl.Empty + "`r`n`r`n" + '(' + $periodText + ')' }

# ---------------------------------------------------------------- write output

# A security product can refuse writes to the data folder when this script is
# launched by the GUI (the launcher must not be granted a trust zone for that).
# Probe the intended folder first; if it is not writable, keep the card inside
# the tool folder, which is the one place that already has to be trusted.
function Test-WritableDir {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
        $probe = Join-Path $Path ('.w-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    }
    catch { return $false }
}

$outDir = $OutRoot
if ($outDir -eq '') {
    $shareRoot = Join-Path $DataRoot (Get-DirName $Cfg 'Share' 'share')
    $outDir = Join-Path $shareRoot $label
}
if (-not (Test-WritableDir $outDir)) {
    $fallback = Join-Path $Root ('out\' + $label)
    Write-Host ('warn: cannot write ' + $outDir + ' (blocked?); using ' + $fallback)
    $outDir = $fallback
    if (-not (Test-WritableDir $outDir)) {
        Write-Host 'ERROR: no writable output folder. A security product is blocking this script.'
        exit 2
    }
}

$written = New-Object System.Collections.ArrayList

if (-not $OnlyPack) {
    $cardPath = Join-Path $outDir 'card.html'
    [System.IO.File]::WriteAllText($cardPath, $cardHtml, $Utf8NoBom)
    [void]$written.Add($cardPath)

    $postPath = Join-Path $outDir 'post.txt'
    [System.IO.File]::WriteAllText($postPath, $postText, $Utf8NoBom)
    [void]$written.Add($postPath)

    if (-not $NoPng) {
        $pngPath = Join-Path $outDir 'card.png'
        if (Save-CardPng -HtmlPath $cardPath -OutPng $pngPath -EdgeExe $EdgeExe) {
            [void](Trim-CardPng -Path $pngPath)
            if ($WmOn) {
                if (-not (Add-CardWatermark -Path $pngPath -Text $WmText)) {
                    Write-Host 'warn: watermark skipped'
                }
            }
            $cardPng = $pngPath
            [void]$written.Add($pngPath)
        }
        else {
            Write-Host 'warn: card.png skipped (Edge not found or headless render failed)'
        }
    }
}

if (-not $OnlyCard) {
    $packDir = Join-Path $outDir 'payload'
    if (-not (Test-Path $packDir)) { New-Item -ItemType Directory -Force -Path $packDir | Out-Null }

    $sbWatch = New-Object System.Text.StringBuilder
    foreach ($it in $items) {
        $t = [string]$it.title
        if ($NoTitles) { $t = $Lbl.RedactedTitle }
        $row = [pscustomobject]@{
            time       = [int64]$it.time
            bvid       = [string]$it.bvid
            aid        = [int64]$it.aid
            title      = $t
            up         = [string]$it.up
            up_mid     = [int64]$it.up_mid
            tag        = [string]$it.tag
            duration   = [int]$it.duration
            progress   = $it.progress
            completion = $it.completion
            completed  = [bool]$it.completed
        }
        [void]$sbWatch.Append((($row | ConvertTo-Json -Compress)) + "`n")
    }
    $watchPath = Join-Path $packDir 'watch.jsonl'
    [System.IO.File]::WriteAllText($watchPath, $sbWatch.ToString(), $Utf8NoBom)
    [void]$written.Add($watchPath)

    if ($IncludeFavorites -and $favItems.Count -gt 0) {
        $sbFav = New-Object System.Text.StringBuilder
        foreach ($fi in $favItems) {
            $t = [string]$fi.title
            if ($NoTitles) { $t = $Lbl.RedactedTitle }
            $row = [pscustomobject]@{
                time     = [int64]$fi.time
                bvid     = [string]$fi.bvid
                aid      = [int64]$fi.aid
                title    = $t
                up       = [string]$fi.up
                up_mid   = [int64]$fi.up_mid
                folder   = [string]$fi.folder
                duration = [int]$fi.duration
                invalid  = [bool]$fi.invalid
            }
            [void]$sbFav.Append((($row | ConvertTo-Json -Compress)) + "`n")
        }
        $favPath = Join-Path $packDir 'favorites.jsonl'
        [System.IO.File]::WriteAllText($favPath, $sbFav.ToString(), $Utf8NoBom)
        [void]$written.Add($favPath)
    }

    $summary = [pscustomobject]@{
        schema    = 1
        generated = $genText
        period    = [pscustomobject]@{ from = $fromStr; to = $toStr; days = $dayCount }
        watch     = [pscustomobject]@{
            count          = $count
            hours          = $hours
            avg_completion = [math]::Round($avgComp / 100.0, 4)
            active_days    = $activeDays
        }
        top_ups   = @($upSorted | ForEach-Object {
                        [pscustomobject]@{
                            up    = [string]$_.Key
                            hours = [math]::Round([int64]$_.Value.secs / 3600.0, 2)
                            count = [int]$_.Value.n
                        }
                    })
        top_tags  = @($tagSorted | ForEach-Object { [pscustomobject]@{ tag = [string]$_.Key; count = [int]$_.Value } })
        favorites = [pscustomobject]@{ count = $favCount; included = [bool]($IncludeFavorites -and $favItems.Count -gt 0) }
        titles_included = (-not $NoTitles)
    }
    $summaryPath = Join-Path $packDir 'summary.json'
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), $Utf8NoBom)
    [void]$written.Add($summaryPath)

    $readmeTpl = Join-Path $Root 'share\pack-readme.md'
    $readmeText = Fill ([System.IO.File]::ReadAllText($readmeTpl, [System.Text.Encoding]::UTF8)) @{
        PERIOD = $periodText
        GENERATED = $genText
    }
    $readmePath = Join-Path $packDir 'README.md'
    [System.IO.File]::WriteAllText($readmePath, $readmeText, $Utf8NoBom)
    [void]$written.Add($readmePath)

    # manifest last, so it covers every other file in the package
    $fileList = @($written | Where-Object { (Split-Path -Parent $_) -eq $packDir } | ForEach-Object {
                    [pscustomobject]@{ name = (Split-Path -Leaf $_); bytes = (Get-Item $_).Length; sha256 = (Get-Sha256 $_) }
                 })
    $manifest = [pscustomobject]@{
        schema    = 1
        generator = 'share.ps1'
        generated = $genText
        period    = $periodText
        files     = $fileList
    }
    $manifestPath = Join-Path $packDir 'manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $Utf8NoBom)
    [void]$written.Add($manifestPath)
}

# ---------------------------------------------------------------- done

Write-Host ('period  : ' + $periodText + '  (' + $dayCount + ' days)')
Write-Host ('watch   : ' + $count + ' rows, ' + $hours + ' h, ' + $avgComp + '% avg completion, ' + $activeDays + ' active days')
if ($IncludeFavorites) { Write-Host ('favorites in period: ' + $favCount) }
Write-Host ('out     : ' + $outDir)
foreach ($w in $written) {
    $size = [math]::Round((Get-Item $w).Length / 1KB, 1)
    Write-Host ('  ' + (Split-Path -Leaf $w) + '  ' + $size + ' KB')
}

# -Open: hand the finished card to the default image viewer, so a tray click
# ends with the picture on screen instead of "go find the folder".
# Open the containing folder with the file selected. Launching the default
# image viewer is a nice-to-have; relying on it is not worth another trust zone.
if ($Open -and $cardPng -and (Test-Path -LiteralPath $cardPng)) {
    try { Start-Process explorer.exe ('/select,"' + $cardPng + '"') | Out-Null }
    catch { Write-Host ('warn: could not open the folder: ' + $_.Exception.Message) }
}

exit 0
