#requires -version 5.1
<#
  Per-video detail enrichment.

  Source: GET /x/web-interface/view/detail?bvid=...  (public, no cookies needed)
  One request returns everything we cannot get for free elsewhere:
    - full description (the favourites list truncates it to 120 chars)
    - uploader avatar URL
    - 8 counters (view / danmaku / reply / like / coin / favorite / share)
    - source resolution (dimension) - NOT the playable quality tiers
    - the auto-recognised song, as a tag with tag_type = 'bgm' plus a music_id

  Cost: one request per video, ~300 KB. Never call this in a loop without a
  budget - see Select-EnrichQueue and EnrichMax in config.json.

  Output: <DataRoot>/<Detail>/details.jsonl, one line per bvid (latest wins).
  Counters are NOT stored here - they belong to the heat time series.
#>

function Convert-DetailRecord {
    <#
      Flattens the view/detail response into the small shape we store.
      Returns $null when the response is not usable.
    #>
    [CmdletBinding()]
    param($Data, [string]$Bvid = '')

    if (-not $Data) { return $null }
    $v = $Data.View
    if (-not $v) { return $null }

    $st = $v.stat
    $dim = $v.dimension
    $own = $v.owner

    $song = ''
    $music = ''
    foreach ($t in @($Data.Tags)) {
        if (-not $t) { continue }
        if ($t.tag_type -eq 'bgm') {
            $song = [string]$t.tag_name
            $music = [string]$t.music_id
            break
        }
    }

    $rec = [ordered]@{
        bvid       = [string]$(if ($v.bvid) { $v.bvid } else { $Bvid })
        title      = [string]$v.title
        desc       = [string]$v.desc
        pubdate    = [int64]$(if ($v.pubdate) { $v.pubdate } else { 0 })
        tname      = [string]$v.tname
        owner      = [string]$(if ($own) { $own.name } else { '' })
        owner_mid  = [int64]$(if ($own) { $own.mid } else { 0 })
        owner_face = [string]$(if ($own) { $own.face } else { '' })
        width      = [int]$(if ($dim) { $dim.width } else { 0 })
        height     = [int]$(if ($dim) { $dim.height } else { 0 })
        rotate     = [int]$(if ($dim) { $dim.rotate } else { 0 })
        song       = $song
        music_id   = $music
        view       = [int64]$(if ($st) { $st.view } else { 0 })
        danmaku    = [int64]$(if ($st) { $st.danmaku } else { 0 })
        reply      = [int64]$(if ($st) { $st.reply } else { 0 })
        like       = [int64]$(if ($st) { $st.like } else { 0 })
        coin       = [int64]$(if ($st) { $st.coin } else { 0 })
        favorite   = [int64]$(if ($st) { $st.favorite } else { 0 })
        share      = [int64]$(if ($st) { $st.share } else { 0 })
    }
    return [pscustomobject]$rec
}

function Read-DetailMap {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o -or -not $o.PSObject.Properties['bvid'] -or -not $o.bvid) { continue }
        $map[[string]$o.bvid] = $o
    }
    return $map
}

function Select-EnrichQueue {
    <#
      Picks the next batch. Never-enriched first, then the ones enriched longest
      ago, so the whole library rotates without a cursor file.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [hashtable]$Details = @{},
        [int]$Max = 300
    )
    if ($Max -le 0) { return @() }

    $scored = foreach ($c in $Candidates) {
        if (-not $c -or -not $c.bvid) { continue }
        $b = [string]$c.bvid
        $at = ''
        if ($Details.ContainsKey($b)) {
            $d = $Details[$b]
            if ($d.PSObject.Properties['enriched_at']) { $at = [string]$d.enriched_at }
        }
        [pscustomobject]@{
            bvid = $b; enriched_at = $at
            weight = [int]$(if ($c.PSObject.Properties['weight']) { $c.weight } else { 1 })
            fav_time = [int64]$(if ($c.fav_time) { $c.fav_time } else { 0 })
        }
    }

    $ordered = @($scored) | Sort-Object -Property @(
        @{ Expression = { - $_.weight } },                             # high-weight folders first
        @{ Expression = { if ($_.enriched_at) { 1 } else { 0 } } },   # never-enriched (0) first
        @{ Expression = { $_.enriched_at } },                          # oldest first
        @{ Expression = { $_.fav_time }; Descending = $true }          # newest saved as tie-break
    )
    return @($ordered | Select-Object -First $Max | ForEach-Object { $_.bvid })
}

function Merge-DetailSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Records = @(),
        [string]$Now = ''
    )
    if (-not $Now) { $Now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $order = New-Object System.Collections.ArrayList
    $map = [ordered]@{}
    if (Test-Path $Path) {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o -or -not $o.PSObject.Properties['bvid'] -or -not $o.bvid) { continue }
            $b = [string]$o.bvid
            if (-not $map.Contains($b)) { [void]$order.Add($b) }
            $map[$b] = $o
        }
    }

    $added = 0
    $updated = 0
    foreach ($r in $Records) {
        if (-not $r -or -not $r.bvid) { continue }
        $b = [string]$r.bvid
        $copy = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        $copy['enriched_at'] = $Now
        $isNew = -not $map.Contains($b)
        if ($isNew) { [void]$order.Add($b); $added++ } else { $updated++ }
        $map[$b] = [pscustomobject]$copy
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $order) {
        [void]$sb.Append(($map[$b] | ConvertTo-Json -Depth 4 -Compress) + "`n")
    }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $sb.ToString(), $utf8)
    if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force

    return [pscustomobject]@{ Added = $added; Updated = $updated; Total = $order.Count; File = $Path }
}
