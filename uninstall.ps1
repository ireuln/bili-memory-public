#requires -version 5.1
<#
  Uninstall helper: shows the exact scope first, then removes only what you
  confirm. Nothing is deleted by default except the automation entries.

  Scenarios:
    A. tried it, did not like it, want everything gone
       .\uninstall.ps1 -RemoveData -RemoveBackups
    B. used it for a while, want to remove the tool but keep backups
       .\uninstall.ps1                 (data/backups kept unless you say yes)
    C. just stop the automation, keep everything
       .\register-task.ps1 -Unregister

  Modes:
    .\uninstall.ps1 -Check     report scope + leftovers, change nothing
    .\uninstall.ps1 -DryRun    show the plan, change nothing
    .\uninstall.ps1 -Yes       no prompts; only -RemoveData/-RemoveBackups flags apply

  Exit codes: 0 done, 1 cancelled, 2 config missing and nothing to do.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Check,
    [switch]$RemoveData,
    [switch]$RemoveBackups
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
$CfgFile = Join-Path $Root 'config.json'
$Cfg = $null
if (Test-Path $CfgFile) {
    $Cfg = [System.IO.File]::ReadAllText($CfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

$TaskNames = @('DSH-BiliHistory', 'DSH-BiliFavs', 'DSH-BiliFollows', 'DSH-BiliBackup', 'DSH-BiliCold', 'DSH-BiliSample')
$StartupDir = [Environment]::GetFolderPath('Startup')
$DesktopDir = [Environment]::GetFolderPath('Desktop')

$TrayName = if ($Cfg -and $Cfg.TrayShortcutName) { [string]$Cfg.TrayShortcutName } else { 'bili-tray.lnk' }
$TrayLnk = Join-Path $StartupDir $TrayName
$DesktopName = if ($Cfg -and $Cfg.ShortcutName) { [string]$Cfg.ShortcutName } else { 'bili-archive-latest.lnk' }
$DesktopLnk = Join-Path $DesktopDir $DesktopName

$DataRoot = if ($Cfg -and $Cfg.DataRoot) { [string]$Cfg.DataRoot } else { '' }
$BackupDirs = @()
if ($Cfg -and $Cfg.BackupTargets) {
    foreach ($t in @($Cfg.BackupTargets)) {
        $p = if ($t -is [string]) { $t } elseif ($t.Path) { [string]$t.Path } else { '' }
        if ($p) { $BackupDirs += $p }
    }
}
if ($Cfg -and $Cfg.ColdBackup) { $BackupDirs += [string]$Cfg.ColdBackup }
$BackupDirs = @($BackupDirs | Where-Object { $_ } | Select-Object -Unique)

function Get-SizeText {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        $bytes = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        return ([math]::Round([double]$bytes / 1MB, 1).ToString() + ' MB')
    } catch { return '' }
}

function Get-ArchiveFiles {
    foreach ($dir in $BackupDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Filter 'bili-archive-*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^bili-archive-\d{8}-\d{4}\.(7z|zip)$' }
    }
}

$archiveFiles = @(Get-ArchiveFiles)
$archiveSize = 0
foreach ($f in $archiveFiles) { $archiveSize += $f.Length }

$tempDirs = @(Get-ChildItem $env:TEMP -Directory -Filter 'bili-pkg-*' -ErrorAction SilentlyContinue) +
            @(Get-ChildItem $env:TEMP -Directory -Filter 'bili-cold-*' -ErrorAction SilentlyContinue)

# ------------------------------------------------------------------ scope
Write-Host ''
Write-Host '=== Bilibili archive - uninstall scope ===' -ForegroundColor Cyan
Write-Host ''
Write-Host ('tool folder   : {0}' -f $Root)
Write-Host ('config        : {0}' -f $CfgFile)
Write-Host ('data folder   : {0} {1}' -f $DataRoot, $(if ($DataRoot) { '(' + (Get-SizeText $DataRoot) + ')' } else { '(not configured)' }))
if ($BackupDirs.Count -gt 0) {
    Write-Host ('backup folders: {0} ({1} archive(s), {2} MB)' -f ($BackupDirs -join '; '), $archiveFiles.Count, [math]::Round($archiveSize / 1MB, 1))
} else {
    Write-Host 'backup folders: (none configured)'
}
Write-Host ''
Write-Host 'will be removed (always):'
Write-Host '  - scheduled tasks: DSH-Bili*'
Write-Host ('  - tray startup   : {0}' -f $TrayLnk)
Write-Host ('  - desktop link   : {0}' -f $DesktopLnk)
Write-Host ('  - temp stages    : {0}' -f ($tempDirs.Count))
Write-Host 'will be removed only if you choose so:'
Write-Host ('  - data folder (archive + browser login state): {0}' -f $DataRoot)
Write-Host ('  - backup archives only (not the folder)     : {0} file(s)' -f $archiveFiles.Count)
Write-Host 'left for you to delete manually:'
Write-Host ('  - this tool folder (scripts, config.json, backup-secret.json): {0}' -f $Root)
Write-Host ''

if ($Check) {
    Write-Host 'residual check:' -ForegroundColor Cyan
    $left = @(Get-ScheduledTask -TaskName 'DSH-Bili*' -ErrorAction SilentlyContinue)
    Write-Host ('  tasks left     : {0}' -f $(if ($left.Count) { ($left | ForEach-Object { $_.TaskName }) -join ', ' } else { 'none' }))
    Write-Host ('  startup link   : {0}' -f $(if (Test-Path $TrayLnk) { 'present' } else { 'none' }))
    Write-Host ('  desktop link   : {0}' -f $(if (Test-Path $DesktopLnk) { 'present' } else { 'none' }))
    Write-Host ('  data folder    : {0}' -f $(if ($DataRoot -and (Test-Path $DataRoot)) { 'present' } else { 'none' }))
    Write-Host ('  backup archives: {0}' -f $archiveFiles.Count)
    Write-Host ('  temp stages    : {0}' -f $tempDirs.Count)
    Write-Host 'nothing was changed (check mode).'
    exit 0
}

# ------------------------------------------------------------------ choices
$doData = [bool]$RemoveData
$doBackups = [bool]$RemoveBackups

# A collector/backup may still be writing. Never delete DataRoot underneath it.
$activeRuns = @()
try {
    $escRoot = [regex]::Escape($Root)
    $activeRuns = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match $escRoot -and
            $_.CommandLine -match 'run-task\.ps1|collect\.ps1|backup-package\.ps1|backup-cold\.ps1'
        })
} catch { }
$lockFile = Join-Path $Root 'run.lock'
if ($activeRuns.Count -gt 0 -or (Test-Path $lockFile)) {
    Write-Host ''
    Write-Host 'WARNING: a run looks active (collector/backup or a stale lock).' -ForegroundColor Yellow
    foreach ($p in $activeRuns) { Write-Host ('  pid ' + $p.ProcessId) }
    if (Test-Path $lockFile) { Write-Host ('  lock: ' + $lockFile) }
    if ($doData) {
        $doData = $false
        Write-Host 'Data folder will be KEPT until the run stops; rerun uninstall afterwards.' -ForegroundColor Yellow
    }
}

if (-not $Yes -and -not $DryRun) {
    if ($DataRoot) {
        $a = Read-Host ('delete the data folder (archive + login state)? [y/N] ' + $DataRoot)
        if ($a -match '^y') { $doData = $true }
    }
    if ($archiveFiles.Count -gt 0) {
        $a = Read-Host ('delete the {0} backup archive(s)? the folders stay [y/N] ' -f $archiveFiles.Count)
        if ($a -match '^y') { $doBackups = $true }
    }
}

if ($DryRun) {
    Write-Host 'DRY RUN - no changes.' -ForegroundColor Yellow
    Write-Host ('  tasks: remove {0}' -f ($TaskNames -join ', '))
    Write-Host ('  startup: {0}' -f $TrayLnk)
    Write-Host ('  desktop: {0}' -f $DesktopLnk)
    Write-Host ('  data: {0}' -f $(if ($doData) { 'DELETE' } else { 'keep' }))
    Write-Host ('  backups: {0}' -f $(if ($doBackups) { 'DELETE files' } else { 'keep' }))
    Write-Host ('  temp: {0} folder(s)' -f $tempDirs.Count)
    exit 0
}

if (-not $Yes) {
    Write-Host ''
    Write-Host 'This cannot be undone for the data/backup choices above.' -ForegroundColor Yellow
    $confirm = Read-Host 'Type DELETE (all caps) to continue'
    if ($confirm -ne 'DELETE') {
        Write-Host 'cancelled; nothing was changed.'
        exit 1
    }
}

# ------------------------------------------------------------------ actions
Write-Host ''
Write-Host 'stopping the tray process if it is running...'
$trayProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + (Join-Path $Root 'tray.ps1') + '*') })
foreach ($p in $trayProcs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host ('  stopped pid ' + $p.ProcessId) } catch { }
}

Write-Host 'removing scheduled tasks...'
foreach ($name in $TaskNames) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host ('  removed task ' + $name)
    }
}

foreach ($lnk in @($TrayLnk, $DesktopLnk)) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host ('  removed ' + $lnk) }
}

foreach ($d in $tempDirs) {
    try { Remove-Item $d.FullName -Recurse -Force; Write-Host ('  removed temp ' + $d.Name) } catch { }
}

if ($doData -and $DataRoot) {
    $full = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $toolFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootOfDrive = ($full.Length -eq 3 -and $full.EndsWith(':\'))
    $unsafe = @($env:SystemRoot, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA)
    if ($rootOfDrive -or ($unsafe -contains $full) -or $full -eq $toolFull -or $toolFull.StartsWith($full + '\')) {
        Write-Host ('refusing to delete unsafe path: ' + $full) -ForegroundColor Red
        exit 3
    }
    if (Test-Path $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Host ('  removed data folder ' + $full)
    }
} elseif ($DataRoot) {
    Write-Host ('  kept data folder ' + $DataRoot)
}

if ($doBackups) {
    foreach ($f in $archiveFiles) {
        try { Remove-Item -LiteralPath $f.FullName -Force; Write-Host ('  removed backup ' + $f.Name) } catch { }
    }
} elseif ($archiveFiles.Count -gt 0) {
    Write-Host ('  kept ' + $archiveFiles.Count + ' backup archive(s)')
}

Write-Host ''
Write-Host 'done. One manual step remains:' -ForegroundColor Yellow
Write-Host ('  delete this folder: ' + $Root)
Write-Host '  it still contains the scripts plus config.json and backup-secret.json.'
Write-Host ''
Write-Host 'residual check:'
$left = @(Get-ScheduledTask -TaskName 'DSH-Bili*' -ErrorAction SilentlyContinue)
Write-Host ('  tasks left     : {0}' -f $(if ($left.Count) { ($left | ForEach-Object { $_.TaskName }) -join ', ' } else { 'none' }))
Write-Host ('  startup link   : {0}' -f $(if (Test-Path $TrayLnk) { 'present' } else { 'none' }))
Write-Host ('  desktop link   : {0}' -f $(if (Test-Path $DesktopLnk) { 'present' } else { 'none' }))
Write-Host ('  data folder    : {0}' -f $(if ($DataRoot -and (Test-Path $DataRoot)) { 'present' } else { 'none' }))
Write-Host ('  backup archives: {0}' -f @(Get-ArchiveFiles).Count)
Write-Host '  tool folder    : present (delete manually)'
exit 0
