#requires -version 5.1
<#
  settings-server.ps1 - a tiny loopback-only HTTP server behind the tray
  "Features & settings" entry.

    GET  /                settings.html
    GET  /api/config      { schema, config }              (fast, no cache)
    GET  /api/tasks       { tasks }                       (5 s cache)
    GET  /api/history     { days }                        (60 s cache)
    POST /api/save        { key, value } -> save one item
    POST /api/apply       re-register scheduled tasks from config.json

  Design rules:
    - binds 127.0.0.1 only, random port, one-shot token in the URL
    - no external requests, no credentials, reads/writes config.json only
    - exits on its own after IdleMinutes without a request
    - saved items are validated against settings.schema.json before writing
    - ASCII-only on purpose: Windows PowerShell 5.1 decodes BOM-less .ps1 as
      GBK, one non-ASCII byte here would break parsing. User-facing text lives
      in settings.html / settings.schema.json / config.json.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\settings-server.ps1
    ... -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [int]$IdleMinutes = 30,
    [switch]$NoBrowser,
    [string]$Section = ''
)

$ErrorActionPreference = 'Stop'
try {
    $script:OutEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $script:OutEncoding
    $OutputEncoding = $script:OutEncoding
} catch { }

$Root = Split-Path -Parent $PSCommandPath
$CfgFile = Join-Path $Root 'config.json'
$SchemaFile = Join-Path $Root 'settings.schema.json'
$HtmlFile = Join-Path $Root 'settings.html'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($f in @($CfgFile, $SchemaFile, $HtmlFile)) {
    if (-not (Test-Path $f)) { Write-Host ('missing: ' + $f); exit 2 }
}

function Read-JsonFile {
    param([string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}
function Write-JsonFile {
    param([string]$Path, $Obj)
    [System.IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 12), $Utf8)
}
function Get-Prop {
    param($Obj, [string]$Path)
    $cur = $Obj
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$seg]
        if (-not $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}
function Set-Prop {
    param($Obj, [string]$Path, $Value)
    $segs = $Path.Split('.')
    $cur = $Obj
    for ($i = 0; $i -lt $segs.Length - 1; $i++) {
        $seg = $segs[$i]
        $next = $null
        if ($cur.PSObject.Properties[$seg]) { $next = $cur.$seg }
        if ($null -eq $next) {
            $next = New-Object psobject
            $cur | Add-Member -NotePropertyName $seg -NotePropertyValue $next -Force
        }
        $cur = $next
    }
    $last = $segs[-1]
    if ($cur.PSObject.Properties[$last]) { $cur.$last = $Value }
    else { $cur | Add-Member -NotePropertyName $last -NotePropertyValue $Value -Force }
}

$Cfg = Read-JsonFile $CfgFile
if (-not $Cfg -or -not $Cfg.DataRoot) { Write-Host 'config.json has no DataRoot'; exit 2 }
$DataRoot = [string]$Cfg.DataRoot
$LogDir = Join-Path $DataRoot ([string]$Cfg.Dirs.Log)
$MasterFile = '收藏总表.jsonl'
if ($Cfg.Text -and $Cfg.Text.masterFile) { $MasterFile = [string]$Cfg.Text.masterFile }
$DirFav = Join-Path $DataRoot ([string]$Cfg.Dirs.Fav)
$CoverDir = Join-Path $DataRoot ([string]$Cfg.Dirs.Cover)
$HdCoverDir = Join-Path $DataRoot $(if ($Cfg.Dirs.HdCover) { [string]$Cfg.Dirs.HdCover } else { 'covers-hd' })
$ShareDir = Join-Path $DataRoot $(if ($Cfg.Dirs.Share) { [string]$Cfg.Dirs.Share } else { 'share' })
$DirDetail = Join-Path $DataRoot $(if ($Cfg.Dirs.Detail) { [string]$Cfg.Dirs.Detail } else { 'details' })
$DetailFile = Join-Path $DirDetail 'details.jsonl'

$Schema = Read-JsonFile $SchemaFile
$SchemaItems = @{}
foreach ($sec in @($Schema.sections)) {
    foreach ($g in @($sec.groups)) {
        foreach ($it in @($g.items)) {
            if ($it.key) { $SchemaItems[[string]$it.key] = $it }
        }
    }
}

$TaskDefs = @(
    @{ name = 'DSH-BiliHistory';  label = 'History';       mode = 'history'; key = 'Automation.History' }
    @{ name = 'DSH-BiliDynamic';  label = 'Dynamic';       mode = 'dynamic'; key = 'Automation.Dynamic' }
    @{ name = 'DSH-BiliFavQuick'; label = 'FavQuick';      mode = 'favq';    key = 'Automation.FavQuick' }
    @{ name = 'DSH-BiliBackup';   label = 'Backup';        mode = 'backup';  key = 'Automation.Backup' }
)

$script:Cache = @{ tasks = $null; tasksAt = [datetime]::MinValue; history = $null; historyAt = [datetime]::MinValue; deleted = $null; deletedAt = [datetime]::MinValue; deletedKey = ''; covers = $null; coversAt = [datetime]::MinValue; watch = $null; watchAt = [datetime]::MinValue }

function Read-LinesShared {
    param([string]$Path)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    try {
        while ($null -ne ($line = $sr.ReadLine())) { $line }
    } finally {
        $sr.Dispose()
        $fs.Dispose()
    }
}

function Get-DeletedItems {
    # Favourites that the collection run has confirmed as gone: the master table
    # keeps invalid = true plus invalid_since, so "recently deleted" is a sort.
    # Days = 0 means all time; the window filters on invalid_since.
    param([int]$Days = 30, [int]$Limit = 300)
    $master = Join-Path $DirFav $MasterFile
    if (-not (Test-Path $master)) { return [pscustomobject]@{ total = 0; unknown = 0; items = @(); days = $Days } }
    $cutoff = ''
    $isAll = ($Days -le 0)
    if (-not $isAll) { $cutoff = (Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd HH:mm:ss') }
    # Detail snapshots carry the tag names fetched while the video was still up.
    # Joining them here is free and keeps the deleted list informative.
    $detailMap = @{}
    if (Test-Path $DetailFile) {
        foreach ($line in (Read-LinesShared $DetailFile)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $d = $null
            try { $d = $line | ConvertFrom-Json } catch { continue }
            if ($d.bvid) { $detailMap[[string]$d.bvid] = $d }
        }
    }
    $items = New-Object System.Collections.ArrayList
    $total = 0
    $unknown = 0
    foreach ($line in (Read-LinesShared $master)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.invalid -ne $true) { continue }
        $since = [string]$o.invalid_since
        # invalid_known is written by the collector when the item turned dead
        # between two nearby scans. Old rows have no field: their removal time
        # is genuinely unknown, so they never count as "recently deleted".
        $known = ($o.invalid_known -eq $true)
        if (-not $known) {
            $unknown++
            if (-not $isAll) { continue }
        } elseif ($cutoff -and (-not $since -or $since -lt $cutoff)) {
            continue
        }
        $total++
        if ($items.Count -ge $Limit) { continue }
        $bvid = [string]$o.bvid
        $tagsVal = @()
        if ($bvid -and $detailMap.ContainsKey($bvid)) {
            $dt = $detailMap[$bvid]
            if ($dt.PSObject.Properties['tags']) {
                $tagsVal = @($dt.tags | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
        }
        $folderId = [string]$o.folder_id
        $coverRel = ''
        $cands = @((Join-Path $CoverDir ($bvid + '.jpg')))
        if ($folderId) { $cands = @((Join-Path $CoverDir (Join-Path $folderId ($bvid + '.jpg'))), (Join-Path $CoverDir ($bvid + '.jpg'))) }
        foreach ($cand in $cands) {
            if (Test-Path -LiteralPath $cand) {
                if ($folderId) { $coverRel = '/cover/' + $folderId + '/' + $bvid + '.jpg' }
                else { $coverRel = '/cover/' + $bvid + '.jpg' }
                break
            }
        }
        [void]$items.Add([pscustomobject]@{
            bvid         = $bvid
            title        = [string]$o.title
            up           = [string]$o.upper
            upperMid     = $(if ($null -ne $o.upper_mid) { [int64]$o.upper_mid } else { [int64]0 })
            folder       = [string]$o.folder
            invalidSince = $since
            favTime      = $(if ($null -ne $o.fav_time) { [int64]$o.fav_time } else { [int64]0 })
            play         = $(if ($null -ne $o.play) { [int64]$o.play } else { [int64]0 })
            danmaku      = $(if ($null -ne $o.danmaku) { [int64]$o.danmaku } else { [int64]0 })
            favCount     = $(if ($null -ne $o.fav_count) { [int64]$o.fav_count } else { [int64]0 })
            duration     = $(if ($null -ne $o.duration) { [int64]$o.duration } else { [int64]0 })
            cover        = $coverRel
            tags         = $tagsVal
            known        = $known
        })
    }
    $sorted = @($items | Sort-Object { $_.invalidSince } -Descending)
    return [pscustomobject]@{ total = $total; unknown = $unknown; items = $sorted; days = $Days }
}

function Get-DeletedItemsCached {
    param([int]$Days = 30)
    $key = [string]$Days
    if ($script:Cache.deleted -and $script:Cache.deletedKey -eq $key -and ((Get-Date) - $script:Cache.deletedAt).TotalSeconds -lt 60) { return $script:Cache.deleted }
    $script:Cache.deleted = Get-DeletedItems -Days $Days -Limit 300
    $script:Cache.deletedKey = $key
    $script:Cache.deletedAt = Get-Date
    return $script:Cache.deleted
}

function Get-TaskStates {
    $out = @()
    foreach ($t in $TaskDefs) {
        $st = Get-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue
        $info = $null
        if ($st) { $info = Get-ScheduledTaskInfo -TaskName $t.name -ErrorAction SilentlyContinue }
        $last = ''
        $next = ''
        $result = $null
        if ($info) {
            if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $last = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') }
            if ($info.NextRunTime -and $info.NextRunTime.Year -gt 1999) { $next = $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') }
            $result = $info.LastTaskResult
        }
        $out += [pscustomobject]@{
            name       = $t.name
            label      = $t.label
            mode       = $t.mode
            key        = $t.key
            installed  = [bool]$st
            state      = $(if ($st) { [string]$st.State } else { 'missing' })
            lastRun    = $last
            lastResult = $result
            nextRun    = $next
            enabled    = ((Get-Prop $Cfg $t.key) -eq 'scheduled')
        }
    }
    $out
}
function Get-TaskStatesCached {
    if ($script:Cache.tasks -and ((Get-Date) - $script:Cache.tasksAt).TotalSeconds -lt 5) { return $script:Cache.tasks }
    $script:Cache.tasks = @(Get-TaskStates)
    $script:Cache.tasksAt = Get-Date
    return $script:Cache.tasks
}

function Get-DailyHistory {
    param([int]$Days = 30)
    if (-not (Test-Path $LogDir)) { return @() }
    $cut = (Get-Date).Date.AddDays(-$Days)
    $byDay = @{}
    foreach ($f in @(Get-ChildItem $LogDir -File -Filter 'collect-*.log' -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch '^collect-(\d{8})-') { continue }
        try { $d = [datetime]::ParseExact($matches[1], 'yyyyMMdd', $null) } catch { continue }
        if ($d -lt $cut) { continue }
        $key = $d.ToString('yyyy-MM-dd')
        if (-not $byDay.ContainsKey($key)) {
            $byDay[$key] = [pscustomobject]@{ date = $key; runs = 0; ok = 0; fail = 0; added = 0 }
        }
        $txt = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $byDay[$key].runs++
        if ($txt -match '=== (done|fav done|dynamic done)') { $byDay[$key].ok++ }
        elseif ($txt -match '\[ERROR\]|\[FATAL\]') { $byDay[$key].fail++ }
        foreach ($m in [regex]::Matches($txt, 'appended (\d+) record')) { $byDay[$key].added += [int]$m.Groups[1].Value }
        foreach ($m in [regex]::Matches($txt, 'master written: \d+ favorite\(s\) total, (\d+) new')) { $byDay[$key].added += [int]$m.Groups[1].Value }
    }
    @($byDay.Values | Sort-Object date -Descending)
}
function Get-DailyHistoryCached {
    if ($script:Cache.history -and ((Get-Date) - $script:Cache.historyAt).TotalSeconds -lt 60) { return $script:Cache.history }
    $script:Cache.history = @(Get-DailyHistory 30)
    $script:Cache.historyAt = Get-Date
    return $script:Cache.history
}

function Get-FavFolderRows {
    # order=api re-sorts by Bilibili's own folder order (folder-order.json),
    # ignoring the drag plan; the default keeps the plan first.
    param([string]$Order = 'plan')
    # The folder list lives in the archive, not in config.json: every
    # <folder>.md header carries "# <real name>" plus a summary line with the
    # item/invalid counts. The plan (order + level) comes from config.
    $rows = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $DirFav)) { return @() }
    # ASCII-only file: build the two CJK summary labels from code points so
    # Windows PowerShell 5.1 (GBK decoding for BOM-less scripts) stays happy.
    $reItems = ([string][char]0x6761 + [char]0x76EE) + '[\uFF1A:]\s*(\d+)'
    $reInvalid = ([string][char]0x5931 + [char]0x6548) + '[\uFF1A:]\s*(\d+)'
    $plan = @()
    if ($Cfg.PSObject.Properties['FavFolderPlan'] -and $Cfg.FavFolderPlan) { $plan = @($Cfg.FavFolderPlan) }
    $files = @(Get-ChildItem -LiteralPath $DirFav -Filter '*.md' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $name = ''
        $count = 0
        $invalid = 0
        try {
            $head = @([System.IO.File]::ReadLines($f.FullName, [System.Text.Encoding]::UTF8) | Select-Object -First 6)
            foreach ($ln in $head) {
                if (-not $name -and $ln -match '^#\s+(.+)$') { $name = $Matches[1].Trim() }
                if ($ln -match $reItems) { $count = [int]$Matches[1] }
                if ($ln -match $reInvalid) { $invalid = [int]$Matches[1] }
            }
        } catch { }
        if (-not $name) { $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
        [void]$rows.Add([pscustomobject]@{ name = $name; count = $count; invalid = $invalid })
    }
    # Order: plan entries first, then the API order the collector saved (the
    # user's own folder order), then the rest by count.
    $apiOrder = @()
    $orderPath = Join-Path $DirFav 'folder-order.json'
    if (Test-Path -LiteralPath $orderPath) {
        try {
            # PS 5.1: piping ReadAllText into ConvertFrom-Json keeps a top-level
            # JSON array as one object, so enumerate the parsed value directly.
            $txt = [System.IO.File]::ReadAllText($orderPath, [System.Text.Encoding]::UTF8)
            foreach ($n in (ConvertFrom-Json -InputObject $txt)) { if ($n) { $apiOrder += [string]$n } }
        } catch { }
    }
    $ordered = New-Object System.Collections.ArrayList
    $added = @{}
    if ($Order -ne 'api') {
        foreach ($e in $plan) {
            $n = [string]$e.name
            if (-not $n) { continue }
            $hit = @($rows | Where-Object { $_.name -eq $n }) | Select-Object -First 1
            if ($hit) { [void]$ordered.Add($hit); $added[$n] = $true }
        }
    }
    foreach ($n in @($apiOrder)) {
        $nm = [string]$n
        if (-not $nm -or $added.ContainsKey($nm)) { continue }
        $hit = @($rows | Where-Object { $_.name -eq $nm }) | Select-Object -First 1
        if ($hit) { [void]$ordered.Add($hit); $added[$nm] = $true }
    }
    foreach ($r in @($rows | Sort-Object -Property @{ Expression = { $_.count }; Descending = $true })) {
        if (-not $added.ContainsKey([string]$r.name)) { [void]$ordered.Add($r); $added[[string]$r.name] = $true }
    }
    $out = @()
    foreach ($r in $ordered) {
        $lv = 'full'
        $pe = @($plan | Where-Object { [string]$_.name -eq $r.name }) | Select-Object -First 1
        if ($pe -and ([string]$pe.level -in @('full', 'daily', 'skip'))) { $lv = [string]$pe.level }
        $out += [pscustomobject]@{ name = $r.name; count = $r.count; invalid = $r.invalid; level = $lv }
    }
    return $out
}

function Test-SettingValue {
    param([string]$Key, $Val)
    $item = $SchemaItems[$Key]
    if (-not $item) { return 'unknown setting' }
    switch ([string]$item.type) {
        'automation' {
            if ($Val -notin @('scheduled', 'manual')) { return 'must be scheduled or manual' }
        }
        'bool' {
            if ($Val -isnot [bool]) { return 'must be true or false' }
        }
        'int' {
            $n = 0L
            if (-not [long]::TryParse([string]$Val, [ref]$n)) { return 'must be a number' }
            if ($null -ne $item.min -and $n -lt [long]$item.min) { return ('minimum is ' + $item.min) }
            if ($null -ne $item.max -and $n -gt [long]$item.max) { return ('maximum is ' + $item.max) }
        }
        'enum' {
            if ($Val -notin @($item.values)) { return ('must be one of: ' + (($item.values) -join ', ')) }
        }
        'time' {
            if ($Val -isnot [string] -or $Val -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { return 'must be HH:mm (00:00-23:59)' }
        }
        'text' {
            if ($Val -isnot [string]) { return 'must be a string' }
            if ($Val.Length -gt 500) { return 'too long (max 500)' }
        }
        'list' {
            if ($Val -isnot [string]) { return 'must be a comma-separated string' }
            if ($Val.Length -gt 2000) { return 'too long (max 2000)' }
        }
        default { return 'unsupported type' }
    }
    return ''
}
function Convert-ForStore {
    param([string]$Key, $Val)
    $item = $SchemaItems[$Key]
    switch ([string]$item.type) {
        'int' { return [long]$Val }
        'list' {
            $parts = @($Val.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            return $parts
        }
        default { return $Val }
    }
}

function Get-CoversStatus {
    $hdName = 'covers-hd'
    if ($Cfg.Dirs.PSObject.Properties['HdCover'] -and $Cfg.Dirs.HdCover) { $hdName = [string]$Cfg.Dirs.HdCover }
    $hd = Join-Path $DataRoot $hdName
    $have = 0; $bytes = [int64]0
    if (Test-Path $hd) {
        $items = @(Get-ChildItem $hd -Recurse -File -ErrorAction SilentlyContinue)
        $have = $items.Count
        $bytes = [int64](($items | Measure-Object Length -Sum).Sum)
    }
    $total = 0
    $master = Join-Path $DirFav $MasterFile
    if (Test-Path $master) {
        $fs = New-Object System.IO.FileStream($master, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try { while ($null -ne $sr.ReadLine()) { $total++ } } finally { $sr.Dispose(); $fs.Dispose() }
    }
    $folders = @()
    foreach ($r in @(Get-FavFolderRows)) { $folders += [string]$r.name }
    # Latest saved HD covers, so the settings page can show a preview wall.
    $recent = @()
    if (Test-Path $hd) {
        $files = @(Get-ChildItem $hd -Recurse -File -Filter '*.jpg' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 24)
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($hd.Length).TrimStart('\', '/') -replace '\\', '/'
            $recent += [pscustomobject]@{
                bvid  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                url   = '/hd-cover/' + $rel
                bytes = [int64]$f.Length
                at    = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            }
        }
    }
    return [pscustomobject]@{ total = $total; have = $have; bytes = $bytes; folders = @($folders); recent = @($recent) }
}
function Get-CoversStatusCached {
    $now = Get-Date
    if ($script:Cache.covers -and (($now - $script:Cache.coversAt).TotalSeconds -lt 30)) { return $script:Cache.covers }
    $v = Get-CoversStatus
    $script:Cache.covers = $v
    $script:Cache.coversAt = $now
    return $v
}

function Get-WatchStates {
    $name = '评论监控'
    if ($Cfg.Dirs.PSObject.Properties['Watch'] -and $Cfg.Dirs.Watch) { $name = [string]$Cfg.Dirs.Watch }
    $dir = Join-Path $DataRoot $name
    $items = New-Object System.Collections.ArrayList
    if (Test-Path $dir) {
        foreach ($f in @(Get-ChildItem $dir -Recurse -Filter 'state.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $st = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                # Recently vanished comments with their text, for the watch page.
                # The events file is the source of truth; state.json only keeps
                # counters, so the body has to come from events.jsonl.
                $gone = New-Object System.Collections.ArrayList
                $ev = Join-Path $f.DirectoryName 'events.jsonl'
                if (Test-Path $ev) {
                    $lines = @(Get-Content $ev -Encoding UTF8 -Tail 400 -ErrorAction SilentlyContinue)
                    foreach ($ln in $lines) {
                        if ($ln -notmatch '"kind"\s*:\s*"(confirmed|suspect-gone)"') { continue }
                        try {
                            $o = $ln | ConvertFrom-Json
                            [void]$gone.Add([pscustomobject]@{ ts = [string]$o.ts; kind = [string]$o.kind; uname = [string]$o.uname; msg = [string]$o.msg; rpid = [string]$o.rpid })
                        } catch { }
                    }
                }
                $last = @($gone)
                if ($last.Count -gt 10) { $last = @($last[($last.Count - 10)..($last.Count - 1)]) }
                $st | Add-Member -NotePropertyName goneItems -NotePropertyValue $last -Force
                [void]$items.Add($st)
            } catch { }
        }
    }
    return @($items)
}
function Get-WatchStatesCached {
    $now = Get-Date
    if ($null -ne $script:Cache.watch -and (($now - $script:Cache.watchAt).TotalSeconds -lt 5)) { return $script:Cache.watch }
    $v = @(Get-WatchStates)
    $script:Cache.watch = $v
    $script:Cache.watchAt = $now
    return $v
}

function Invoke-ApplyTasks {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = Join-Path $Root 'register-task.ps1'
    & $ps -NoProfile -ExecutionPolicy Bypass -File $runner -Yes 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Send-Binary {
    param($Stream, [string]$Type, [byte[]]$Bytes)
    $head = 'HTTP/1.1 200 OK' + "`r`n" +
            'Content-Type: ' + $Type + "`r`n" +
            'Content-Length: ' + $Bytes.Length + "`r`n" +
            'Connection: close' + "`r`n" +
            'Cache-Control: max-age=3600' + "`r`n" + "`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush()
}

function Send-Response {
    param($Stream, [int]$Code, [string]$Type, [string]$Body)
    $bytes = $Utf8.GetBytes($Body)
    $head = 'HTTP/1.1 ' + $Code + ' OK' + "`r`n" +
            'Content-Type: ' + $Type + '; charset=utf-8' + "`r`n" +
            'Content-Length: ' + $bytes.Length + "`r`n" +
            'Connection: close' + "`r`n" +
            'Cache-Control: no-store' + "`r`n" + "`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
    $Stream.Flush()
}

# ------------------------------------------------------------------ server --
$token = [guid]::NewGuid().ToString('N')
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = 'http://127.0.0.1:' + $actualPort + '/?t=' + $token
if ($Section) { $url = $url + '#' + $Section }

$stateFile = Join-Path $Root 'settings-server.json'
[pscustomobject]@{
    pid   = $PID
    port  = $actualPort
    token = $token
    url   = $url
    started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
} | ConvertTo-Json -Depth 3 | ForEach-Object { [System.IO.File]::WriteAllText($stateFile, $_, $Utf8) }

Write-Host ('settings server: ' + $url)
if (-not $NoBrowser) {
    try { Start-Process $url } catch { Write-Host ('could not open browser: ' + $_.Exception.Message) }
}

$idleSeconds = [Math]::Max(1, $IdleMinutes) * 60
$lastHit = Get-Date

try {
    while (((Get-Date) - $lastHit).TotalSeconds -lt $idleSeconds) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 10000
        $stream = $client.GetStream()
        try {
            # Read the request as raw bytes. Headers are ASCII, but the JSON body
            # can contain non-ASCII text (favourite names, watermark), so the
            # body must be decoded as UTF-8, not with the header reader.
            $buffer = New-Object System.IO.MemoryStream
            $tmp = New-Object byte[] 8192
            $headerEnd = -1
            while ($headerEnd -lt 0) {
                $n = $stream.Read($tmp, 0, $tmp.Length)
                if ($n -le 0) { break }
                $buffer.Write($tmp, 0, $n)
                $arr = $buffer.ToArray()
                for ($bi = 0; $bi -le $arr.Length - 4; $bi++) {
                    if ($arr[$bi] -eq 13 -and $arr[$bi + 1] -eq 10 -and $arr[$bi + 2] -eq 13 -and $arr[$bi + 3] -eq 10) { $headerEnd = $bi; break }
                }
            }
            if ($headerEnd -lt 0) { $client.Close(); continue }
            $arr = $buffer.ToArray()
            $headText = [System.Text.Encoding]::ASCII.GetString($arr, 0, $headerEnd)
            $headLines = $headText -split "`r`n"
            $requestLine = $headLines[0]
            $headers = @{}
            foreach ($hl in ($headLines | Select-Object -Skip 1)) {
                if (-not $hl) { continue }
                $ci = $hl.IndexOf(':')
                if ($ci -gt 0) { $headers[$hl.Substring(0, $ci).Trim().ToLowerInvariant()] = $hl.Substring($ci + 1).Trim() }
            }
            $bodyStart = $headerEnd + 4
            $need = 0
            if ($headers.ContainsKey('content-length')) { $need = [int]$headers['content-length'] }
            $bodyLen = [Math]::Max(0, $arr.Length - $bodyStart)
            while ($bodyLen -lt $need) {
                $want = [Math]::Min($tmp.Length, $need - $bodyLen)
                $n = $stream.Read($tmp, 0, $want)
                if ($n -le 0) { break }
                $buffer.Write($tmp, 0, $n)
                $bodyLen += $n
            }
            $body = ''
            if ($bodyLen -gt 0) {
                $arr = $buffer.ToArray()
                $body = [System.Text.Encoding]::UTF8.GetString($arr, $bodyStart, $bodyLen)
            }

            $parts = $requestLine.Split(' ')
            $method = if ($parts.Length -ge 1) { $parts[0].ToUpperInvariant() } else { 'GET' }
            $target = if ($parts.Length -ge 2) { $parts[1] } else { '/' }
            $path = $target
            $qs = ''
            $queryToken = ''
            $q = $target.IndexOf('?')
            if ($q -ge 0) {
                $path = $target.Substring(0, $q)
                $qs = $target.Substring($q + 1)
                foreach ($kv in $qs.Split('&')) {
                    if ($kv -match '^t=(.+)$') { $queryToken = [uri]::UnescapeDataString($matches[1]) }
                }
            }
            $reqToken = $queryToken
            if (-not $reqToken -and $headers.ContainsKey('x-token')) { $reqToken = $headers['x-token'] }
            if ($reqToken -ne $token) {
                Send-Response $stream 403 'text/plain' 'forbidden'
                $client.Close()
                continue
            }
            $lastHit = Get-Date

            if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                Send-Response $stream 200 'text/html' ([System.IO.File]::ReadAllText($HtmlFile, [System.Text.Encoding]::UTF8))
            }
            elseif ($method -eq 'GET' -and $path -match '^/cover/(?:([A-Za-z0-9_-]+)/)?([A-Za-z0-9_-]+)\.(jpg|png)$') {
                $sub = $matches[1]
                $fname = $matches[2] + '.' + $matches[3]
                $file = Join-Path $CoverDir $fname
                if ($sub) { $file = Join-Path (Join-Path $CoverDir $sub) $fname }
                if (Test-Path -LiteralPath $file) {
                    $ctype = 'image/jpeg'
                    if ($matches[3] -eq 'png') { $ctype = 'image/png' }
                    Send-Binary $stream $ctype ([System.IO.File]::ReadAllBytes($file))
                } else {
                    Send-Response $stream 404 'text/plain' 'not found'
                }
            }
            elseif ($method -eq 'GET' -and $path -match '^/hd-cover/(.+)$') {
                $rel = [uri]::UnescapeDataString($matches[1]).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                $file = [System.IO.Path]::GetFullPath((Join-Path $HdCoverDir $rel))
                $root = [System.IO.Path]::GetFullPath($HdCoverDir)
                if ($file.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $file)) {
                    Send-Binary $stream 'image/jpeg' ([System.IO.File]::ReadAllBytes($file))
                } else {
                    Send-Response $stream 404 'text/plain' 'not found'
                }
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/deleted') {
                $days = 30
                if ($qs) {
                    if ($qs -match '(?:^|&)range=(\w+)') {
                        switch ($matches[1]) {
                            '7d' { $days = 7 }
                            '30d' { $days = 30 }
                            '180d' { $days = 180 }
                            '365d' { $days = 365 }
                            'all' { $days = 0 }
                        }
                    }
                }
                $cached = Get-DeletedItemsCached -Days $days
                $payload = [pscustomobject]@{
                    total = $cached.total
                    unknown = $cached.unknown
                    days = $cached.days
                    items = @($cached.items)
                    tracked = 'favourites-video only'
                    note = 'Dynamics and articles have no deletion signal yet.'
                }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/config') {
                $payload = [pscustomobject]@{ schema = $Schema; config = $Cfg }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 12)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/tasks') {
                $payload = [pscustomobject]@{ tasks = @(Get-TaskStatesCached) }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 8)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/history') {
                $payload = [pscustomobject]@{ days = @(Get-DailyHistoryCached) }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/save') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $key = ''
                if ($req -and $req.PSObject.Properties['key']) { $key = [string]$req.key }
                $val = $null
                if ($req -and $req.PSObject.Properties['value']) { $val = $req.value }
                if (-not $key) {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"missing key"}'
                    $client.Close()
                    continue
                }
                $err = Test-SettingValue $key $val
                if ($err) {
                    $resp = [pscustomobject]@{ ok = $false; error = $err; key = $key }
                    Send-Response $stream 400 'application/json' ($resp | ConvertTo-Json -Depth 4)
                    $client.Close()
                    continue
                }
                $store = Convert-ForStore $key $val
                Set-Prop $Cfg $key $store
                Write-JsonFile $CfgFile $Cfg
                $resp = [pscustomobject]@{ ok = $true; key = $key; value = $store }
                Send-Response $stream 200 'application/json' ($resp | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/folders') {
                $order = 'plan'
                if ($qs -and $qs -match '(?:^|&)order=(\w+)') { $order = $matches[1] }
                $payload = [pscustomobject]@{
                    folders    = @(Get-FavFolderRows -Order $order)
                    levels     = @('full', 'daily', 'skip')
                    orderReady = (Test-Path -LiteralPath (Join-Path $DirFav 'folder-order.json'))
                }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/folders') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $plan = $null
                if ($req -and $req.PSObject.Properties['plan']) { $plan = @($req.plan) }
                if ($null -eq $plan) {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"missing plan"}'
                    $client.Close()
                    continue
                }
                $known = @{}
                foreach ($r in @(Get-FavFolderRows)) { $known[[string]$r.name] = $true }
                $clean = @()
                foreach ($e in $plan) {
                    $n = ''
                    if ($e -and $e.PSObject.Properties['name']) { $n = [string]$e.name }
                    $lv = 'full'
                    if ($e -and $e.PSObject.Properties['level']) { $lv = [string]$e.level }
                    if (-not $n -or -not $known.ContainsKey($n)) { continue }
                    if ($lv -notin @('full', 'daily', 'skip')) { $lv = 'full' }
                    $clean += [pscustomobject]@{ name = $n; level = $lv }
                }
                Set-Prop $Cfg 'FavFolderPlan' $clean
                Write-JsonFile $CfgFile $Cfg
                $resp = [pscustomobject]@{ ok = $true; plan = $clean }
                Send-Response $stream 200 'application/json' ($resp | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/watch/start') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $bv = ''; $interval = 5
                if ($req -and $req.PSObject.Properties['bvid']) { $bv = [string]$req.bvid }
                if ($bv -match '/video/(BV[0-9A-Za-z]+)') { $bv = $Matches[1] }
                if ($req -and $req.PSObject.Properties['intervalSec']) { $interval = [int]$req.intervalSec }
                if ($bv -notmatch '^BV[0-9A-Za-z]+$') {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"invalid bvid"}'
                    $client.Close()
                    continue
                }
                if ($interval -lt 2) { $interval = 2 }
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'watch-comments.ps1') + '" -Bvid ' + $bv + ' -IntervalSec ' + $interval
                Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden | Out-Null
                $script:Cache.watch = $null
                Send-Response $stream 200 'application/json' '{"ok":true}'
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/watch/trash') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $bv = if ($req -and $req.bvid) { [string]$req.bvid } else { '' }
                if ($bv -notmatch '^BV[0-9A-Za-z]+$') {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"invalid bvid"}'
                    $client.Close(); continue
                }
                $watchName = '评论监控'
                if ($Cfg.Dirs.PSObject.Properties['Watch'] -and $Cfg.Dirs.Watch) { $watchName = [string]$Cfg.Dirs.Watch }
                $src = Join-Path (Join-Path $DataRoot $watchName) $bv
                if (-not (Test-Path -LiteralPath $src)) {
                    Send-Response $stream 404 'application/json' '{"ok":false,"error":"not found"}'
                    $client.Close(); continue
                }
                $st = $null
                try { $st = [System.IO.File]::ReadAllText((Join-Path $src 'state.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
                if ($st -and $st.running) {
                    [System.IO.File]::WriteAllText((Join-Path $src 'stop.flag'), '1')
                    Start-Sleep -Seconds 2
                }
                $trash = Join-Path (Join-Path $DataRoot $watchName) '.trash'
                New-Item -ItemType Directory -Force -Path $trash | Out-Null
                $dest = Join-Path $trash ($bv + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Move-Item -LiteralPath $src -Destination $dest -Force
                $script:Cache.watch = $null
                Send-Response $stream 200 'application/json' '{"ok":true}'
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/watch/trash') {
                $watchName = '评论监控'
                if ($Cfg.Dirs.PSObject.Properties['Watch'] -and $Cfg.Dirs.Watch) { $watchName = [string]$Cfg.Dirs.Watch }
                $trash = Join-Path (Join-Path $DataRoot $watchName) '.trash'
                $names = @()
                if (Test-Path -LiteralPath $trash) { $names = @(Get-ChildItem -LiteralPath $trash -Directory | Select-Object -ExpandProperty Name) }
                $payload = [pscustomobject]@{ items = $names }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 3)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/watch/restore') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $name = if ($req -and $req.name) { [string]$req.name } else { '' }
                if ($name -notmatch '^BV[0-9A-Za-z]+-\d{8}-\d{6}$') {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"invalid name"}'
                    $client.Close(); continue
                }
                $watchName = '评论监控'
                if ($Cfg.Dirs.PSObject.Properties['Watch'] -and $Cfg.Dirs.Watch) { $watchName = [string]$Cfg.Dirs.Watch }
                $trash = Join-Path (Join-Path $DataRoot $watchName) '.trash'
                $src = Join-Path $trash $name
                if (-not (Test-Path -LiteralPath $src)) {
                    Send-Response $stream 404 'application/json' '{"ok":false,"error":"not found"}'
                    $client.Close(); continue
                }
                $bv = ($name -split '-')[0]
                $dest = Join-Path (Join-Path $DataRoot $watchName) $bv
                Move-Item -LiteralPath $src -Destination $dest -Force
                $script:Cache.watch = $null
                Send-Response $stream 200 'application/json' '{"ok":true}'
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/watch') {
                $payload = [pscustomobject]@{ watches = @(Get-WatchStatesCached) }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/share') {
                $recent = @()
                if (Test-Path $ShareDir) {
                    foreach ($d in @(Get-ChildItem $ShareDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) {
                        $recent += [pscustomobject]@{
                            name = $d.Name
                            path = $d.FullName
                            at   = $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                            png  = (Test-Path (Join-Path $d.FullName 'card.png'))
                            post = (Test-Path (Join-Path $d.FullName 'post.txt'))
                        }
                    }
                }
                Send-Response $stream 200 'application/json' ([pscustomobject]@{ recent = @($recent); shareDir = $ShareDir } | ConvertTo-Json -Depth 5)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/share') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $period = 'last30d'
                if ($req -and $req.PSObject.Properties['period'] -and $req.period) { $period = [string]$req.period }
                if ($period -notmatch '^(last\d{1,3}d|\d{4}-\d{2}|\d{4})$') {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"invalid period"}'
                    $client.Close()
                    continue
                }
                $sections = ''
                if ($req -and $req.PSObject.Properties['sections']) {
                    $sections = ((@($req.sections) | ForEach-Object { [string]$_ }) -join ',')
                }
                if ($sections -notmatch '^[A-Za-z,]*$') {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"invalid sections"}'
                    $client.Close()
                    continue
                }
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $Root 'share.ps1'), '-Period', $period)
                if ($sections) { $argList += @('-Sections', $sections) }
                Start-Process -FilePath $ps -ArgumentList $argList -WindowStyle Hidden | Out-Null
                Send-Response $stream 200 'application/json' '{"ok":true,"started":true}'
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/backup-targets') {
                $targets = @()
                if ($Cfg.PSObject.Properties['BackupTargets'] -and $Cfg.BackupTargets) {
                    foreach ($t in @($Cfg.BackupTargets)) {
                        $targets += [pscustomobject]@{ path = [string]$t.Path; kind = [string]$t.Kind }
                    }
                }
                Send-Response $stream 200 'application/json' ([pscustomobject]@{ targets = @($targets) } | ConvertTo-Json -Depth 4)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/backup-targets') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $clean = @()
                foreach ($t in @($req.targets)) {
                    if (-not $t) { continue }
                    $p = ''
                    $k = 'primary'
                    if ($t.PSObject.Properties['path']) { $p = ([string]$t.path).Trim() }
                    if ($t.PSObject.Properties['kind']) { $k = ([string]$t.kind).Trim() }
                    if (-not $p) { continue }
                    if ($k -notin @('primary', 'mirror')) { $k = 'mirror' }
                    $clean += [pscustomobject]@{ Path = $p; Kind = $k }
                }
                if ($clean.Count -lt 1 -or $clean.Count -gt 3) {
                    Send-Response $stream 400 'application/json' '{"ok":false,"error":"need 1-3 targets"}'
                    $client.Close()
                    continue
                }
                Set-Prop $Cfg 'BackupTargets' @($clean)
                Write-JsonFile $CfgFile $Cfg
                Send-Response $stream 200 'application/json' ([pscustomobject]@{ ok = $true; targets = @($clean) } | ConvertTo-Json -Depth 5)
            }
            elseif ($method -eq 'GET' -and $path -eq '/api/covers') {
                $payload = [pscustomobject]@{ covers = (Get-CoversStatusCached) }
                Send-Response $stream 200 'application/json' ($payload | ConvertTo-Json -Depth 6)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/covers/fetch') {
                $req = $null
                try { $req = $body | ConvertFrom-Json } catch { }
                $folder = ''
                if ($req -and $req.PSObject.Properties['folder']) { $folder = [string]$req.folder }
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'fetch-covers-hd.ps1') + '"'
                if ($folder) { $argLine = $argLine + ' -Folder "' + $folder + '"' }
                Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null
                $script:Cache.covers = $null
                Send-Response $stream 200 'application/json' '{"ok":true}'
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/apply') {
                $code = Invoke-ApplyTasks
                $script:Cache.tasks = $null
                $resp = [pscustomobject]@{
                    ok    = ($code -eq 0)
                    code  = $code
                    tasks = @(Get-TaskStates)
                }
                Send-Response $stream 200 'application/json' ($resp | ConvertTo-Json -Depth 8)
            }
            elseif ($method -eq 'POST' -and $path -eq '/api/quit') {
                Send-Response $stream 200 'application/json' '{"ok":true}'
                $client.Close()
                break
            }
            else {
                Send-Response $stream 404 'text/plain' 'not found'
            }
        } catch {
            try { Send-Response $stream 500 'text/plain' 'internal error' } catch { }
        } finally {
            try { $client.Close() } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue } catch { }
    Write-Host 'settings server stopped'
}
