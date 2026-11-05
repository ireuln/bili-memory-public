#requires -version 5.1
<#
  Download original (high-res) covers for every favourite.

  Source: the "cover" field of the favourites master table, which already
  points at the original image (i0/i1/i2.hdslb.com/bfs/archive/....jpg) - no
  extra API call per video is needed.

  Output: <DataRoot>\<Dirs.HdCover>\<upper_mid>\<bvid>.jpg
  Existing files are skipped, so the script can be interrupted and resumed.
  Rate limited on purpose: this is an image CDN, still be gentle.

  Usage:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fetch-covers-hd.ps1 -Limit 20
    ... -Limit 0            # everything (about 12k images, ~1.7 GB)
    ... -DryRun             # report what would be downloaded
    ... -DelayMs 500
#>
[CmdletBinding()]
param(
    [int]$Limit = 0,
    [string]$Folder = '',
    [int]$DelayMs = 300,
    [int]$Width = 0,
    [switch]$DryRun
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
$FavDir = Join-Path $DataRoot ([string]$Cfg.Dirs.Fav)
$HdName = 'covers-hd'
if ($Cfg.Dirs.PSObject.Properties['HdCover'] -and $Cfg.Dirs.HdCover) { $HdName = [string]$Cfg.Dirs.HdCover }
$HdDir = Join-Path $DataRoot $HdName
$Master = 'favourites.jsonl'
if ($Cfg.Text -and $Cfg.Text.masterFile) { $Master = [string]$Cfg.Text.masterFile }
$MasterPath = Join-Path $FavDir $Master
if (-not (Test-Path $MasterPath)) { throw ('master table not found: ' + $MasterPath) }

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$hdr = @{ 'User-Agent' = $ua; 'Referer' = 'https://www.bilibili.com/' }

if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $HdDir | Out-Null }

# Preferred HD width: 0 keeps the original image. Bilibili's image CDN accepts
# a "@<width>w.<ext>" suffix (verified 2026-11: 1632x918 -> 1280x720, ~40% less).
if ($Width -le 0 -and $Cfg.PSObject.Properties['HdCoverWidth'] -and $null -ne $Cfg.HdCoverWidth) {
    $Width = [int]$Cfg.HdCoverWidth
}
if ($Width -lt 0) { $Width = 0 }

$total = 0; $have = 0; $todo = 0; $ok = 0; $fail = 0; $bytes = 0
$failList = New-Object System.Collections.ArrayList
$reader = New-Object System.IO.StreamReader($MasterPath, [System.Text.Encoding]::UTF8)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $bvid = [string]$o.bvid
        $mid = [string]$o.upper_mid
        $cover = [string]$o.cover
        if (-not $bvid -or -not $cover) { continue }
        if ($Folder -and ([string]$o.folder) -ne $Folder) { continue }
        $total++
        if (-not $mid) { $mid = '0' }
        $targetDir = Join-Path $HdDir $mid
        $target = Join-Path $targetDir ($bvid + '.jpg')
        $dlUrl = $cover
        if ($Width -gt 0) {
            $ext = [System.IO.Path]::GetExtension($cover)
            if (-not $ext) { $ext = '.jpg' }
            $dlUrl = $cover + '@' + $Width + 'w' + $ext
        }
        if (Test-Path $target) { $have++; continue }
        if ($Limit -gt 0 -and $todo -ge $Limit) { break }
        $todo++
        if ($DryRun) { continue }
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        $done = $false
        for ($try = 0; $try -lt 3 -and -not $done; $try++) {
            try {
                Invoke-WebRequest -Uri $dlUrl -OutFile $target -Headers $hdr -TimeoutSec 30
                $done = $true
            } catch {
                Start-Sleep -Milliseconds (300 + $try * 400)
            }
        }
        if ($done) {
            $ok++
            $bytes += [int64](Get-Item $target).Length
        } else {
            $fail++
            [void]$failList.Add($bvid)
            if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
        }
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds ($DelayMs + (Get-Random -Minimum 0 -Maximum 100)) }
    }
} finally {
    $reader.Dispose()
}

$mb = [math]::Round($bytes / 1MB, 1)
Write-Host ('covers-hd: total={0} have={1} fetched={2} ok={3} fail={4} new={5} MB' -f $total, $have, $todo, $ok, $fail, $mb)
if ($failList.Count -gt 0) {
    Write-Host ('failed: ' + (($failList | Select-Object -First 10) -join ', '))
    exit 1
}
Write-Host ('target: ' + $HdDir)
exit 0
