#requires -version 5.1
<#
  Cold backup: text-only snapshot of the Bilibili archive to a second disk.
  Covers are excluded on purpose - they are ~90% of the bytes and rebuildable,
  while the metadata is the part that cannot be recreated once a video dies.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup-cold.ps1
    ... -File .\backup-cold.ps1 -Keep 6
#>
[CmdletBinding()]
param(
    [int]$Keep = 8
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

$DataRoot = $Cfg.DataRoot
if (-not $DataRoot) { throw 'config.json has no DataRoot.' }
$Target = $Cfg.ColdBackup
if (-not $Target) { throw 'config.json has no ColdBackup.' }
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }

$h1 = Join-Path $DataRoot $Cfg.Dirs.History
$h2 = Join-Path $DataRoot $Cfg.Dirs.Fav
if (-not (Test-Path $h1)) { throw "History folder missing: $h1" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$zip = Join-Path $Target ("bili-archive-$stamp.zip")

$stage = Join-Path $env:TEMP ("bili-cold-" + $stamp)
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item (Join-Path $h1 '*.jsonl') $stage -ErrorAction SilentlyContinue
Copy-Item (Join-Path $h1 'state.json') $stage -ErrorAction SilentlyContinue
if (Test-Path $h2) {
    $sub = Join-Path $stage 'favorites'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Copy-Item (Join-Path $h2 '*.jsonl') $sub -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $h2 '*.md') $sub -ErrorAction SilentlyContinue
}

$files = Get-ChildItem $stage -Recurse -File
if ($files.Count -eq 0) { Write-Host 'nothing to back up'; exit 0 }

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Remove-Item $stage -Recurse -Force

$sizeKb = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Host ("backup written: {0} ({1} KB from {2} file(s))" -f $zip, $sizeKb, $files.Count)

$old = Get-ChildItem $Target -Filter 'bili-archive-*' | Where-Object { $_.Name -match '^bili-archive-\d{8}-\d{4}\.zip$' } |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep
foreach ($o in $old) {
    Remove-Item $o.FullName -Force
    Write-Host ("pruned old backup: {0}" -f $o.Name)
}
