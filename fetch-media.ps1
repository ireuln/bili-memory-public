#requires -version 5.1
<#
  One-shot media capture for a single video:

    - top comments   : x/v2/reply/wbi/main with mode=3 (hot order)
    - danmaku list   : x/v1/dm/list.so?oid=<cid> (full pool, ordered by time)

  Output (inside the optional content layer):
    <DataRoot>\<content>\<BV>\hot-comments.jsonl
    <DataRoot>\<content>\<BV>\danmaku.jsonl
    <DataRoot>\<content>\<BV>\media-meta.json

  Cost: 2-3 requests per video, deliberately low frequency. Nothing is uploaded.

  ASCII-only on purpose: Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fetch-media.ps1 -Bvid BV1xxxxxxxxx
    ... -Bvid BV1xxxxxxxxx -Hot 20 -NoDanmaku
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Bvid,
    [int]$Hot = 50,
    [switch]$NoDanmaku,
    [int]$DelayMs = 500
)

$ErrorActionPreference = 'Stop'
try {
    $script:OutEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $script:OutEncoding
    $OutputEncoding = $script:OutEncoding
} catch { }

$Root = Split-Path -Parent $PSCommandPath
$Cfg = [System.IO.File]::ReadAllText((Join-Path $Root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$DataRoot = [string]$Cfg.DataRoot
$ContentName = 'content'
if ($Cfg.Dirs.PSObject.Properties['Content'] -and $Cfg.Dirs.Content) { $ContentName = [string]$Cfg.Dirs.Content }
$ContentRoot = Join-Path $DataRoot $ContentName
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Accept a BV id or a full video URL.
$Bvid = $Bvid.Trim()
if ($Bvid -match '/video/(BV[0-9A-Za-z]+)') { $Bvid = $Matches[1] }
if ($Bvid -notmatch '^BV[0-9A-Za-z]+$') { Write-Host 'invalid BV id'; exit 2 }

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$h = @{ 'User-Agent' = $ua; 'Referer' = 'https://www.bilibili.com/' }
$T = @(46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52)
function Mix([string]$i, [string]$s) { $r = $i + $s; $sb = New-Object System.Text.StringBuilder; foreach ($x in $T) { [void]$sb.Append($r[$x]) }; $sb.ToString().Substring(0, 32) }
function Sign([hashtable]$P, [string]$mk) {
    $o = @{}; foreach ($k in $P.Keys) { $o[$k] = [string]$P[$k] }
    $o['wts'] = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $parts = New-Object System.Collections.ArrayList
    foreach ($k in ($o.Keys | Sort-Object)) { $v = [regex]::Replace([string]$o[$k], "[!'()*]", ''); [void]$parts.Add($k + '=' + [Uri]::EscapeDataString($v)) }
    $q = $parts -join '&'
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $b = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($q + $mk)) } finally { $md5.Dispose() }
    $q + '&w_rid=' + ([BitConverter]::ToString($b)).Replace('-', '').ToLowerInvariant()
}
function Get-Json([string]$Url) {
    try {
        $r = Invoke-WebRequest -Uri $Url -Headers $h -TimeoutSec 25 -UseBasicParsing
        $o = $null; try { $o = $r.Content | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ status = [int]$r.StatusCode; obj = $o }
    } catch {
        $sc = -1; try { $sc = [int]($_.Exception.Response.StatusCode) } catch { }
        return [pscustomobject]@{ status = $sc; obj = $null }
    }
}

# --- resolve the video -------------------------------------------------------
$view = Get-Json ('https://api.bilibili.com/x/web-interface/view?bvid=' + $Bvid)
if (-not $view.obj -or $view.obj.code -ne 0) { Write-Host ('view failed for ' + $Bvid); exit 3 }
$title = [string]$view.obj.data.title
$aid = [string]$view.obj.data.aid
$cid = [string]$view.obj.data.cid
Write-Host ('video ' + $Bvid + '  aid=' + $aid + '  cid=' + $cid)
Write-Host ('title ' + $title)

$outDir = Join-Path $ContentRoot $Bvid
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- hot comments (mode=3) ---------------------------------------------------
$hotFile = Join-Path $outDir 'hot-comments.jsonl'
$hotCount = 0
if ($Hot -gt 0) {
    $nav = Get-Json 'https://api.bilibili.com/x/web-interface/nav'
    # Anonymous nav returns code=-101 but still carries wbi_img; only the key matters.
    if ($nav.obj -and $nav.obj.data -and $nav.obj.data.wbi_img) {
        $mk = Mix (([string]$nav.obj.data.wbi_img.img_url).Split('/')[-1].Split('.')[0]) (([string]$nav.obj.data.wbi_img.sub_url).Split('/')[-1].Split('.')[0])
        $q = Sign @{ oid = $aid; type = '1'; mode = '3'; pagination_str = '{"offset":""}'; plat = '1'; web_location = '1315875' } $mk
        $resp = Get-Json ('https://api.bilibili.com/x/v2/reply/wbi/main?' + $q)
        if ($resp.obj -and $resp.obj.code -eq 0) {
            $rows = New-Object System.Collections.ArrayList
            $seen = @{}
            # Pinned replies first, then the hot page.
            foreach ($r in @($resp.obj.data.top_replies) + @($resp.obj.data.replies)) {
                if (-not $r) { continue }
                $id = [string]$r.rpid
                if (-not $id -or $seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                [void]$rows.Add([ordered]@{
                    rpid  = $id
                    uname = [string]$r.member.uname
                    ctime = [int64]$r.ctime
                    like  = [int64]$r.like
                    msg   = [string]$r.content.message
                })
                if ($rows.Count -ge $Hot) { break }
            }
            $sb = New-Object System.Text.StringBuilder
            foreach ($row in $rows) { [void]$sb.AppendLine(($row | ConvertTo-Json -Compress)) }
            [System.IO.File]::WriteAllText($hotFile, $sb.ToString(), $utf8)
            $hotCount = $rows.Count
            Write-Host ('hot comments: ' + $hotCount)
        } else {
            Write-Host ('hot comments failed: code=' + $(if ($resp.obj) { $resp.obj.code } else { 'http ' + $resp.status }))
        }
    } else {
        Write-Host 'hot comments skipped: nav/wbi key unavailable'
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

# --- danmaku (full public pool) ---------------------------------------------
$danmakuFile = Join-Path $outDir 'danmaku.jsonl'
$dmCount = 0
if (-not $NoDanmaku -and $cid) {
    try {
        $r = Invoke-WebRequest -Uri ('https://api.bilibili.com/x/v1/dm/list.so?oid=' + $cid) -Headers $h -TimeoutSec 30 -UseBasicParsing
        $xml = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $sb = New-Object System.Text.StringBuilder
        foreach ($m in [regex]::Matches($xml, '<d p="([^"]+)">([^<]*)</d>')) {
            $parts = $m.Groups[1].Value.Split(',')
            if ($parts.Count -lt 2) { continue }
            $text = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
            $row = [ordered]@{
                t     = [math]::Round([double]$parts[0], 3)
                mode  = [int]$parts[1]
                size  = [int]$parts[2]
                color = [int]$parts[3]
                text  = $text
            }
            [void]$sb.AppendLine(($row | ConvertTo-Json -Compress))
            $dmCount++
        }
        [System.IO.File]::WriteAllText($danmakuFile, $sb.ToString(), $utf8)
        Write-Host ('danmaku: ' + $dmCount)
    } catch {
        Write-Host ('danmaku failed: ' + $_.Exception.Message)
    }
} else {
    Write-Host 'danmaku skipped'
}

# --- meta --------------------------------------------------------------------
$meta = [ordered]@{
    bvid    = $Bvid
    title   = $title
    aid     = $aid
    cid     = $cid
    fetched = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    hot     = $hotCount
    danmaku = $dmCount
}
[System.IO.File]::WriteAllText((Join-Path $outDir 'media-meta.json'), ($meta | ConvertTo-Json -Depth 3), $utf8)
Write-Host ('saved to ' + $outDir)
exit 0
