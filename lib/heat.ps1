#requires -version 5.1
<#
  Heat (counter) snapshots. One JSON object per line, one line per video per day.

  Why a separate file instead of fields on the master row: the same video gets
  sampled again tomorrow, and what matters is the curve, not the latest value.
  Keeping it append-only also means a broken run cannot corrupt the master table.

  Line shape (UTF-8, no BOM):
    {"bvid":"BV1xx","date":"2026-10-27","ts":1761612345,
     "view":1639179,"danmaku":515,"fav":50419,"source":"fav"}

  Dedupe key: bvid + date. Same day => the line is replaced in place (counters
  only move forward); a new day => a new line is appended.

  Size guard: MaxRows caps how many NEW rows one run may add, so a library of
  14k favourites does not grow the file by 14k lines every single day. Updates
  to rows that are already there are never capped.
#>

function Get-HeatKey {
    param([string]$Bvid, [string]$Date)
    return $Bvid + '|' + $Date
}

function Get-HeatLastDates {
    <#
      bvid -> newest snapshot date already on disk. Used to rotate the row
      budget: the videos sampled longest ago (or never) go first, so a capped
      run does not starve the same tail every single day.
    #>
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o -or -not $o.PSObject.Properties['bvid'] -or -not $o.bvid) { continue }
        $b = [string]$o.bvid
        $d = if ($o.PSObject.Properties['date']) { [string]$o.date } else { '' }
        if (-not $map.ContainsKey($b) -or $d -gt $map[$b]) { $map[$b] = $d }
    }
    return $map
}

function Merge-HeatSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [string]$Date = '',
        [string]$Source = 'fav',
        [int]$MaxRows = 0
    )

    if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $order = New-Object System.Collections.ArrayList
    $map = @{}
    if (Test-Path $Path) {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o -or -not $o.PSObject.Properties['bvid']) { continue }
            $d = if ($o.PSObject.Properties['date']) { [string]$o.date } else { '' }
            $k = Get-HeatKey ([string]$o.bvid) $d
            if (-not $map.ContainsKey($k)) { [void]$order.Add($k) }
            $map[$k] = $o
        }
    }

    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $added = 0
    $updated = 0
    $skipped = 0

    foreach ($r in $Rows) {
        if (-not $r -or -not $r.bvid) { continue }
        $k = Get-HeatKey ([string]$r.bvid) $Date
        $isNew = -not $map.ContainsKey($k)
        if ($isNew -and $MaxRows -gt 0 -and $added -ge $MaxRows) { $skipped++; continue }

        $view = 0; $dm = 0; $favn = 0
        if ($null -ne $r.view) { $view = [int64]$r.view }
        if ($null -ne $r.danmaku) { $dm = [int64]$r.danmaku }
        if ($null -ne $r.fav) { $favn = [int64]$r.fav }
        $src = if ($r.source) { [string]$r.source } else { $Source }

        $rec = [ordered]@{
            bvid    = [string]$r.bvid
            date    = $Date
            ts      = $ts
            view    = $view
            danmaku = $dm
            fav     = $favn
            source  = $src
        }
        # The richer rows (source = detail) also carry the remaining counters.
        # Rows without them stay small on purpose - the favourites response has
        # no reply/like/coin/share at all.
        foreach ($extra in @('reply', 'like', 'coin', 'share')) {
            if ($r.PSObject.Properties[$extra] -and $null -ne $r.$extra) {
                $rec[$extra] = [int64]$r.$extra
            }
        }

        if ($isNew) { [void]$order.Add($k); $added++ } else { $updated++ }
        $map[$k] = $rec
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $order) {
        [void]$sb.Append(($map[$k] | ConvertTo-Json -Depth 4 -Compress) + "`n")
    }

    # Write to a temp file and swap, so an interrupted run cannot leave the
    # snapshot half-written.
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $sb.ToString(), $utf8)
    if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force

    return [pscustomobject]@{
        Added   = $added
        Updated = $updated
        Skipped = $skipped
        Total   = $order.Count
        File    = $Path
    }
}
