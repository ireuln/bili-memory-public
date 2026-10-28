#requires -version 5.1
<#
  Bilibili watch-history collector.

  Strategy: launch a DEDICATED Edge profile against a local CDP port, then run
  the history API fetch from inside the page context (same origin as the API),
  so no cookie ever leaves the browser and no credential is written by us.

  The browser profile is the only credential store. We never read it directly.

  Modes:
    (default)   incremental collect, write jsonl, exit
    -Status     report login state only
    -Login      open a visible window for the one-time QR login, wait, then close
    -Full       ignore the incremental cursor, backfill up to -MaxPages

  NOTE: pure ASCII on purpose. Windows PowerShell 5.1 reads BOM-less .ps1 as GBK;
  any non-ASCII byte here would break parsing.
#>
[CmdletBinding()]
# ---------------------------------------------------------------------------
# MODIFICATION MAP (for humans and AI assistants editing this file)
#
#   config.json          paths, directory names, all user-facing text
#   llms.txt             quick map for AI readers (rules + risk list)
#   docs/                Chinese docs: data contract, AI handover, risks
#
# Hard rules:
#   1. This file must stay pure ASCII. PS 5.1 decodes BOM-less scripts with the
#      system ANSI code page; one CJK byte breaks the whole file silently.
#   2. PowerShell variables are case-insensitive: never let a loop variable
#      shadow a script-level name (e.g. `$top` vs the `[int]` parameter `$Top`).
#   3. Every schedulable script ends with an explicit `exit 0`.
#   4. New data sources: probe with `-Probe <url>` first, then copy the
#      `-Follow` branch as a template. Never guess field names.
# ---------------------------------------------------------------------------

param(
    [switch]$Login,
    [switch]$Status,
    [switch]$Full,
    [switch]$FavFolders,
    [switch]$Fav,
    [string[]]$FavOnly = @(),
    [switch]$NoCover,
    [int]$CoverWidth = 0,
    [int]$FavMaxPages = 0,
    [switch]$IncludeLow,
    [int]$Top = 0,
    [switch]$Force,
    [int]$MaxPages = 40,
    [string]$Probe = '',
    [switch]$Follow,
    [switch]$WatchLater,
    [switch]$Dms,
    [int]$DmsLimit = 30,
    [switch]$FavCheck,
    [switch]$IncludeAllFollows,
    [switch]$Enrich,
    [int]$EnrichMax = 0,
    [int]$EnrichDelayMs = 0,
    [int]$Port = 9223,
    [int]$LoginTimeoutSec = 300
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
Set-StrictMode -Off
if ($Probe -and $Probe -notmatch '^https?://') {
    Write-Host 'Probe must be a full http(s) URL.'
    exit 2
}

$Root      = Split-Path -Parent $PSCommandPath
$ConfigFile = Join-Path $Root 'config.json'

# Paths may contain Chinese, so they live in a UTF-8 config.json. This script
# itself stays pure ASCII: Windows PowerShell 5.1 would misread the bytes.
$Cfg = $null
if (Test-Path $ConfigFile) {
    try { $Cfg = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { Write-Host "WARN: config.json unreadable, falling back to script folder." }
}
$DataRoot   = if ($Cfg -and $Cfg.DataRoot) { $Cfg.DataRoot } else { $Root }

# Every non-ASCII path component comes from config.json. Nothing here may hold
# a literal non-ASCII byte, or PS 5.1 would decode the whole file as GBK.
function Get-DirName {
    # ---------------------------------------------------------------------------
param($Cfg, [string]$Key, [string]$Fallback)
    if ($Cfg -and $Cfg.Dirs) {
        $p = $Cfg.Dirs.PSObject.Properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $Fallback
}

$DirHistory = Join-Path $DataRoot (Get-DirName $Cfg 'History' 'data')
$DirFav     = Join-Path $DataRoot (Get-DirName $Cfg 'Fav' 'favorites')
$DirCover   = Join-Path $DataRoot (Get-DirName $Cfg 'Cover' 'covers')
$ProfileDir = Join-Path $DataRoot (Get-DirName $Cfg 'Profile' 'profile')
$LogDir     = Join-Path $DataRoot (Get-DirName $Cfg 'Log' 'logs')
$DirFollow  = Join-Path $DataRoot (Get-DirName $Cfg 'Follow' 'follows')
$DirDms     = Join-Path $DataRoot (Get-DirName $Cfg 'Dms' 'dms')
$DirHeat    = Join-Path $DataRoot (Get-DirName $Cfg 'Heat' 'heat')
$DirDetail  = Join-Path $DataRoot (Get-DirName $Cfg 'Detail' 'details')
. (Join-Path $Root 'lib\heat.ps1')
. (Join-Path $Root 'lib\detail.ps1')
. (Join-Path $Root 'lib\folders.ps1')
$StateFile  = Join-Path $DirHistory 'state.json'
$EdgeExe    = if ($Cfg -and $Cfg.BrowserExe) { [string]$Cfg.BrowserExe } else { 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }
$HomeUrl    = 'https://www.bilibili.com/'
# Loading the homepage SPA costs ~700MB of renderer memory for no benefit; the
# API document is same-origin with the endpoints we call and renders in ~100MB.
$ApiUrl     = 'https://api.bilibili.com/x/web-interface/nav'

# User-facing strings live in config.json too (see above): one non-ASCII byte
# in this file is enough to break parsing under PS 5.1.
$Ui = [pscustomobject]@{
    masterFile   = 'favorites-master.jsonl'
    mdSummary    = '- items: {0} / invalid: {1} / updated: {2}'
    mdHeader     = '| # | title | uploader | duration | added | state | link |'
    mdSep        = '|---|---|---|---|---|---|---|'
    stateInvalid = 'invalid'
    stateOk      = 'ok'
    linkText     = 'link'
    progressFile = 'progress.json'
    watchLaterFile = 'watch-later.jsonl'
    dmsSessionsFile = 'dm-sessions.jsonl'
    heatFile = 'stats.jsonl'
    detailFile = 'details.jsonl'
}
if ($Cfg -and $Cfg.Text) {
    foreach ($p in $Cfg.Text.PSObject.Properties) {
        if ($Ui.PSObject.Properties[$p.Name]) { $Ui.($p.Name) = [string]$p.Value }
    }
}

foreach ($d in @($DirHistory, $DirFav, $DirCover, $ProfileDir, $LogDir, $DirFollow, $DirDms, $DirHeat, $DirDetail)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$HeatFile = Join-Path $DirHeat $Ui.heatFile
$DetailFile = Join-Path $DirDetail $Ui.detailFile
# Counters are free in the favourites response, but snapshotting every video
# every day would grow the file without bound. Config:
#   HeatEnabled = false -> do not snapshot at all
#   HeatMaxRows = N > 0 -> at most N new rows per run (default 5000), 0 = no cap
$HeatOn = $true
if ($Cfg -and $Cfg.PSObject.Properties['HeatEnabled'] -and $null -ne $Cfg.HeatEnabled) { $HeatOn = [bool]$Cfg.HeatEnabled }
$HeatMaxRows = 5000
if ($Cfg -and $Cfg.PSObject.Properties['HeatMaxRows'] -and $null -ne $Cfg.HeatMaxRows) { $HeatMaxRows = [int]$Cfg.HeatMaxRows }

# Enrichment budget: one request per video (~300 KB), so the default is a
# deliberately small 300 per run; the queue rotates by enriched_at, so the
# whole library still gets covered over time.
$EnrichBudget = 300
if ($Cfg -and $Cfg.PSObject.Properties['EnrichMax'] -and $null -ne $Cfg.EnrichMax) { $EnrichBudget = [int]$Cfg.EnrichMax }
$EnrichDelay = 600
if ($Cfg -and $Cfg.PSObject.Properties['EnrichDelayMs'] -and $null -ne $Cfg.EnrichDelayMs) { $EnrichDelay = [int]$Cfg.EnrichDelayMs }

$LogFile = Join-Path $LogDir ('collect-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function Write-Log {
    # ---------------------------------------------------------------------------
param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
}

# ---------------------------------------------------------------- CDP plumbing

function Wait-CdpReady {
    # ---------------------------------------------------------------------------
param([int]$Port, [int]$TimeoutSec = 40)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastErr = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $v = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 3
            if ($v.webSocketDebuggerUrl) { return $v }
        } catch { $lastErr = $_.Exception.Message }
        Start-Sleep -Milliseconds 400
    }
    throw "CDP never came up on port $Port. Last error: $lastErr"
}

function Get-PageTarget {
    # ---------------------------------------------------------------------------
param([int]$Port)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 3
            $page = @($targets | Where-Object { $_.type -eq 'page' }) | Select-Object -First 1
            if ($page -and $page.webSocketDebuggerUrl) { return $page }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
    throw 'No page target exposed by CDP.'
}

function New-CdpSession {
    # ---------------------------------------------------------------------------
param([string]$WsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    $task = $ws.ConnectAsync([Uri]$WsUrl, [System.Threading.CancellationToken]::None)
    if (-not $task.Wait(15000)) { throw 'CDP websocket connect timed out.' }
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw "CDP websocket state: $($ws.State)" }
    return $ws
}

function Send-CdpRaw {
    # ---------------------------------------------------------------------------
param($Ws, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $seg = [System.ArraySegment[byte]]::new($bytes)
    $t = $Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
    if (-not $t.Wait(15000)) { throw 'CDP send timed out.' }
}

function Receive-CdpRaw {
    # ---------------------------------------------------------------------------
param($Ws, [int]$TimeoutMs = 180000)
    $buf = New-Object byte[] 131072
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $seg = [System.ArraySegment[byte]]::new($buf)
        $t = $Ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        if (-not $t.Wait($TimeoutMs)) { throw 'CDP receive timed out.' }
        $r = $t.Result
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'CDP closed the socket.' }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
        if ($r.EndOfMessage) { break }
    }
    return $sb.ToString()
}

$script:CdpId = 0

function Invoke-Cdp {
    # ---------------------------------------------------------------------------
param($Ws, [string]$Method, $Params = $null, [int]$TimeoutMs = 180000)
    $script:CdpId++
    $id = $script:CdpId
    $payload = @{ id = $id; method = $Method }
    if ($null -ne $Params) { $payload.params = $Params }
    Send-CdpRaw -Ws $Ws -Json ($payload | ConvertTo-Json -Depth 8 -Compress)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $msg = Receive-CdpRaw -Ws $Ws -TimeoutMs ([int][Math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds))
        if ([string]::IsNullOrWhiteSpace($msg)) { continue }
        $obj = $msg | ConvertFrom-Json
        if ($obj.PSObject.Properties.Name -contains 'id' -and $obj.id -eq $id) {
            if ($obj.PSObject.Properties.Name -contains 'error') {
                throw ("CDP error on {0}: {1}" -f $Method, ($obj.error | ConvertTo-Json -Compress))
            }
            return $obj.result
        }
        # otherwise: a CDP event, ignore
    }
    throw "CDP call $Method timed out."
}

function Invoke-Js {
    # ---------------------------------------------------------------------------
param($Ws, [string]$Expression, [int]$TimeoutMs = 240000)
    $res = Invoke-Cdp -Ws $Ws -Method 'Runtime.evaluate' -Params @{
        expression    = $Expression
        awaitPromise  = $true
        returnByValue = $true
        userGesture   = $true
        timeout       = $TimeoutMs
    } -TimeoutMs $TimeoutMs
    if ($res.PSObject.Properties.Name -contains 'exceptionDetails' -and $null -ne $res.exceptionDetails) {
        throw ("JS exception: " + ($res.exceptionDetails | ConvertTo-Json -Depth 6 -Compress))
    }
    return $res.result.value
}

# ---------------------------------------------------------------- browser

function Set-PageUrl {
    # Point the tab at an explicit URL instead of trusting the launch argument.
    # ---------------------------------------------------------------------------
param($Ws, [string]$Url)
    $null = Invoke-Cdp -Ws $Ws -Method 'Page.navigate' -Params @{ url = $Url } -TimeoutMs 20000
}

function Wait-PageReady {
    # fetch() from an about:blank origin is blocked by CORS, so never call the
    # API before the tab has actually landed on a bilibili origin.
    # ---------------------------------------------------------------------------
param($Ws, [string]$ExpectHost = 'bilibili.com', [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $v = Invoke-Js -Ws $Ws -Expression 'JSON.stringify({s:document.readyState,h:location.href})' -TimeoutMs 8000
            $o = $v | ConvertFrom-Json
            $last = $o.h
            if ($o.s -eq 'complete' -and $o.h -like "*$ExpectHost*") { return $o.h }
        } catch { $last = $_.Exception.Message }
        Start-Sleep -Milliseconds 600
    }
    throw "page never reached a usable state (last href: $last)"
}

function Connect-PageSession {
    # One shot: grab the page target, connect, navigate once, wait until usable.
    # Prefers the lightweight API document; falls back to the homepage if that
    # ever fails to render as a page.
    # ---------------------------------------------------------------------------
param([int]$Port, [string]$Url = '', [int]$ReadyTimeout = 40)
    $target = Get-PageTarget -Port $Port
    $ws = New-CdpSession -WsUrl $target.webSocketDebuggerUrl
    $href = ''
    if (-not $Url) {
        try {
            Set-PageUrl -Ws $ws -Url $ApiUrl
            $href = Wait-PageReady -Ws $ws -ExpectHost 'bilibili.com' -TimeoutSec 20
        } catch { $href = '' }
        if (-not $href) {
            Set-PageUrl -Ws $ws -Url $HomeUrl
            $href = Wait-PageReady -Ws $ws -ExpectHost 'bilibili.com' -TimeoutSec $ReadyTimeout
        }
    } else {
        Set-PageUrl -Ws $ws -Url $Url
        $href = Wait-PageReady -Ws $ws -ExpectHost 'bilibili.com' -TimeoutSec $ReadyTimeout
    }
    return [pscustomobject]@{ Ws = $ws; Href = $href }
}

function Test-BrowserAlive {
    # ---------------------------------------------------------------------------
param([string]$ProfileDir)
    $n = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
           Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" }).Count
    return ($n -gt 0)
}

function Invoke-JsRetry {
    # Reconnects from scratch between attempts: a dead tab kills the websocket,
    # and reusing it is the one failure mode we actually hit.
    # ---------------------------------------------------------------------------
param([int]$Port, [string]$Expression, [int]$TimeoutMs = 240000, [int]$Attempts = 3)
    $lastErr = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        $ses = $null
        try {
            $ses = Connect-PageSession -Port $Port
            Write-Log ("page ready: {0}" -f $ses.Href)
            $out = Invoke-Js -Ws $ses.Ws -Expression $Expression -TimeoutMs $TimeoutMs
            return $out
        }
        catch {
            $lastErr = $_.Exception.Message
            Write-Log ("attempt {0}/{1} failed: {2}" -f $i, $Attempts, $lastErr) 'WARN'
            Start-Sleep -Seconds 2
        }
        finally {
            if ($ses -and $ses.Ws) { try { $ses.Ws.Dispose() } catch { } }
        }
    }
    throw "all $Attempts attempts failed. Last: $lastErr"
}

function Start-Browser {
    # ---------------------------------------------------------------------------
param([string]$Url, [switch]$Visible)
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
                  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" })
    if ($existing.Count -gt 0) {
        throw "A collector browser is already running for this profile (pid $($existing[0].ProcessId)). Close it first."
    }
    $argList = @(
        "--remote-debugging-port=$Port",
        "--user-data-dir=`"$ProfileDir`"",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-features=msEdgeFirstRunExperience,msEdgeSidebarV2',
        '--disable-background-networking',
        '--disable-sync',
        '--no-service-autorun',
        '--password-store=basic',
        '--disable-component-update'
    )
    if (-not $Visible) {
        $argList += '--window-position=-32000,-32000'
        $argList += '--window-size=1024,768'
    }
    else {
        # Edge persists window geometry in the profile, so an off-screen position
        # from a headless run would be restored here. Force a sane on-screen spot.
        $argList += '--window-position=160,120'
        $argList += '--window-size=1280,900'
    }
    $argList += 'about:blank'
    $proc = Start-Process -FilePath $EdgeExe -ArgumentList $argList -PassThru
    return $proc
}

function Stop-Browser {
    # ---------------------------------------------------------------------------
param([int]$Port, $Proc)
    try {
        $v = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 3
        if ($v.webSocketDebuggerUrl) {
            try {
                $ws = New-CdpSession -WsUrl $v.webSocketDebuggerUrl
                [void](Invoke-Cdp -Ws $ws -Method 'Browser.close' -TimeoutMs 8000)
                $ws.Dispose()
            } catch { }
        }
    } catch { }
    Start-Sleep -Seconds 2
    $left = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
              Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" })
    foreach ($p in $left) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($left.Count -gt 0) { Write-Log "Force-killed $($left.Count) leftover browser process(es)." 'WARN' }
}

# ---------------------------------------------------------------- page scripts

$JsLoginCheck = @'
(async () => {
  try {
    const r = await fetch('https://api.bilibili.com/x/web-interface/nav', { credentials: 'include' });
    const j = await r.json();
    return JSON.stringify({ isLogin: !!(j.data && j.data.isLogin), code: j.code, mid: (j.data || {}).mid || 0, uname: (j.data || {}).uname || '' });
  } catch (e) { return JSON.stringify({ isLogin: false, code: -999, error: String(e) }); }
})()
'@

$JsProbe = @'
(async () => {
  try {
    const r = await fetch('__URL__', { credentials: 'include' });
    const t = await r.text();
    return JSON.stringify({ status: r.status, body: t.slice(0, __LIMIT__) });
  } catch (e) { return JSON.stringify({ status: -1, error: String(e) }); }
})()
'@

$JsWatchLater = @'
(async () => {
  try {
    const r = await fetch('https://api.bilibili.com/x/v2/history/toview', { credentials: 'include' });
    const j = await r.json();
    if (j.code !== 0) { return JSON.stringify({ ok: false, code: j.code, message: j.message }); }
    const d = j.data || {};
    const list = (d.list || []).map(function (it) {
      const o = it.owner || {};
      return { bvid: it.bvid || '', aid: it.aid || 0, title: it.title || '',
        author: o.name || '', author_mid: o.mid || 0, tag: it.tname || '',
        duration: it.duration || 0,
        progress: (typeof it.progress === 'number' ? it.progress : null),
        add_at: it.add_at || 0, pubdate: it.pubdate || 0 };
    });
    return JSON.stringify({ ok: true, count: d.count || 0, list: list });
  } catch (e) { return JSON.stringify({ ok: false, error: String(e) }); }
})()
@'

$JsFavFolders = @'
(async () => {
  try {
    const nav = await fetch('https://api.bilibili.com/x/web-interface/nav', { credentials: 'include' });
    const nj = await nav.json();
    if (!nj.data || nj.data.isLogin !== true) { return JSON.stringify({ ok: false, error: 'not_logged_in', code: nj.code }); }
    const mid = nj.data.mid;
    const r = await fetch('https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=' + mid, { credentials: 'include' });
    const j = await r.json();
    if (j.code !== 0) { return JSON.stringify({ ok: false, error: 'api', code: j.code, message: j.message }); }
    const list = (j.data && j.data.list) || [];
    const folders = list.map(function (f) {
      return { id: f.id, fid: f.fid, title: f.title, count: f.media_count, attr: f.attr, state: f.state };
    });
    folders.sort(function (a, b) { return (b.count || 0) - (a.count || 0); });
    return JSON.stringify({ ok: true, mid: mid, uname: nj.data.uname || '', folders: folders });
  } catch (e) { return JSON.stringify({ ok: false, error: 'exception', message: String(e) }); }
})()
'@

$JsCollect = @'
(async () => {
  const MAX = __MAX_PAGES__;
  const SINCE = __SINCE__;
  try {
    const nav = await fetch('https://api.bilibili.com/x/web-interface/nav', { credentials: 'include' });
    const nj = await nav.json();
    if (!nj.data || nj.data.isLogin !== true) {
      return JSON.stringify({ ok: false, error: 'not_logged_in', code: nj.code, mid: 0 });
    }
    const out = [];
    const seen = new Set();
    let max = 0, viewAt = 0, pages = 0, stopped = false, oldStreak = 0;
    while (pages < MAX && !stopped) {
      let url = 'https://api.bilibili.com/x/web-interface/history/cursor?ps=30&type=archive';
      if (max > 0) { url += '&max=' + max + '&view_at=' + viewAt; }
      const r = await fetch(url, { credentials: 'include' });
      const j = await r.json();
      if (j.code !== 0) {
        return JSON.stringify({ ok: false, error: 'api', code: j.code, message: j.message, mid: nj.data.mid, list: out, pages: pages });
      }
      const list = (j.data && j.data.list) || [];
      if (list.length === 0) { break; }
      for (const it of list) {
        const va = it.view_at || 0;
        // Bilibili does not return history in strict time order: stale PGC
        // (bangumi/movie) entries can surface between fresh ones. So require a
        // long run of old items before assuming the cursor is caught up.
        if (SINCE > 0 && va <= SINCE) {
          oldStreak++;
          if (oldStreak >= 60) { stopped = true; break; }
          continue;
        }
        oldStreak = 0;
        const hist = it.history || {};
        const bvid = it.bvid || hist.bvid || '';
        const aid = hist.oid || 0;
        const key = va + '|' + (bvid || aid || it.title || '');
        if (seen.has(key)) { continue; }
        seen.add(key);
        out.push({
          view_at: va,
          bvid: bvid,
          aid: aid,
          title: it.title || '',
          author: it.author_name || '',
          author_mid: it.author_mid || 0,
          tag: it.tag_name || '',
          duration: it.duration || 0,
          progress: (typeof it.progress === 'number' ? it.progress : null),
          is_finish: it.is_finish || 0,
          completion: (typeof it.progress === 'number' && it.progress > 0 && it.duration > 0)
            ? Math.min(1, it.progress / it.duration) : null,
          completed: (typeof it.progress === 'number' && it.progress > 0 && it.duration > 0)
            ? (it.progress / it.duration >= 0.9) : false,
          videos: it.videos || 1,
          business: hist.business || 'archive'
        });
      }
      const c = (j.data && j.data.cursor) || {};
      max = c.max || 0;
      viewAt = c.view_at || 0;
      pages++;
      if (list.length < 30) { break; }
      await new Promise(function (res) { setTimeout(res, 400); });
    }
    return JSON.stringify({ ok: true, mid: nj.data.mid, uname: nj.data.uname || '', list: out, pages: pages, stopped_at_since: stopped });
  } catch (e) {
    return JSON.stringify({ ok: false, error: 'exception', message: String(e) });
  }
})()
'@

# ---------------------------------------------------------------- state

function Read-State {
    $s = [pscustomobject]@{ lastViewAt = 0; lastRun = $null; total = 0; mid = 0 }
    if (Test-Path $StateFile) {
        try {
            $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'lastViewAt') { $s.lastViewAt = [int64]$j.lastViewAt }
            if ($j.PSObject.Properties.Name -contains 'lastRun')    { $s.lastRun    = $j.lastRun }
            if ($j.PSObject.Properties.Name -contains 'total')      { $s.total      = [int]$j.total }
            if ($j.PSObject.Properties.Name -contains 'mid')        { $s.mid        = [int64]$j.mid }
        } catch { Write-Log "state.json unreadable, starting fresh: $($_.Exception.Message)" 'WARN' }
    }
    return $s
}

function Write-State {
    # ---------------------------------------------------------------------------
param($State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Write-RunResult {
    # Machine-readable run summary. Downstream tools should read this file
    # instead of parsing console output; `schema` is bumped on breaking changes.
    # ---------------------------------------------------------------------------
param([string]$Mode, [int]$ExitCode, [hashtable]$Extra)
    $obj = [ordered]@{
        schema   = 1
        mode     = $Mode
        exit     = $ExitCode
        finished = (Get-Date).ToString('o')
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] } }
    try {
        $path = Join-Path $DataRoot 'last-result.json'
        [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-RecordKey {
    # ---------------------------------------------------------------------------
param($Rec)
    $id = if ($Rec.bvid) { $Rec.bvid } elseif ($Rec.aid) { [string]$Rec.aid } else { $Rec.title }
    return ([string]$Rec.view_at) + '|' + $id
}

function Append-Records {
    # Dedupe against what is already on disk, not just within this run: the
    # incremental cursor deliberately overlaps by a couple of minutes so that
    # items sharing the boundary second are never lost.
    # ---------------------------------------------------------------------------
param([object[]]$Records)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $byMonth = @{}
    foreach ($rec in $Records) {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$rec.view_at).ToLocalTime()
        $m = $dt.ToString('yyyy-MM')
        if (-not $byMonth.ContainsKey($m)) { $byMonth[$m] = New-Object System.Collections.ArrayList }
        [void]$byMonth[$m].Add($rec)
    }
    $written = 0
    $skipped = 0
    $inKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $inDup = 0
    foreach ($rec in $Records) {
        if (-not $inKeys.Add((Get-RecordKey -Rec $rec))) { $inDup++ }
    }
    if ($inDup -gt 0) { Write-Log ("input contained {0} duplicate key(s) out of {1}" -f $inDup, $Records.Count) 'WARN' }
    foreach ($m in ($byMonth.Keys | Sort-Object)) {
        $path = Join-Path $DirHistory ($m + '.jsonl')
        $existing = New-Object 'System.Collections.Generic.HashSet[string]'
        if (Test-Path $path) {
            foreach ($line in [System.IO.File]::ReadLines($path)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $o = $line | ConvertFrom-Json; [void]$existing.Add((Get-RecordKey -Rec $o)) } catch { }
            }
        }
        $sb = New-Object System.Text.StringBuilder
        foreach ($rec in $byMonth[$m]) {
            $k = Get-RecordKey -Rec $rec
            if ($existing.Contains($k)) { $skipped++; continue }
            [void]$existing.Add($k)
            [void]$sb.Append(($rec | ConvertTo-Json -Depth 5 -Compress) + "`n")
            $written++
        }
        if ($sb.Length -gt 0) {
            [System.IO.File]::AppendAllText($path, $sb.ToString(), $utf8)
        }
    }
    return [pscustomobject]@{ Written = $written; Skipped = $skipped }
}

# ---------------------------------------------------------------- favorites

$JsFavPage = @'
(async () => {
  const MEDIA_ID = __MEDIA_ID__;
  const MAXPAGES = __MAX_PAGES__;
  const DELAY_MIN = __DELAY_MIN__;
  const DELAY_MAX = __DELAY_MAX__;
  try {
    const out = [];
    let pn = 1, pages = 0, exhausted = false;
    while (pages < MAXPAGES) {
      const url = 'https://api.bilibili.com/x/v3/fav/resource/list?media_id=' + MEDIA_ID +
                  '&pn=' + pn + '&ps=20&platform=web&order=mtime&type=0&tid=0';
      const r = await fetch(url, { credentials: 'include' });
      const j = await r.json();
      if (j.code !== 0) {
        return JSON.stringify({ ok: false, error: 'api', code: j.code, message: j.message, list: out, pages: pages });
      }
      const d = j.data || {};
      const medias = d.medias || [];
      for (const m of medias) {
        const up = m.upper || {};
        const attr = m.attr || 0;
        const ci = m.cnt_info || {};
        out.push({
          bvid: m.bvid || '',
          aid: m.id || 0,
          type: m.type || 0,
          title: m.title || '',
          cover: m.cover || '',
          upper: up.name || '',
          upper_mid: up.mid || 0,
          duration: m.duration || 0,
          pubtime: m.pubtime || 0,
          fav_time: m.fav_time || m.ctime || 0,
          attr: attr,
          invalid: ((attr & 1) === 1) || !m.cover,
          intro: (m.intro || '').slice(0, 120),
          link: m.link || '',
          play: ci.play || 0,
          danmaku: ci.danmaku || 0,
          fav_count: ci.collect || 0
        });
      }
      pages++;
      if (!d.has_more || medias.length === 0) { exhausted = true; break; }
      pn++;
      await new Promise(function (res) {
        setTimeout(res, DELAY_MIN + Math.floor(Math.random() * Math.max(1, DELAY_MAX - DELAY_MIN)));
      });
    }
    return JSON.stringify({ ok: true, media_id: MEDIA_ID, list: out, pages: pages, exhausted: exhausted });
  } catch (e) {
    return JSON.stringify({ ok: false, error: 'exception', message: String(e), list: [], pages: 0 });
  }
})()
'@

function Get-FavKey {
    # ---------------------------------------------------------------------------
param($Rec)
    if ($Rec.bvid) { return [string]$Rec.bvid }
    if ($Rec.aid) { return 'av' + [string]$Rec.aid }
    return 'unknown'
}

function Get-SafeFileName {
    # ---------------------------------------------------------------------------
param([string]$Name)
    $bad = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($bad -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $s = $sb.ToString().Trim()
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    if (-not $s) { $s = 'untitled' }
    return $s
}

function Read-FavMaster {
    $map = [ordered]@{}
    $path = Join-Path $DirFav $Ui.masterFile
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $map[(Get-FavKey $o)] = $o
        } catch { }
    }
    return $map
}

function Write-FavMaster {
    # ---------------------------------------------------------------------------
param($Map)
    $path = Join-Path $DirFav $Ui.masterFile
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder
    $items = @($Map.Values) | Sort-Object { [int64]$_.fav_time } -Descending
    foreach ($o in $items) {
        [void]$sb.Append(($o | ConvertTo-Json -Depth 5 -Compress) + "`n")
    }
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $utf8)
    return $items.Count
}

function Write-FavMarkdown {
    # ---------------------------------------------------------------------------
param($Map, [string]$FolderTitle, [long]$FolderId)
    $items = @($Map.Values) | Where-Object { [long]$_.folder_id -eq $FolderId } |
             Sort-Object { [int64]$_.fav_time } -Descending
    $path = Join-Path $DirFav ((Get-SafeFileName $FolderTitle) + '.md')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder
    $bad = @($items | Where-Object { $_.invalid }).Count
    [void]$sb.AppendLine('# ' + $FolderTitle)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(($Ui.mdSummary -f $items.Count, $bad, (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($Ui.mdHeader)
    [void]$sb.AppendLine($Ui.mdSep)
    $i = 0
    foreach ($it in $items) {
        $i++
        $t = ([string]$it.title) -replace '\|', '\|'
        $u = ([string]$it.upper) -replace '\|', '\|'
        $mins = [math]::Floor(([int]$it.duration) / 60)
        $secs = ([int]$it.duration) % 60
        $dur = '{0}:{1:00}' -f $mins, $secs
        $ft = if ([int64]$it.fav_time -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$it.fav_time).ToLocalTime().ToString('yyyy-MM-dd') } else { '' }
        $state = if ($it.invalid) { $Ui.stateInvalid } else { $Ui.stateOk }
        $link = if ($it.bvid) { 'https://www.bilibili.com/video/' + $it.bvid } else { 'https://www.bilibili.com/video/av' + $it.aid }
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | [{6}]({7}) |' -f $i, $t, $u, $dur, $ft, $state, $Ui.linkText, $link))
    }
    [System.IO.File]::WriteAllText($path, $sb.ToString(), $utf8)
    return $items.Count
}

function Save-CoverFile {
    # ---------------------------------------------------------------------------
param([string]$Url, [string]$OutFile, [int]$Width = 320)
    if (-not $Url) { return $false }
    if (Test-Path $OutFile) { return $true }
    $u = $Url.Trim()
    if ($u -notmatch '^https?://') { $u = 'https://' + $u }
    $h = [int]($Width * 0.625)
    $sized = $u + ('@' + $Width + 'w_' + $h + 'h_1c.webp')
    try {
        Invoke-WebRequest -Uri $sized -OutFile $OutFile -UseBasicParsing -TimeoutSec 20 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://www.bilibili.com/' } | Out-Null
        return $true
    } catch {
        try {
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 20 `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://www.bilibili.com/' } | Out-Null
            return $true
        } catch { return $false }
    }
}

function Read-FavCheckpoint {
    $p = Join-Path $DirFav $Ui.progressFile
    $h = @{}
    if (-not (Test-Path $p)) { return $h }
    try {
        $j = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($prop in $j.PSObject.Properties) { $h[$prop.Name] = [string]$prop.Value }
    } catch { Write-Log ("checkpoint unreadable, starting fresh: " + $_.Exception.Message) 'WARN' }
    return $h
}

function Write-FavCheckpoint {
    # ---------------------------------------------------------------------------
param($Map)
    $p = Join-Path $DirFav $Ui.progressFile
    $o = [ordered]@{}
    foreach ($k in ($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
    [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Save-CoversBulk {
    # Sequential downloads cost ~2h for a full 13k archive, so fan out across
    # runspaces. Every file already on disk is skipped, which makes this pass
    # resumable after a crash or a manual stop.
    # ---------------------------------------------------------------------------
param([object[]]$Jobs, [int]$Width = 320, [int]$Throttle = 6)
    $body = {
        # ---------------------------------------------------------------------------
param($payload, $Width)
        $h = [int]($Width * 0.625)
        $ok = 0; $fail = 0
        $hdr = @{ 'User-Agent' = 'Mozilla/5.0'; 'Referer' = 'https://www.bilibili.com/' }
        foreach ($j in $payload.items) {
            $u = [string]$j.url
            if ($u -notmatch '^https?://') { $u = 'https://' + $u }
            $sized = $u + ('@' + $Width + 'w_' + $h + 'h_1c.webp')
            $done = $false
            try {
                Invoke-WebRequest -Uri $sized -OutFile $j.dest -UseBasicParsing -TimeoutSec 20 -Headers $hdr | Out-Null
                $done = $true
            } catch {
                try {
                    Invoke-WebRequest -Uri $u -OutFile $j.dest -UseBasicParsing -TimeoutSec 20 -Headers $hdr | Out-Null
                    $done = $true
                } catch { }
            }
            if ($done) { $ok++ } else { $fail++ }
        }
        return @($ok, $fail)
    }
    $n = [int][Math]::Ceiling($Jobs.Count / [double]$Throttle)
    if ($n -lt 1) { $n = 1 }
    $chunks = @()
    for ($i = 0; $i -lt $Throttle; $i++) {
        $start = $i * $n
        if ($start -ge $Jobs.Count) { break }
        $end = [Math]::Min($start + $n - 1, $Jobs.Count - 1)
        $chunks += , @($Jobs[$start..$end])
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $chunks.Count))
    $pool.Open()
    $handles = @()
    foreach ($c in $chunks) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($body).AddArgument([pscustomobject]@{ items = $c }).AddArgument($Width)
        $handles += [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
    }
    $ok = 0; $fail = 0; $done = 0
    foreach ($hnd in $handles) {
        try {
            $out = $hnd.PS.EndInvoke($hnd.H)
            if ($out -and $out.Count -ge 2) { $ok += [int]$out[0]; $fail += [int]$out[1] }
        } catch { Write-Log ("cover batch error: " + $_.Exception.Message) 'WARN' }
        $hnd.PS.Dispose()
        $done++
        Write-Log ("  cover batch {0}/{1} finished (ok={2} fail={3})" -f $done, $handles.Count, $ok, $fail)
    }
    $pool.Close()
    $pool.Dispose()
    return @($ok, $fail)
}

function Get-FavFolders {
    # Fetch the folder list through the generic probe + PowerShell parsing.
    # A dedicated JS block here kept returning an empty string, so this path is
    # deliberately dumb: raw JSON out, ConvertFrom-Json in.
    param([int]$Port)
    $st = (Invoke-JsRetry -Port $Port -Expression $JsLoginCheck -TimeoutMs 30000) | ConvertFrom-Json
    if (-not $st.isLogin) { return $null }
    $u = 'https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=' + $st.mid
    $env1 = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $u).Replace('__LIMIT__', '2000000')) -TimeoutMs 60000) | ConvertFrom-Json
    $body = $env1.body | ConvertFrom-Json
    if ($body.code -ne 0) { Write-Log ('folder list api failed: ' + $body.code) 'ERROR'; return $null }
    $list = @($body.data.list)
    $out = @()
    foreach ($f1 in $list) {
        $out += [pscustomobject]@{ id = $f1.id; fid = $f1.fid; title = $f1.title; count = $f1.media_count; attr = $f1.attr; state = $f1.state }
    }
    return $out
    $null = $Port
}

function Invoke-FavCollect {
    # ---------------------------------------------------------------------------
param([int]$Port, [object[]]$Folders, [int]$MaxPages, [int]$CoverWidth, [bool]$WithCover, [switch]$Force)

    $master = Read-FavMaster
    Write-Log ("master loaded: {0} existing favorite(s)" -f $master.Count)
    $ck = Read-FavCheckpoint
    if ($Force) { $ck = @{} ; Write-Log 'force mode: checkpoint ignored' }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $grandNew = 0
    $grandInv = 0

    foreach ($folder in $Folders) {
        $ckKey = [string]$folder.id
        if (-not $Force -and $ck.ContainsKey($ckKey)) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse([string]$ck[$ckKey], [ref]$ts) -and (((Get-Date) - $ts).TotalHours -lt 12)) {
                Write-Log ("skip '{0}' id={1}: done at {2}" -f $folder.title, $folder.id, $ts.ToString('HH:mm:ss'))
                continue
            }
        }
        $pages = [int][Math]::Ceiling([double]$folder.count / 20.0) + 2
        if ($MaxPages -gt 0 -and $pages -gt $MaxPages) { $pages = $MaxPages }
        Write-Log ("folder '{0}' id={1} count={2} pages<={3}" -f $folder.title, $folder.id, $folder.count, $pages)

        $expr = $JsFavPage.Replace('__MEDIA_ID__', [string]$folder.id).Replace('__MAX_PAGES__', [string]$pages).Replace('__DELAY_MIN__', '1200').Replace('__DELAY_MAX__', '2000')
        $timeout = 60000 + ($pages * 2500)
        $raw = Invoke-JsRetry -Port $Port -Expression $expr -TimeoutMs $timeout
        $res = $raw | ConvertFrom-Json
        if (-not $res.ok) {
            Write-Log ("folder '{0}' failed: {1} {2}" -f $folder.title, $res.error, $res.message) 'ERROR'
            continue
        }
        $items = @($res.list)
        Write-Log ("  fetched {0} item(s) over {1} page(s)" -f $items.Count, $res.pages)

        $newCount = 0
        $invCount = 0
        $coverDir = Join-Path $DirCover ([string]$folder.id)
        if ($WithCover -and -not (Test-Path $coverDir)) { New-Item -ItemType Directory -Force -Path $coverDir | Out-Null }

        foreach ($it in $items) {
            $k = Get-FavKey $it
            $rec = $null
            if ($master.Contains($k)) { $rec = $master[$k] }
            if ($null -eq $rec) {
                $rec = [pscustomobject]@{
                    folder_id = [long]$folder.id; folder = [string]$folder.title
                    bvid = $it.bvid; aid = [int64]$it.aid; type = $it.type
                    title = $it.title; upper = $it.upper; upper_mid = [int64]$it.upper_mid
                    duration = $it.duration; pubtime = [int64]$it.pubtime; fav_time = [int64]$it.fav_time
                    attr = $it.attr; invalid = [bool]$it.invalid
                    first_seen = $now; last_seen = $now
                    invalid_since = $(if ($it.invalid) { $now } else { '' })
                    intro = $it.intro; link = $it.link; cover = $it.cover
                    play = [int64]$it.play; danmaku = [int64]$it.danmaku; fav_count = [int64]$it.fav_count
                    stats_at = $now
                }
                $master[$k] = $rec
                $newCount++
            } else {
                $rec.last_seen = $now
                $rec.folder_id = [long]$folder.id
                $rec.folder = [string]$folder.title
                if ($it.title) { $rec.title = $it.title }
                if ($it.upper) { $rec.upper = $it.upper }
                if ($it.cover) { $rec.cover = $it.cover }
                $rec.attr = $it.attr
                # Counters come for free in the same response; keep the record
                # current and let the heat snapshot below own the time series.
                foreach ($cntName in @('play', 'danmaku', 'fav_count')) {
                    $val = [int64]$it.$cntName
                    if ($rec.PSObject.Properties[$cntName]) { $rec.$cntName = $val }
                    else { $rec | Add-Member -NotePropertyName $cntName -NotePropertyValue $val -Force }
                }
                if ($rec.PSObject.Properties['stats_at']) { $rec.stats_at = $now }
                else { $rec | Add-Member -NotePropertyName stats_at -NotePropertyValue $now -Force }
                if ([bool]$it.invalid -and -not $rec.invalid) {
                    $rec.invalid = $true
                    $rec.invalid_since = $now
                } elseif (-not [bool]$it.invalid -and $rec.invalid) {
                    $rec.invalid = $false
                    $rec.invalid_since = ''
                }
            }
            if ($rec.invalid) { $invCount++ }
        }
        # Detect items unfavourited since the last complete scan of this folder.
        # Only trust the diff when paging actually exhausted, otherwise a partial
        # fetch would mark live items as removed.
        if ($res.exhausted) {
            $seen = @{}
            foreach ($it in $items) { $seen[(Get-FavKey $it)] = $true }
            $removedCount = 0
            foreach ($k2 in @($master.Keys)) {
                $rec2 = $master[$k2]
                if ([long]$rec2.folder_id -ne [long]$folder.id) { continue }
                $hasProp = $rec2.PSObject.Properties.Name -contains 'removed_at'
                if ($seen.ContainsKey($k2)) {
                    if ($hasProp -and $rec2.removed_at) { $rec2.removed_at = '' }
                } else {
                    if (-not $hasProp) {
                        $rec2 | Add-Member -NotePropertyName removed_at -NotePropertyValue $now -Force
                        $removedCount++
                    } elseif (-not $rec2.removed_at) {
                        $rec2.removed_at = $now
                        $removedCount++
                    }
                }
            }
            if ($removedCount -gt 0) { Write-Log ("  {0} item(s) marked removed from this folder" -f $removedCount) }
        }

        $written = Write-FavMarkdown -Map $master -FolderTitle $folder.title -FolderId ([long]$folder.id)
        $totalNow = Write-FavMaster -Map $master
        $ck[$ckKey] = (Get-Date).ToString('o')
        Write-FavCheckpoint -Map $ck
        Write-Log ("  saved: new={0} invalid={1} md-rows={2} master={3}" -f $newCount, $invCount, $written, $totalNow)
        $grandNew += $newCount
        $grandInv += $invCount
    }

    if ($WithCover) {
        $pending = New-Object System.Collections.ArrayList
        foreach ($rec in $master.Values) {
            if ($rec.invalid -or -not $rec.cover) { continue }
            $dir = Join-Path $DirCover ([string]$rec.folder_id)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $fname = (Get-SafeFileName $(if ($rec.bvid) { $rec.bvid } else { 'av' + $rec.aid })) + '.jpg'
            $dest = Join-Path $dir $fname
            if (Test-Path $dest) { continue }
            [void]$pending.Add([pscustomobject]@{ url = [string]$rec.cover; dest = $dest })
        }
        Write-Log ("cover queue: {0} file(s) missing" -f $pending.Count)
        if ($pending.Count -gt 0) {
            $cr = Save-CoversBulk -Jobs $pending -Width $CoverWidth -Throttle 6
            Write-Log ("covers done: ok={0} fail={1}" -f $cr[0], $cr[1])
        }
    }

    $total = Write-FavMaster -Map $master
    Write-Log ("master written: {0} favorite(s) total, {1} new this run" -f $total, $grandNew)

    # Heat snapshot: the counters were free in the same response, so this adds
    # no request. Order = never sampled first, then oldest sample, so a capped
    # run rotates through the whole library instead of re-sampling the same N.
    if ($HeatOn) {
        $heatRows = New-Object System.Collections.ArrayList
        $lastDates = Get-HeatLastDates -Path $HeatFile
        $cands = @(@($master.Values) | Where-Object { $_.bvid -and -not $_.invalid } | ForEach-Object {
            $b = [string]$_.bvid
            $ld = ''
            if ($lastDates.ContainsKey($b)) { $ld = [string]$lastDates[$b] }
            [pscustomobject]@{ rec = $_; last = $ld }
        } | Sort-Object -Property @{ Expression = { $_.last } }, @{ Expression = { [int64]$_.rec.fav_time }; Descending = $true } |
            ForEach-Object { $_.rec })
        foreach ($r in $cands) {
            $vPlay = 0; $vDm = 0; $vFav = 0
            if ($r.PSObject.Properties['play']) { $vPlay = [int64]$r.play }
            if ($r.PSObject.Properties['danmaku']) { $vDm = [int64]$r.danmaku }
            if ($r.PSObject.Properties['fav_count']) { $vFav = [int64]$r.fav_count }
            [void]$heatRows.Add([pscustomobject]@{
                bvid = [string]$r.bvid; view = $vPlay; danmaku = $vDm; fav = $vFav; source = 'fav'
            })
        }
        $hr = Merge-HeatSnapshot -Path $HeatFile -Rows $heatRows -MaxRows $HeatMaxRows
        Write-Log ("heat: total={0} added={1} updated={2} skipped={3}" -f $hr.Total, $hr.Added, $hr.Updated, $hr.Skipped)
    }

    return [pscustomobject]@{ Total = $total; New = $grandNew }
}

# ---------------------------------------------------------------- enrich

function Invoke-Enrich {
    # ---------------------------------------------------------------------------
    # Deliberately NOT going through the browser: view/detail is public data, so
    # a plain request works, costs no CDP round-trip, and can be tested without
    # logging in. Member-only videos simply fail and are retried next time.
    param([int]$Max = 300, [int]$DelayMs = 600)

    $empty = [pscustomobject]@{ Requested = 0; Ok = 0; Fail = 0; DetailFile = $DetailFile }
    if ($Max -le 0) { Write-Log 'enrich: skipped (EnrichMax <= 0)'; return $empty }

    $master = Read-FavMaster
    $cands = @(@($master.Values) | Where-Object { $_.bvid -and -not $_.invalid } | ForEach-Object {
        [pscustomobject]@{
            bvid     = [string]$_.bvid
            fav_time = [int64]$_.fav_time
            weight   = (Get-FolderWeight -Cfg $Cfg -Name ([string]$_.folder))
        }
    } | Where-Object { [int]$_.weight -gt 0 })
    if ($cands.Count -eq 0) { Write-Log 'enrich: no candidates (run a fav collection first)'; return $empty }

    $details = Read-DetailMap -Path $DetailFile
    $queue = @(Select-EnrichQueue -Candidates $cands -Details $details -Max $Max)
    if ($queue.Count -eq 0) { Write-Log 'enrich: queue empty'; return $empty }

    Write-Log ("enrich: {0} of {1} candidate(s) queued, {2} ms apart" -f $queue.Count, $cands.Count, $DelayMs)
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36'
    $hdr = @{ 'User-Agent' = $ua; 'Referer' = 'https://www.bilibili.com/' }
    $ok = 0
    $fail = 0
    $records = New-Object System.Collections.ArrayList
    $heatRows = New-Object System.Collections.ArrayList
    $i = 0

    foreach ($bvid in $queue) {
        $i++
        try {
            $uri = 'https://api.bilibili.com/x/web-interface/view/detail?bvid=' + $bvid
            $resp = Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 20
            if ($resp.code -ne 0) {
                $fail++
                Write-Log ("  enrich {0}: api code {1}" -f $bvid, $resp.code) 'WARN'
            } else {
                $rec = Convert-DetailRecord -Data $resp.data -Bvid $bvid
                if ($null -eq $rec) {
                    $fail++
                    Write-Log ("  enrich {0}: unusable payload" -f $bvid) 'WARN'
                } else {
                    [void]$records.Add($rec)
                    [void]$heatRows.Add([pscustomobject]@{
                        bvid = $rec.bvid; view = $rec.view; danmaku = $rec.danmaku; fav = $rec.favorite
                        reply = $rec.reply; like = $rec.like; coin = $rec.coin; share = $rec.share
                        source = 'detail'
                    })
                    $ok++
                }
            }
        } catch {
            $fail++
            Write-Log ("  enrich {0}: {1}" -f $bvid, $_.Exception.Message) 'WARN'
        }
        if ($i -lt $queue.Count -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }

    if ($records.Count -gt 0) {
        $dm = Merge-DetailSnapshot -Path $DetailFile -Records $records
        Write-Log ("enrich details: total={0} added={1} updated={2}" -f $dm.Total, $dm.Added, $dm.Updated)
    }
    if ($HeatOn -and $heatRows.Count -gt 0) {
        $hr = Merge-HeatSnapshot -Path $HeatFile -Rows $heatRows -MaxRows $HeatMaxRows
        Write-Log ("enrich heat: added={0} updated={1}" -f $hr.Added, $hr.Updated)
    }
    return [pscustomobject]@{ Requested = $queue.Count; Ok = $ok; Fail = $fail; DetailFile = $DetailFile }
}

# ---------------------------------------------------------------- main

Write-Log ("=== start | mode={0} port={1} maxpages={2} ===" -f $(if ($Login) {'login'} elseif ($Status) {'status'} else {'collect'}), $Port, $MaxPages)

if (-not (Test-Path $EdgeExe)) { Write-Log "Edge not found at $EdgeExe" 'ERROR'; exit 2 }

$browser = $null
try {
    if ($Login) {
        Write-Log 'Opening a dedicated Edge window. Scan the QR code there to log in to Bilibili.'
        $browser = Start-Browser -Url $HomeUrl -Visible
        $null = Wait-CdpReady -Port $Port
        $ws = $null
        $deadline = (Get-Date).AddSeconds($LoginTimeoutSec)
        $ok = $false
        while ((Get-Date) -lt $deadline) {
            try {
                if (-not $ws -or $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                    if ($ws) { try { $ws.Dispose() } catch { } }
                    $ses = Connect-PageSession -Port $Port -Url $HomeUrl
                    $ws = $ses.Ws
                    Write-Log ("page ready: {0}" -f $ses.Href)
                }
                Start-Sleep -Seconds 3
                $raw = Invoke-Js -Ws $ws -Expression $JsLoginCheck -TimeoutMs 20000
                $st = $raw | ConvertFrom-Json
                if ($st.isLogin) {
                    Write-Log ("Login detected: mid={0} uname={1}" -f $st.mid, $st.uname)
                    $ok = $true
                    break
                }
                Write-Log ("still waiting for login (code={0}) ..." -f $st.code)
            }
            catch {
                Write-Log ("poll error: {0}" -f $_.Exception.Message) 'WARN'
                if ($ws) { try { $ws.Dispose() } catch { } }
                $ws = $null
                if (-not (Test-BrowserAlive -ProfileDir $ProfileDir)) {
                    Write-Log 'browser window is gone; relaunching it.' 'WARN'
                    $browser = Start-Browser -Url $HomeUrl -Visible
                    $null = Wait-CdpReady -Port $Port
                }
                Start-Sleep -Seconds 2
            }
        }
        if ($ws) { try { $ws.Dispose() } catch { } }
        if (-not $ok) { Write-Log 'Login not detected before timeout.' 'ERROR' }
        Stop-Browser -Port $Port -Proc $browser
        if ($ok) { exit 0 } else { exit 3 }
    }

    $browser = Start-Browser -Url $HomeUrl -Visible:$false
    $null = Wait-CdpReady -Port $Port

    if ($Probe) {
        # The URL is interpolated into a single-quoted JS string, so escape the
        # string metacharacters instead of pasting the raw value.
        $probeLiteral = $Probe.Replace('\', '\\').Replace("'", "\'").Replace("`r", '\r').Replace("`n", '\n')
        $expr = $JsProbe.Replace('__URL__', $probeLiteral).Replace('__LIMIT__', '3000')
        $raw = Invoke-JsRetry -Port $Port -Expression $expr -TimeoutMs 60000
        Write-Host $raw
        Write-Log ('probe: ' + $Probe + ' -> ' + $raw)
        Stop-Browser -Port $Port -Proc $browser
        exit 0
    }

    if ($Dms) {
        # Own-account DM export. Local only: the text also contains the other
        # party's words, so it is excluded from backups and sharing payloads.
        $surl = 'https://api.vc.bilibili.com/session_svr/v1/session_svr/get_sessions?session_type=1&group_fold=1&unfollow_fold=0&sort_rule=2&build=0&mobi_app=web'
        $sEnv = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $surl).Replace('__LIMIT__', '4000000')) -TimeoutMs 90000) | ConvertFrom-Json
        $sj = $sEnv.body | ConvertFrom-Json
        if ($sj.code -ne 0) { Write-Log ("dm sessions failed: " + $sj.code) 'ERROR'; Stop-Browser -Port $Port -Proc $browser; exit 4 }
        $sessions = @($sj.data.session_list)
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $sbS = New-Object System.Text.StringBuilder
        $msgDir = Join-Path $DirDms 'messages'
        if (-not (Test-Path $msgDir)) { New-Item -ItemType Directory -Force -Path $msgDir | Out-Null }
        $taken = 0
        foreach ($s in $sessions) {
            if ($taken -ge $DmsLimit) { break }
            $taken++
            $talker = [int64]$s.talker_id
            $last = $s.last_msg
            $row = [pscustomobject]@{
                talker_id = $talker
                unread = [int]$s.unread_count
                last_ts = $(if ($last) { [int64]$last.timestamp } else { 0 })
                last_from_me = $(if ($last) { ([int64]$last.sender_uid -eq [int64]$st.mid) } else { $false })
                captured_at = $now
            }
            [void]$sbS.Append((($row | ConvertTo-Json -Compress)) + "`n")
            $murl = 'https://api.vc.bilibili.com/svr_sync/v1/svr_sync/fetch_session_msgs?talker_id=' + $talker + '&session_type=1&size=20&build=0&mobi_app=web'
            $mEnv = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $murl).Replace('__LIMIT__', '2000000')) -TimeoutMs 60000) | ConvertFrom-Json
            $mj = $mEnv.body | ConvertFrom-Json
            if ($mj.code -ne 0) { Write-Log ("  talker {0}: messages failed {1}" -f $talker, $mj.code) 'WARN'; continue }
            $sbM = New-Object System.Text.StringBuilder
            foreach ($m in @($mj.data.messages)) {
                $content = [string]$m.content
                if ($content.Length -gt 300) { $content = $content.Substring(0, 300) }
                $mrow = [pscustomobject]@{
                    ts = [int64]$m.timestamp
                    from_me = ([int64]$m.sender_uid -ne $talker)
                    type = [int]$m.msg_type
                    content = $content
                }
                [void]$sbM.Append((($mrow | ConvertTo-Json -Compress)) + "`n")
            }
            [System.IO.File]::WriteAllText((Join-Path $msgDir ($talker.ToString() + '.jsonl')), $sbM.ToString(), (New-Object System.Text.UTF8Encoding($false)))
            Start-Sleep -Milliseconds 400
        }
        [System.IO.File]::WriteAllText((Join-Path $DirDms $Ui.dmsSessionsFile), $sbS.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ("dm: {0} session(s) captured (limit {1})" -f $taken, $DmsLimit)
        Stop-Browser -Port $Port -Proc $browser
        Write-RunResult -Mode 'dms' -ExitCode 0 -Extra @{ sessions = $taken }
        exit 0
    }

    if ($WatchLater) {
        $wurl = 'https://api.bilibili.com/x/v2/history/toview'
        $wraw = Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $wurl).Replace('__LIMIT__', '2000000')) -TimeoutMs 90000
        $wEnv = $wraw | ConvertFrom-Json
        $wj = $wEnv.body | ConvertFrom-Json
        if ($wj.code -ne 0) { Write-Log ("watch-later failed: " + $wj.code) 'ERROR'; Stop-Browser -Port $Port -Proc $browser; exit 4 }
        $wItems = @($wj.data.list)
        $wNow = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $sbW = New-Object System.Text.StringBuilder
        foreach ($wIt in $wItems) {
            $wLine = $wIt | Select-Object *, @{ n = 'captured_at'; e = { $wNow } }
            [void]$sbW.Append((($wLine | ConvertTo-Json -Compress)) + "`n")
        }
        $wf = Join-Path $DirHistory $Ui.watchLaterFile
        [System.IO.File]::WriteAllText($wf, $sbW.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ("watch-later: {0} item(s) -> {1}" -f $wItems.Count, $wf)
        Stop-Browser -Port $Port -Proc $browser
        Write-RunResult -Mode 'watchlater' -ExitCode 0 -Extra @{ count = $wItems.Count }
        exit 0
    }

    if ($Follow) {
        $st = (Invoke-JsRetry -Port $Port -Expression $JsLoginCheck -TimeoutMs 30000) | ConvertFrom-Json
        if (-not $st.isLogin) { Write-Log 'not logged in' 'ERROR'; Stop-Browser -Port $Port -Proc $browser; exit 4 }
        $mid = [string]$st.mid

        $tagsUrl = 'https://api.bilibili.com/x/relation/tags?vmid=' + $mid
        $rj = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $tagsUrl).Replace('__LIMIT__', '2000000')) -TimeoutMs 60000) | ConvertFrom-Json
        $tj = $rj.body | ConvertFrom-Json
        if ($tj.code -ne 0) { Write-Log ('relation/tags failed: ' + $tj.code) 'ERROR'; Stop-Browser -Port $Port -Proc $browser; exit 4 }
        $groups = @($tj.data)
        Write-Log ('follow groups: {0}' -f $groups.Count)

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $DirFollow 'groups.json'), ($groups | ConvertTo-Json -Depth 5), $utf8)

        $members = New-Object System.Collections.ArrayList
        foreach ($g in $groups) {
            $tagId = [int64]$g.tagid
            if ($tagId -eq 0 -and -not $IncludeAllFollows) {
                Write-Log ('skip default group: {0} people (use -IncludeAllFollows)' -f $g.count)
                continue
            }
            $pn = 1
            $got = 0
            while ($pn -le 80) {
                $u = 'https://api.bilibili.com/x/relation/tag?tagid=' + $tagId + '&pn=' + $pn + '&ps=50&vmid=' + $mid
                $rr = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $u).Replace('__LIMIT__', '2000000')) -TimeoutMs 60000) | ConvertFrom-Json
                $bj = $rr.body | ConvertFrom-Json
                if ($bj.code -ne 0) { Write-Log ('group {0} page {1} failed: {2}' -f $g.name, $pn, $bj.code) 'WARN'; break }
                $list = @($bj.data)
                if ($list.Count -eq 0) { break }
                foreach ($m in $list) {
                    $off = -1
                    if ($m.official_verify) { $off = [int]$m.official_verify.type }
                    $vipType = 0
                    if ($m.vip) { $vipType = [int]$m.vip.vipType }
                    [void]$members.Add([pscustomobject]@{
                        tagid    = $tagId
                        tag      = [string]$g.name
                        mid      = [int64]$m.mid
                        uname    = [string]$m.uname
                        sign     = [string]$m.sign
                        official = $off
                        vip      = $vipType
                        # follow_time comes free in the same relation/tag response
                        # (the older single-user endpoint calls it mtime).
                        follow_time = [int64]$(if ($m.PSObject.Properties['follow_time']) { $m.follow_time } else { 0 })
                    })
                }
                $got += $list.Count
                if ($list.Count -lt 50) { break }
                $pn++
                Start-Sleep -Milliseconds 700
            }
            Write-Log ('group {0}: {1} member(s)' -f $g.name, $got)
            Start-Sleep -Milliseconds 600
        }

        # Follow time: the batch endpoint returns follow_time as null, so the
        # value only comes from /x/relation?fid= (field name mtime there). One
        # request per followed user, hence the per-run cap; members already
        # resolved are skipped, so a big account fills in over several runs.
        # Default 0 = off: this is the one place that costs a request per
        # followed user, so the public build leaves it to the user.
        $ftMax = 0
        if ($Cfg -and $Cfg.PSObject.Properties['FollowTimeMax'] -and $null -ne $Cfg.FollowTimeMax) { $ftMax = [int]$Cfg.FollowTimeMax }
        if ($ftMax -gt 0) {
            $need = @($members | Where-Object { [int64]$_.follow_time -le 0 })
            if ($need.Count -gt 0) {
                $todo = @($need | Select-Object -First $ftMax)
                Write-Log ('follow_time: {0} of {1} unknown, fetching {2}' -f $need.Count, $members.Count, $todo.Count)
                $okFt = 0
                $failFt = 0
                foreach ($m in $todo) {
                    try {
                        $ftUrl = 'https://api.bilibili.com/x/relation?fid=' + [string]$m.mid
                        $ftRaw = (Invoke-JsRetry -Port $Port -Expression ($JsProbe.Replace('__URL__', $ftUrl).Replace('__LIMIT__', '4000')) -TimeoutMs 30000) | ConvertFrom-Json
                        $ftJson = $ftRaw.body | ConvertFrom-Json
                        if ($ftJson.code -eq 0 -and $ftJson.data -and [int64]$ftJson.data.mtime -gt 0) {
                            $m.follow_time = [int64]$ftJson.data.mtime
                            $okFt++
                        }
                        else { $failFt++ }
                    }
                    catch { $failFt++ }
                    Start-Sleep -Milliseconds 700
                }
                Write-Log ('follow_time: ok={0} fail={1}' -f $okFt, $failFt)
            }
        }
        $sb = New-Object System.Text.StringBuilder
        foreach ($m in $members) { [void]$sb.Append((($m | ConvertTo-Json -Compress)) + "`n") }
        [System.IO.File]::WriteAllText((Join-Path $DirFollow 'members.jsonl'), $sb.ToString(), $utf8)
        Write-Log ('members written: {0}' -f $members.Count)

        # recent heavy rotation, derived from the local history archive
        $specialSet = @{}
        $tagOf = @{}
        foreach ($m in $members) {
            $un = [string]$m.uname
            if ($m.tagid -eq [int64](-10)) { $specialSet[$un] = $true }
            if (-not $tagOf.ContainsKey($un)) { $tagOf[$un] = [string]$m.tag }
        }

        $cutoff = [DateTimeOffset]::UtcNow.AddDays(-30).ToUnixTimeSeconds()
        $recent = @()
        foreach ($hf in Get-ChildItem $DirHistory -Filter '*.jsonl' -ErrorAction SilentlyContinue) {
            foreach ($line in [System.IO.File]::ReadLines($hf.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $rec = $line | ConvertFrom-Json } catch { continue }
                if ([int64]$rec.view_at -ge $cutoff -and $rec.author) { $recent += $rec }
            }
        }
        $hotUp = @()
        foreach ($g2 in ($recent | Group-Object author | Sort-Object Count -Descending | Select-Object -First 20)) {
            $secs = (($g2.Group | Where-Object { $_.progress -gt 0 } | Measure-Object progress -Sum).Sum)
            if (-not $secs) { $secs = 0 }
            $hotUp += [pscustomobject]@{
                author  = $g2.Name
                count   = $g2.Count
                hours   = [math]::Round($secs / 3600, 2)
                special = [bool]$specialSet[$g2.Name]
                tag     = [string]$tagOf[$g2.Name]
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $DirFollow 'recent-top30d.json'), ($hotUp | ConvertTo-Json -Depth 4), $utf8)
        Write-Log ('recent top uploaders (30d): {0}' -f $hotUp.Count)

        Stop-Browser -Port $Port -Proc $browser
        Write-RunResult -Mode 'follow' -ExitCode 0 -Extra @{ groups = $groups.Count; members = $members.Count; top30d = $hotUp.Count }
        Write-Log ('=== follow done | groups={0} members={1} ===' -f $groups.Count, $members.Count)
        exit 0
    }

    if ($FavFolders) {
        $ff = Get-FavFolders -Port $Port
        if ($null -eq $ff) { Write-Log "favfolders: failed" "ERROR"; Stop-Browser -Port $Port -Proc $browser; exit 4 }
        $raw = ($ff | ConvertTo-Json -Depth 4 -Compress)
        Stop-Browser -Port $Port -Proc $browser
        exit 0
    }

    if ($Fav) {
        $foldersRaw = Get-FavFolders -Port $Port
        if ($null -eq $foldersRaw) { throw "folder list failed" }
        $folders = @($foldersRaw)
        $fj = [pscustomobject]@{ ok = $true }
        if ($FavOnly -and $FavOnly.Count -gt 0) {
            $folders = @($folders | Where-Object {
                $hit = $false
                foreach ($pat in $FavOnly) { if ($_.title -like "*$pat*") { $hit = $true } }
                $hit
            })
        }
        # Weight every folder: 0 = skip by default, 3 = refresh first. The rules
        # live in config.json (FolderWeight), so no personal folder name is baked
        # into this script or into the example config.
        foreach ($f in $folders) {
            $wf = Get-FolderWeight -Cfg $Cfg -Name ([string]$f.title)
            $f | Add-Member -NotePropertyName weight -NotePropertyValue $wf -Force
        }
        if (-not $IncludeLow -and -not $Force) {
            $before = $folders.Count
            $folders = @($folders | Where-Object { [int]$_.weight -gt 0 })
            if ($before -ne $folders.Count) {
                Write-Log ("weight filter: skipped {0} folder(s) with weight 0" -f ($before - $folders.Count))
            }
        }
        # Higher weight first, then the user's stated folder order, so a -Top run
        # refreshes what matters and the low-value tail can wait.
        $prio = @()
        if ($Cfg.FolderPriority) { $prio = @($Cfg.FolderPriority) }
        $folders = @($folders | Sort-Object -Property @{ Expression = { - [int]$_.weight } }, @{ Expression = {
                $t = [string]$_.title
                $r = 999
                for ($pi = 0; $pi -lt $prio.Count; $pi++) {
                    if ($t -like ('*' + $prio[$pi] + '*')) { $r = $pi; break }
                }
                $r
            } })
        Write-Log ('priority order: ' + (($folders | ForEach-Object { $_.title }) -join ' > '))
        if ($Top -gt 0 -and $folders.Count -gt $Top) {
            $folders = @($folders | Select-Object -First $Top)
            Write-Log ('-Top {0}: only the first {1} folder(s) this run' -f $Top, $folders.Count)
        }
        Write-Log ("fav mode: {0} folder(s) selected, cover={1}" -f $folders.Count, (-not $NoCover))
        if ($folders.Count -eq 0) { Write-Log 'no folder matched -FavOnly or filters' 'ERROR'; Stop-Browser -Port $Port -Proc $browser; exit 5 }

        if ($FavCheck) { $NoCover = $true }
        $w = if ($CoverWidth -gt 0) { $CoverWidth } elseif ($Cfg -and $Cfg.CoverWidth) { [int]$Cfg.CoverWidth } else { 320 }
        $favRes = Invoke-FavCollect -Port $Port -Folders $folders -MaxPages $FavMaxPages -CoverWidth $w -WithCover (-not $NoCover) -Force:$Force
        Stop-Browser -Port $Port -Proc $browser
        if ($Enrich) {
            $em = if ($EnrichMax -gt 0) { $EnrichMax } else { $EnrichBudget }
            $ed = if ($EnrichDelayMs -gt 0) { $EnrichDelayMs } else { $EnrichDelay }
            $en = Invoke-Enrich -Max $em -DelayMs $ed
            Write-Log ("=== enrich done | requested={0} ok={1} fail={2} ===" -f $en.Requested, $en.Ok, $en.Fail)
        }
        Write-Log ("=== fav done | total={0} new={1} ===" -f $favRes.Total, $favRes.New)
        Write-RunResult -Mode 'fav' -ExitCode 0 -Extra @{ total = $favRes.Total; added = $favRes.New; folders = $folders.Count }
        exit 0
    }

    if ($Status) {
        $raw = Invoke-JsRetry -Port $Port -Expression $JsLoginCheck -TimeoutMs 30000
        Write-Host $raw
        Write-Log ("status: " + $raw)
        Stop-Browser -Port $Port -Proc $browser
        exit 0
    }

    $state = Read-State
    $since = 0
    if (-not $Full -and $state.lastViewAt -gt 0) {
        # Overlap by 120s: two records can share the boundary second, and the
        # on-disk dedupe makes the overlap cost nothing.
        $since = [int64]$state.lastViewAt - 120
        if ($since -lt 0) { $since = 0 }
    }
    Write-Log ("incremental cursor: since={0} (0 = full scan)" -f $since)

    $expr = $JsCollect.Replace('__MAX_PAGES__', [string]$MaxPages).Replace('__SINCE__', [string]$since)
    $raw = Invoke-JsRetry -Port $Port -Expression $expr -TimeoutMs 300000
    Stop-Browser -Port $Port -Proc $browser

    $res = $raw | ConvertFrom-Json
    if (-not $res.ok) {
        Write-Log ("collect failed: error={0} code={1} message={2}" -f $res.error, $res.code, $res.message) 'ERROR'
        exit 4
    }

    $records = @($res.list)
    Write-Log ("fetched {0} record(s) over {1} page(s); mid={2} uname={3}" -f $records.Count, $res.pages, $res.mid, $res.uname)

    $n = 0
    if ($records.Count -gt 0) {
        $ap = Append-Records -Records $records
        Write-Log ("appended {0} record(s), skipped {1} already on disk" -f $ap.Written, $ap.Skipped)
        $n = $ap.Written
        $newest = ($records | ForEach-Object { [int64]$_.view_at } | Measure-Object -Maximum).Maximum
        if ($newest -gt $state.lastViewAt) { $state.lastViewAt = $newest }
        $state.total = $state.total + $n
        $state.mid = [int64]$res.mid
    } else {
        Write-Log 'no new records (nothing watched since last run, or cursor caught up).'
    }
    $state.lastRun = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-State -State $state
    Write-Log ("=== done | total={0} lastViewAt={1} ===" -f $state.total, $state.lastViewAt)
    if ($Enrich) {
        $em = if ($EnrichMax -gt 0) { $EnrichMax } else { $EnrichBudget }
        $ed = if ($EnrichDelayMs -gt 0) { $EnrichDelayMs } else { $EnrichDelay }
        $en = Invoke-Enrich -Max $em -DelayMs $ed
        Write-Log ("=== enrich done | requested={0} ok={1} fail={2} ===" -f $en.Requested, $en.Ok, $en.Fail)
    }
    Write-RunResult -Mode 'history' -ExitCode 0 -Extra @{
        fetched = $records.Count; written = $n; total = $state.total; lastViewAt = $state.lastViewAt; pages = $res.pages
    }
    exit 0
}
catch {
    Write-Log ("FATAL: " + $_.Exception.Message) 'ERROR'
    if ($browser) { try { Stop-Browser -Port $Port -Proc $browser } catch { } }
    exit 1
}
