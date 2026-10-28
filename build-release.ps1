#requires -version 5.1
<#
  Build a portable distribution folder + zip.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
    ... -Version 0.1.1
    ... -NoZip

  Output:
    dist\bili-memory-<version>\        (copy this folder to a USB stick)
    dist\bili-memory-<version>.zip     (same content, one file)

  Never includes: config.json, backup-secret.json, status.json, run.lock,
  .secret-patterns, .git, dist.
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$NoZip
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
$InfoFile = Join-Path $Root 'version.json'
if (-not (Test-Path $InfoFile)) { throw 'version.json missing' }
$Info = [System.IO.File]::ReadAllText($InfoFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

if (-not $Version) { $Version = [string]$Info.version }
if (-not $Version) { throw 'version is empty' }

$Name = 'bili-memory-' + $Version
$Dist = Join-Path $Root 'dist'
$OutDir = Join-Path $Dist $Name
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$files = @(
    'start.cmd',
    'README.md',
    'LICENSE',
    'NOTICE.md',
    'SUPPORT.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'CHANGELOG.md',
    'llms.txt',
    'config.example.json',
    'version.json'
)
foreach ($f in $files) {
    $src = Join-Path $Root $f
    if (Test-Path $src) { Copy-Item $src $OutDir -Force }
}

$scripts = @(Get-ChildItem $Root -Filter '*.ps1' -File)
foreach ($s in $scripts) { Copy-Item $s.FullName $OutDir -Force }

# 'share' holds the card template (share\card.html); leaving it out made
# share.ps1 fail with "file not found" in every packaged build.
foreach ($dir in @('lang', 'lib', 'tools', 'assets', 'docs', 'share')) {
    $src = Join-Path $Root $dir
    if (Test-Path $src) { Copy-Item $src (Join-Path $OutDir $dir) -Recurse -Force }
}

# --- encoding guard ---------------------------------------------------------
# PowerShell 5.1 reads a BOM-less .ps1 with the ANSI code page. A Chinese
# literal in such a file becomes mojibake, which is exactly how the tray menu
# came to launch "B鍗拌薄.exe" and throw "the system cannot find the file".
# Rule: any script that contains non-ASCII ships with a UTF-8 BOM.
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$bomFixed = 0
Get-ChildItem $OutDir -Recurse -File -Filter '*.ps1' | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $offset = 0
    if ($hasBom) { $offset = 3 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $nonAscii = ($text -match '[^\x00-\x7F]')
    if ($nonAscii -and -not $hasBom) {
        [System.IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
        $bomFixed++
    }
}
if ($bomFixed -gt 0) { Write-Host ('encoding guard: ' + $bomFixed + ' script(s) re-saved with UTF-8 BOM') }

# Thin GUI launchers (C# wrappers around start.cmd / uninstall.ps1).
$exeBuilder = Join-Path $Root 'build-exe.ps1'
if (Test-Path $exeBuilder) {
    try { & $exeBuilder } catch { Write-Host ('EXE build skipped: ' + $_.Exception.Message) -ForegroundColor Yellow }
}
$binDir = Join-Path $Root 'bin'
if (Test-Path $binDir) {
    Get-ChildItem $binDir -Filter '*.exe' -File | Copy-Item -Destination $OutDir -Force
}

$commit = 'unknown'
$gitExe = ''
foreach ($g in @('git', 'C:\Program Files\Git\cmd\git.exe')) {
    try { $null = & $g --version 2>$null; $gitExe = $g; break } catch { }
}
if ($gitExe) {
    try { $commit = (& $gitExe -C $Root rev-parse --short HEAD 2>$null) } catch { }
}
if (-not $commit) { $commit = 'unknown' }
$build = @(
    'B-Impression portable build',
    '',
    ('version : ' + $Version),
    ('commit  : ' + $commit),
    ('built   : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
    ('repo    : ' + $Info.repo),
    ('releases: ' + $Info.releases),
    '',
    'Update:',
    '  1. download the latest release zip from the releases URL above',
    '  2. close the tray icon',
    '  3. replace the scripts in this folder (keep config.json and your DataRoot)',
    '  4. run start.cmd again',
    '',
    'Do not copy config.json / backup-secret.json / login state between machines.'
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $OutDir 'BUILD-INFO.txt'), $build, (New-Object System.Text.UTF8Encoding($false)))

# Integrity manifest: the GUI launcher checks every file against this list on
# startup, so a quarantined/missing script is reported instead of failing silently.
$sums = New-Object System.Collections.ArrayList
Get-ChildItem $OutDir -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
    $rel = $_.FullName.Substring($OutDir.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$sums.Add($hash + '  ' + $rel)
}
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'SHA256SUMS.txt'), $sums, (New-Object System.Text.UTF8Encoding($false)))

if (-not $NoZip) {
    $zip = Join-Path $Dist ($Name + '.zip')
    if (Test-Path $zip) {
        try { Remove-Item $zip -Force -ErrorAction Stop }
        catch {
            $zip = Join-Path $Dist ($Name + '-' + $commit + '.zip')
            Write-Host ('target zip is locked; writing ' + $zip) -ForegroundColor Yellow
        }
    }
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $size = [math]::Round((Get-Item $zip).Length / 1MB, 2)
    Write-Host ('zip: ' + $zip + ' (' + $size + ' MB)')
}

Write-Host ('folder: ' + $OutDir)
Write-Host 'done.'
