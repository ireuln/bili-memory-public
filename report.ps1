#requires -version 5.1
<#
  Offline report from the local archive. No browser, no network, no AI.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\report.ps1
    ... -File .\report.ps1 -TopN 25
    ... -File .\report.ps1 -OutFile "D:\somewhere\report.md"

  Reads:  <DataRoot>\<History>\*.jsonl, <DataRoot>\<Fav>\<master>
  Writes: <DataRoot>\<Report.Dir>\report-<yyyyMMdd-HHmm>.md
#>
[CmdletBinding()]
param(
    [int]$TopN = 15,
    [string]$OutFile = '',
    [switch]$Json
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
$Cfg = [System.IO.File]::ReadAllText((Join-Path $Root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$DataRoot = [string]$Cfg.DataRoot
$DirHistory = Join-Path $DataRoot $Cfg.Dirs.History
$DirFav = Join-Path $DataRoot $Cfg.Dirs.Fav
$RepDir = Join-Path $DataRoot $(if ($Cfg.Report.Dir) { $Cfg.Report.Dir } else { 'reports' })
if (-not (Test-Path $RepDir)) { New-Item -ItemType Directory -Force -Path $RepDir | Out-Null }

$L = $Cfg.Report.Labels
function T { param([string]$Key, [string]$Fallback) if ($L -and $L.PSObject.Properties[$Key]) { return [string]$L.PSObject.Properties[$Key].Value } return $Fallback }
# config.example.json ships without a "Report" section, so $Cfg.Report can be
# $null on a fresh install; indexing into it threw "Cannot index into a null
# array" the first time a new user asked for a report.
function Title { param([string]$Key, [string]$Fallback) if ($Cfg.Report -and $Cfg.Report.PSObject.Properties[$Key]) { return [string]$Cfg.Report.PSObject.Properties[$Key].Value } return $Fallback }
function Epoch2Local { param($E) return [DateTimeOffset]::FromUnixTimeSeconds([int64]$E).ToLocalTime() }

# ---- load ---------------------------------------------------------------
$hist = @()
# The watch-later file lives in the same folder but is NOT watch history: its
# rows have no view_at. Counting them inflated the total by ~11% and added a
# bogus 1970-01-01 active day.
$LaterFile = if ($Cfg.Text -and $Cfg.Text.watchLaterFile) { [string]$Cfg.Text.watchLaterFile } else { 'watch-later.jsonl' }
foreach ($f in Get-ChildItem $DirHistory -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
    if ($f.Name -eq $LaterFile) { continue }
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $hrec = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $hrec.view_at) { continue }
        $hist += $hrec
    }
}
$favs = @()
$masterPath = Join-Path $DirFav $(if ($Cfg.Text.masterFile) { $Cfg.Text.masterFile } else { 'favorites-master.jsonl' })
if (Test-Path $masterPath) {
    foreach ($line in [System.IO.File]::ReadLines($masterPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $favs += ($line | ConvertFrom-Json) } catch { }
    }
}

$sb = New-Object System.Text.StringBuilder
function W { param([string]$Line) [void]$sb.AppendLine($Line) }

$stamp = Get-Date
W ('# ' + (Title 'Title' 'Bilibili report'))
W ''
W ('> ' + (T 'generated' 'generated') + ': ' + $stamp.ToString('yyyy-MM-dd HH:mm'))
W ''

$watchedHours = 0
$avgCompValue = 0
$activeDaysValue = 0

if ($hist.Count -eq 0) {
    W ((T 'empty' 'no data'))
} else {
    # ---- watch overview -------------------------------------------------
    $minT = ($hist | Measure-Object view_at -Minimum).Minimum
    $maxT = ($hist | Measure-Object view_at -Maximum).Maximum
    $span = (Epoch2Local $maxT) - (Epoch2Local $minT)
    $activeDays = @($hist | ForEach-Object { (Epoch2Local $_.view_at).ToString('yyyy-MM-dd') } | Sort-Object -Unique).Count
    if ($activeDays -lt 1) { $activeDays = 1 }
    $days = [Math]::Max(1, [Math]::Ceiling($span.TotalDays))
    $valid = @($hist | Where-Object { $_.progress -ne $null -and $_.progress -gt 0 -and $_.duration -gt 0 })
    $watchedSec = (($valid | Measure-Object progress -Sum).Sum)
    if (-not $watchedSec) { $watchedSec = 0 }
    $avgComp = 0
    if ($valid.Count -gt 0) {
        $avgComp = ($valid | ForEach-Object { [Math]::Min(1.0, [double]$_.progress / [double]$_.duration) } | Measure-Object -Average).Average
    }

    $watchedHours = [math]::Round($watchedSec / 3600, 2)
    $avgCompValue = [math]::Round($avgComp, 4)
    $activeDaysValue = $activeDays
    W ('## ' + (T 'overview' 'overview'))
    W ''
    W ('| ' + (T 'records' 'records') + ' | ' + (T 'range' 'range') + ' | ' + (T 'activeDays' 'active days') + ' | ' + (T 'perDay' 'per day') + ' | ' + (T 'watched' 'watched') + ' | ' + (T 'avgCompletion' 'completion') + ' |')
    W '|---|---|---|---|---|---|'
    W ('| {0} | {1} ~ {2} | {3} | {4:N0} | {5:N1} {6} | {7:P0} |' -f `
        $hist.Count, (Epoch2Local $minT).ToString('yyyy-MM-dd'), (Epoch2Local $maxT).ToString('yyyy-MM-dd'), `
        $activeDays, ($hist.Count / $activeDays), ($watchedSec / 3600), (T 'hour' 'h'), $avgComp)
    W ''

    # ---- per day --------------------------------------------------------
    W ('## ' + (T 'byDay' 'by day'))
    W ''
    W ('| ' + (T 'day' 'date') + ' | ' + (T 'count' 'count') + ' | ' + (T 'watched' 'watched') + ' |')
    W '|---|---|---|'
    $cut = (Epoch2Local $maxT).Date.AddDays(-30)
    $byDay = $hist | Where-Object { (Epoch2Local $_.view_at).Date -ge $cut } |
             Group-Object { (Epoch2Local $_.view_at).ToString('yyyy-MM-dd') } |
             Sort-Object Name -Descending | Select-Object -First 14
    foreach ($g in $byDay) {
        $sec = (($g.Group | Where-Object { $_.progress -gt 0 } | Measure-Object progress -Sum).Sum)
        if (-not $sec) { $sec = 0 }
        W ('| {0} | {1} | {2:N1} {3} |' -f $g.Name, $g.Count, ($sec / 3600), (T 'hour' 'h'))
    }
    W ''

    # ---- tags / authors -------------------------------------------------
    W ('## ' + (T 'byTag' 'by tag'))
    W ''
    W ('| ' + (T 'colTag' 'tag') + ' | ' + (T 'count' 'count') + ' |')
    W '|---|---|'
    foreach ($g in ($hist | Group-Object tag | Sort-Object Count -Descending | Select-Object -First $TopN)) {
        W ('| {0} | {1} |' -f $g.Name, $g.Count)
    }
    W ''

    W ('## ' + (T 'byAuthor' 'top uploaders'))
    W ''
    W ('| ' + (T 'colAuthor' 'uploader') + ' | ' + (T 'count' 'count') + ' |')
    W '|---|---|'
    foreach ($g in ($hist | Group-Object author | Sort-Object Count -Descending | Select-Object -First $TopN)) {
        W ('| {0} | {1} |' -f $g.Name, $g.Count)
    }
    W ''

    # ---- completion buckets --------------------------------------------
    W ('## ' + (T 'completion' 'completion'))
    W ''
    W ('| ' + (T 'completion' 'bucket') + ' | ' + (T 'count' 'count') + ' |')
    W '|---|---|'
    $b1 = @($valid | Where-Object { $_.progress / $_.duration -lt 0.1 }).Count
    $b2 = @($valid | Where-Object { $_.progress / $_.duration -ge 0.1 -and $_.progress / $_.duration -lt 0.5 }).Count
    $b3 = @($valid | Where-Object { $_.progress / $_.duration -ge 0.5 -and $_.progress / $_.duration -lt 0.9 }).Count
    $b4 = @($valid | Where-Object { $_.progress / $_.duration -ge 0.9 }).Count
    W ('| <10% | {0} |' -f $b1)
    W ('| 10-50% | {0} |' -f $b2)
    W ('| 50-90% | {0} |' -f $b3)
    W ('| >=90% | {0} |' -f $b4)
    W ''
}

# ---- favorites ----------------------------------------------------------
if ($favs.Count -gt 0) {
    $inv = @($favs | Where-Object { $_.invalid })
    $rate = [double]$inv.Count / [double]$favs.Count
    W ('## ' + (T 'favs' 'favorites'))
    W ''
    W ('| ' + (T 'favTotal' 'total') + ' | ' + (T 'favInvalid' 'invalid') + ' | ' + (T 'invalidRate' 'rate') + ' |')
    W '|---|---|---|'
    W ('| {0} | {1} | {2:P1} |' -f $favs.Count, $inv.Count, $rate)
    W ''

    W ('### ' + (T 'favByFolder' 'by folder'))
    W ''
    W ('| folder | ' + (T 'count' 'count') + ' |') 
    W '|---|---|'
    foreach ($g in ($favs | Group-Object folder | Sort-Object Count -Descending)) {
        W ('| {0} | {1} |' -f $g.Name, $g.Count)
    }
    W ''

    W ('### ' + (T 'favByYear' 'by year'))
    W ''
    W ('| year | ' + (T 'count' 'count') + ' |')
    W '|---|---|'
    foreach ($g in ($favs | Where-Object { $_.fav_time -gt 0 } | Group-Object { (Epoch2Local $_.fav_time).Year } | Sort-Object Name)) {
        W ('| {0} | {1} |' -f $g.Name, $g.Count)
    }
    W ''

    if ($inv.Count -gt 0) {
        # The heading shows the real total; the table below is capped at $TopN.
        W ('### ' + (T 'invalidList' 'invalid list') + ' (' + $inv.Count + ', showing ' + [math]::Min($TopN, $inv.Count) + ')')
        W ''
        W ('| title | uploader | ' + (T 'linkText' 'link') + ' |')
        W '|---|---|---|'
        foreach ($r in ($inv | Select-Object -First $TopN)) {
            $t = ([string]$r.title) -replace '\|', '\|'
            $u = ([string]$r.upper) -replace '\|', '\|'
            W ('| {0} | {1} | {2} |' -f $t, $u, $r.bvid)
        }
        W ''
    }
}

if (-not $OutFile) { $OutFile = Join-Path $RepDir ('report-' + $stamp.ToString('yyyyMMdd-HHmm') + '.md') }
$outParent = Split-Path -Parent $OutFile
if ($outParent -and -not (Test-Path $outParent)) { New-Item -ItemType Directory -Force -Path $outParent | Out-Null }
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

if ($Json) {
    $summary = [ordered]@{
        schema        = 1
        generated     = $stamp.ToString('o')
        report_file   = $OutFile
        history_rows  = $hist.Count
        favorite_rows = $favs.Count
        invalid_favs  = @($favs | Where-Object { $_.invalid }).Count
        watched_hours = $watchedHours
        avg_completion= $avgCompValue
        active_days   = $activeDaysValue
    }
    $summary | ConvertTo-Json -Depth 4
} else {
    Write-Host ('report: ' + $OutFile)
    Write-Host ('  history rows: ' + $hist.Count + '  favorites: ' + $favs.Count)
}
exit 0
