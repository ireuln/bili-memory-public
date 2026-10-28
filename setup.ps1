#requires -version 5.1
<#
  First-run setup for the Bilibili memory archive.

  Designed to be driven by an AI assistant as well as a human:
    - every question has a flag, so nothing blocks a non-interactive run
    - it never deletes anything and never overwrites a config without -Force
    - it prints what it will do before doing it

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
    ... -File .\setup.ps1 -Yes -NoLogin
    ... -File .\setup.ps1 -DataRoot "D:\bili-archive" -Yes
#>
[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [string]$ConfigFile = '',
    [ValidateSet('zh-CN', 'en-US')]
    [string]$UiLanguage = '',
    [switch]$Yes,
    [switch]$NoLogin,
    [switch]$NoBackup,
    [switch]$Force
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
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $ConfigFile) { $ConfigFile = Join-Path $Root 'config.json' }
$Example = Join-Path $Root 'config.example.json'

function Ask {
    param([string]$Question, [string]$Default = '')
    if ($Yes) { return $Default }
    $suffix = if ($Default) { ' [' + $Default + ']' } else { '' }
    $answer = Read-Host ($Question + $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

Write-Host ''
Write-Host '=== Bilibili memory archive - setup ===' -ForegroundColor Cyan
Write-Host ''

# ---- 1. browser ----------------------------------------------------------
$candidates = @(
    (@{ Name = 'Edge';   Path = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' }),
    (@{ Name = 'Edge';   Path = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }),
    (@{ Name = 'Chrome'; Path = 'C:\Program Files\Google\Chrome\Application\chrome.exe' }),
    (@{ Name = 'Chrome'; Path = 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe' })
)
$browser = $null
foreach ($c in $candidates) { if (Test-Path $c.Path) { $browser = $c; break } }
if (-not $browser) {
    Write-Host 'No Edge/Chrome found. Install one first, then re-run this script.' -ForegroundColor Red
    exit 2
}
Write-Host ("browser : {0}  {1}" -f $browser.Name, $browser.Path)

# ---- 2. data root --------------------------------------------------------
$vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.SizeRemaining -gt 2GB }
$ranked = @()
foreach ($v in $vols) {
    $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue | Select-Object -First 1
    $disk = $null
    $bus = ''
    if ($part) {
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
        if ($disk) { $bus = [string]$disk.BusType }
    }
    $isSystem = ($v.DriveLetter -eq $env:SystemDrive.TrimEnd(':'))
    $ranked += [pscustomobject]@{
        Letter   = $v.DriveLetter
        FreeGB   = [math]::Round($v.SizeRemaining / 1GB, 1)
        BusType  = $bus
        System   = $isSystem
        Path     = ($v.DriveLetter + ':\bili-archive')
    }
}
# prefer internal disks with the most free space, never the system drive
$ranked = @($ranked | Sort-Object @{ Expression = { $_.System } }, @{ Expression = { $_.BusType -eq 'USB' } }, @{ Expression = { 0 - $_.FreeGB } })
Write-Host ''
Write-Host 'candidate data locations:'
$i = 0
foreach ($r in $ranked) {
    $i++
    Write-Host ("  {0}. {1}  {2} GB free  bus={3}{4}" -f $i, $r.Path, $r.FreeGB, $r.BusType, $(if ($r.System) { '  (system drive)' } else { '' }))
}
$defaultRoot = $ranked[0].Path
if (-not $DataRoot) {
    $pick = Ask ("data folder (empty = {0})" -f $defaultRoot) $defaultRoot
    $DataRoot = $pick
}
Write-Host ("data root: {0}" -f $DataRoot)
$fullData = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
$unsafeDirs = @($env:SystemRoot, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)})
if ($fullData.Length -le 3 -or ($unsafeDirs -contains $fullData) -or
    $fullData.StartsWith($env:SystemRoot + '\') -or $fullData.StartsWith($env:ProgramFiles + '\')) {
    Write-Host ('refusing unsafe data folder: ' + $fullData) -ForegroundColor Red
    Write-Host 'pick a normal folder such as D:\bili-archive.' -ForegroundColor Red
    exit 2
}

# ---- 3. config -----------------------------------------------------------
if ((Test-Path $ConfigFile) -and -not $Force) {
    Write-Host ("config already exists: {0} (use -Force to overwrite)" -f $ConfigFile) -ForegroundColor Yellow
    exit 3
}
if (-not (Test-Path $Example)) {
    Write-Host ("missing template: {0}" -f $Example) -ForegroundColor Red
    exit 4
}
$cfg = [System.IO.File]::ReadAllText($Example, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
if ($UiLanguage) { $cfg.UiLanguage = $UiLanguage }

# 7-Zip is only needed for backups; find it and record the real path instead of
# failing later with the template default.
$sevenCandidates = @([string]$cfg.SevenZip, 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')
$sevenFound = @($sevenCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
if ($sevenFound.Count -gt 0) {
    $cfg.SevenZip = $sevenFound[0]
    Write-Host ("7-Zip   : {0}" -f $sevenFound[0])
} else {
    Write-Host '7-Zip   : not found; backups stay unavailable until you install it.' -ForegroundColor Yellow
}
$cfg.DataRoot = $DataRoot
$cfg.BrowserExe = $browser.Path
if ($cfg.PSObject.Properties['ColdBackup'] -and -not $NoBackup) {
    $backupDefault = ($DataRoot.TrimEnd('\').Substring(0, 2)) + '\bili-backup'
    $backupRoot = Ask ('backup folder (empty = {0})' -f $backupDefault) $backupDefault
    $cfg.ColdBackup = $backupRoot
    if ($cfg.PSObject.Properties['BackupTargets']) {
        $cfg.BackupTargets = @([pscustomobject]@{ Path = $backupRoot; Kind = 'primary' })
    }
}
# Tray autostart is opt-in: ask once, store the answer in Automation.Startup.
if ($cfg.PSObject.Properties['Automation']) {
    $trayAnswer = Ask 'start tray icon at logon? (y/n)' 'n'
    if ($trayAnswer -match '^y') { $cfg.Automation.Startup = 'tray' } else { $cfg.Automation.Startup = 'none' }
}
$json = $cfg | ConvertTo-Json -Depth 10
$cfgParent = Split-Path -Parent $ConfigFile
if ($cfgParent -and -not (Test-Path $cfgParent)) { New-Item -ItemType Directory -Force -Path $cfgParent | Out-Null }
[System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("config written: {0}" -f $ConfigFile) -ForegroundColor Green

foreach ($d in @($DataRoot, (Join-Path $DataRoot $cfg.Dirs.History), (Join-Path $DataRoot $cfg.Dirs.Fav), (Join-Path $DataRoot $cfg.Dirs.Cover), (Join-Path $DataRoot $cfg.Dirs.Profile), (Join-Path $DataRoot $cfg.Dirs.Log))) {
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ---- 4. login ------------------------------------------------------------
if ($NoLogin) {
    Write-Host 'skipped login (-NoLogin). Run collect.ps1 -Login when ready.' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host 'A dedicated browser window will open. Scan the QR code to log in to Bilibili.' -ForegroundColor Cyan
    Write-Host 'The window closes automatically once the login is detected.' -ForegroundColor Cyan
    if ((Ask 'continue? (y/n)' 'y') -match '^y') {
        & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'collect.ps1') -Login
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Write-Host ("login did not complete (exit {0}). Re-run: collect.ps1 -Login" -f $code) -ForegroundColor Yellow
        }
    }
}

# ---- 5. smoke test -------------------------------------------------------
Write-Host ''
Write-Host 'checking login state...' -ForegroundColor Cyan
& $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'collect.ps1') -Status

Write-Host ''
Write-Host 'next steps:' -ForegroundColor Cyan
Write-Host '  1. history once :  powershell -File .\run-task.ps1 -Mode history'
Write-Host '  2. favorites    :  powershell -File .\run-task.ps1 -Mode fav -TimeoutMinutes 90'
Write-Host '  3. choose what is scheduled vs manual: edit config.json -> Automation'
Write-Host '  4. apply choices:  powershell -File .\register-task.ps1 -DryRun   (then without -DryRun)'
Write-Host '  5. tray icon    :  powershell -File .\tray.ps1   (or set Automation.Startup = "tray")'
Write-Host ''
Write-Host 'first-time users: read docs/ (the capability doc) before relying on the output.' -ForegroundColor Cyan
Write-Host 'setup finished.' -ForegroundColor Green
exit 0
