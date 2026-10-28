#requires -version 5.1
<#
  Build a portable snapshot of the memory archive.

  Unencrypted by default: the .7z opens with a double-click, no password to
  lose. Add -Encrypt for 7z AES-256 + -mhe=on; the password then comes from
  backup-secret.json (never stored in the archive or the repo).

  Contents: workspace memory files + collector scripts + Bilibili history and
  favorite metadata. Deliberately excluded: browser profile (login state),
  cover images, logs, and the password file itself.

  Outputs:
    1. <ColdBackup>\bili-archive-<stamp>.7z              (second disk, cold copy)
    2. <OneDrive>\<BackupSubdir>\bili-archive-<stamp>.7z (cloud + phone)
    3. a desktop shortcut pointing at the newest archive
    4. (only with -Encrypt) a plaintext hint file next to the archive

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup-package.ps1
    powershell.exe ... -Encrypt
    powershell.exe ... -Format zip      # force Windows ZIP (best third-party compatibility)
    powershell.exe ... -Yes             # no confirmation dialog (used by the scheduler)
#>
[CmdletBinding()]
param(
    [int]$Keep = 5,
    [switch]$NoShortcut,
    [switch]$Force,
    [switch]$Verify,
    [switch]$Encrypt,
    [ValidateSet('auto', 'zip', '7z')]
    [string]$Format = 'auto',
    [switch]$Yes
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

# All names that are not ASCII come from config.json; PS 5.1 reads this file as
# GBK, so a single CJK literal below would corrupt the whole script.
$Cfg = [System.IO.File]::ReadAllText((Join-Path $Root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

function CfgOr {
    param($Obj, [string]$Name, $Fallback)
    if ($Obj -and $Obj.PSObject.Properties[$Name] -and $Obj.PSObject.Properties[$Name].Value) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $Fallback
}

$SecretFile = Join-Path $Root 'backup-secret.json'
$EncryptOn = $Encrypt -or [bool](CfgOr $Cfg 'BackupEncrypt' $false)
$Password = ''

$SevenZipCfg = [string](CfgOr $Cfg 'SevenZip' '')
$SevenZip = ''
if ($SevenZipCfg -and (Test-Path $SevenZipCfg)) { $SevenZip = $SevenZipCfg }
if (-not $SevenZip) {
    foreach ($candidate in @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')) {
        if (Test-Path $candidate) { $SevenZip = $candidate; break }
    }
}
# Without 7-Zip a plain ZIP is still useful (and readable by Windows itself).
# Encryption is the only feature that truly requires 7-Zip. -Format lets the
# user force ZIP even when 7-Zip exists, because some third-party archivers
# handle 7z (especially header-encrypted ones) poorly.
$UseZipFallback = $false
if ($Format -eq 'zip') {
    $UseZipFallback = $true
} elseif ($Format -eq '7z') {
    if (-not $SevenZip) { throw '-Format 7z requires 7-Zip.' }
} else {
    $UseZipFallback = -not $SevenZip
}

$Workspace = [string](CfgOr $Cfg 'WorkspaceRoot' (Split-Path -Parent (Split-Path -Parent $Root)))
$DataRoot = [string](CfgOr $Cfg 'DataRoot' '')
$ColdBackup = [string](CfgOr $Cfg 'ColdBackup' '')
$OneDrive = [string](CfgOr $Cfg 'OneDrive' 'D:\OneDrive')
$OneSub = [string](CfgOr $Cfg 'BackupSubdir' 'bili-backup')
$HintName = [string](CfgOr $Cfg 'PasswordHintFile' 'password-hint.txt')
$HintText = [string](CfgOr $Cfg 'PasswordHintText' 'The password is my QQ number.')
$ShortcutName = [string](CfgOr $Cfg 'ShortcutName' 'bili-archive-latest.lnk')
$ProgressName = [string](CfgOr $Cfg 'ProgressFileName' 'progress.json')
$WorkspaceFiles = @(CfgOr $Cfg 'WorkspaceFiles' @('AGENTS.md'))

# Backup locations: config.BackupTargets is authoritative; the legacy
# ColdBackup/OneDrive pair is only a fallback for older configs.
$OneDir = Join-Path $OneDrive $OneSub
$Targets = @()
if ($Cfg.BackupTargets) {
    foreach ($t in @($Cfg.BackupTargets)) {
        $tp = if ($t -is [string]) { $t } elseif ($t.Path) { [string]$t.Path } else { '' }
        if ($tp) { $Targets += $tp }
    }
}
if ($Targets.Count -eq 0) { $Targets = @($ColdBackup, $OneDir) }
$Targets = @($Targets | Where-Object { $_ } | Select-Object -Unique)
$Primary = $Targets[0]
$Mirrors = @($Targets | Select-Object -Skip 1)

if ($Verify) {
    if ($EncryptOn -and $UseZipFallback) {
        Write-Host 'compression: ERROR - -Encrypt requires 7-Zip, which was not found.' -ForegroundColor Red
        Write-Host 'install 7-Zip, or drop -Encrypt to use the plain ZIP fallback.'
        exit 1
    }
    Write-Host ('compression: ' + $(if ($EncryptOn) { 'AES-256 (7-Zip)' } elseif ($UseZipFallback) { 'plain ZIP (Windows Compress-Archive)' } else { 'plain 7z' }))
    Write-Host 'resolved backup targets:'
    $i = 0
    foreach ($t in $Targets) {
        $i++
        $exists = Test-Path $t
        $freeGb = ''
        $writable = 'no'
        if ($exists) {
            try {
                $probe = Join-Path $t ('.probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                [System.IO.File]::WriteAllText($probe, 'x')
                Remove-Item $probe -Force
                $writable = 'yes'
            } catch { $writable = 'no' }
            $drive = (Get-Item $t).PSDrive
            if ($drive) { $freeGb = [string][math]::Round($drive.Free / 1GB, 1) + ' GB free' }
        }
        Write-Host ("  {0}. {1}  exists={2} writable={3} {4}" -f $i, $t, $exists, $writable, $freeGb)
    }
    Write-Host 'nothing was written (verify mode).'
    exit 0
}

if ($EncryptOn -and $UseZipFallback) { throw '-Encrypt requires 7-Zip; install it or drop -Encrypt.' }
if ($EncryptOn) {
    if (-not (Test-Path $SecretFile)) { throw 'missing backup-secret.json (-Encrypt needs the password)' }
    $Secret = [System.IO.File]::ReadAllText($SecretFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $Password = [string]$Secret.Password
    if (-not $Password) { throw 'backup-secret.json has no Password field.' }
}

foreach ($d in $Targets) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Write-Host ('target: ' + $d)
}

# Ask before a manual run: show how much is about to be packed and a rough
# time estimate. Scheduled runs pass -Yes so they never block on a dialog.
if (-not $Yes) {
    $srcBytes = 0
    $srcCount = 0
    foreach ($name in @('History', 'Fav')) {
        if (-not $Cfg.Dirs -or -not $Cfg.Dirs.$name) { continue }
        $d = Join-Path $DataRoot $Cfg.Dirs.$name
        if (-not (Test-Path $d)) { continue }
        $items = @(Get-ChildItem $d -Recurse -File -ErrorAction SilentlyContinue)
        $srcCount += $items.Count
        $srcBytes += [int64](($items | Measure-Object Length -Sum).Sum)
    }
    $srcMb = [math]::Round($srcBytes / 1MB, 1)
    $estSec = [math]::Round(($srcBytes / 20MB) + 3, 0)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $msg = "Backup about to start.`r`n`r`nFiles: $srcCount`r`nSource: $srcMb MB`r`nEstimated: about $estSec s`r`n`r`nContinue?"
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'Bilibili archive backup', 'YesNo', 'Question', 'Button2')
        if ($answer -ne 'Yes') {
            Write-Host 'cancelled by user; nothing was written.'
            exit 0
        }
    } catch {
        Write-Host 'confirmation dialog unavailable; continuing.'
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$stage = Join-Path $env:TEMP ('bili-pkg-' + $stamp)
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

function Copy-Rel {
    param([string]$From, [string]$To)
    if (-not (Test-Path $From)) { Write-Host ('  skip (missing): ' + $From); return }
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    if ((Get-Item $From).PSIsContainer) {
        # copy the CONTENTS, not the folder itself, or the target gains an
        # extra nesting level (memory\memory).
        Copy-Item (Join-Path $From '*') $To -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Copy-Item $From $To -Force -ErrorAction SilentlyContinue
    }
}

# 1. workspace memory + rules
$wsStage = Join-Path $stage 'workspace'
New-Item -ItemType Directory -Force -Path $wsStage | Out-Null
foreach ($f in $WorkspaceFiles) { Copy-Rel (Join-Path $Workspace $f) $wsStage }
Copy-Rel (Join-Path $Workspace 'memory') (Join-Path $wsStage 'memory')
Copy-Rel (Join-Path $Workspace 'modes') (Join-Path $wsStage 'modes')

# 2. collector scripts and docs (no data, no secrets)
$projStage = Join-Path $stage 'collector'
New-Item -ItemType Directory -Force -Path $projStage | Out-Null
foreach ($pat in @('*.ps1', '*.md', 'config.json', '.session.json')) {
    Get-ChildItem $Root -Filter $pat -File -ErrorAction SilentlyContinue |
        Copy-Item -Destination $projStage -Force -ErrorAction SilentlyContinue
}

# 3. archive text data
if ($DataRoot) {
    $h1 = Join-Path $DataRoot $Cfg.Dirs.History
    $h2 = Join-Path $DataRoot $Cfg.Dirs.Fav
    if (Test-Path $h1) {
        $dst = Join-Path $stage 'bili\history'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $h1 '*.jsonl') $dst -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $h1 'state.json') $dst -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $h2) {
        $dst = Join-Path $stage 'bili\favorites'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $h2 '*.jsonl') $dst -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $h2 '*.md') $dst -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $h2 $ProgressName) $dst -Force -ErrorAction SilentlyContinue
    }
}

# inventory, so the archive can be checked without extracting it
# .NET instead of Get-FileHash: the cmdlet needs Microsoft.PowerShell.Utility to
# autoload, which breaks when PSModulePath is inherited from a PS7 parent.
function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function New-HardOrCopy {
    # Both targets sit on D:, so one physical copy can back two paths. Falls
    # back to a real copy when the volumes differ or the link fails.
    param([string]$Source, [string]$Dest)
    if (Test-Path $Dest) { Remove-Item $Dest -Force }
    try {
        New-Item -ItemType HardLink -Path $Dest -Target $Source -ErrorAction Stop | Out-Null
        return 'hardlink'
    } catch {
        Copy-Item $Source $Dest -Force
        return 'copy'
    }
}

$inv = Get-ChildItem $stage -Recurse -File | ForEach-Object {
    [pscustomobject]@{
        path   = $_.FullName.Substring($stage.Length + 1)
        bytes  = $_.Length
        sha256 = (Get-Sha256 $_.FullName)
    }
}
$inv | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $stage 'MANIFEST.json') -Encoding UTF8

function Set-DesktopShortcut {
    param([string]$TargetFile, [string]$WorkDir)
    if ($NoShortcut) { return }
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desk $ShortcutName
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $TargetFile
    $s.WorkingDirectory = $WorkDir
    $s.Description = $(if ($UseZipFallback) { 'Bilibili archive (unencrypted ZIP).' } elseif ($EncryptOn) { 'Bilibili archive (AES-256). Password: backup-secret.json.' } else { 'Bilibili archive (unencrypted).' })
    $s.Save()
    Write-Host ("desktop shortcut: {0}" -f $lnk)
}

# Content fingerprint: identical content means a new archive would only differ
# in timestamps, so skip the work entirely.
$fpSource = ($EncryptOn.ToString()) + ':' + ($UseZipFallback.ToString()) + "`n" + (($inv | Sort-Object path | ForEach-Object { $_.path + ':' + $_.bytes + ':' + $_.sha256 }) -join "`n")
$fp = Get-Sha256Text $fpSource
$fpFile = Join-Path $Primary '.last-fingerprint'
$prevFp = ''
if (Test-Path $fpFile) { $prevFp = ([System.IO.File]::ReadAllText($fpFile)).Trim() }

$existing = Get-ChildItem $Primary -Filter 'bili-archive-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^bili-archive-\d{8}-\d{4}\.(7z|zip)$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $Force -and $prevFp -eq $fp -and $existing) {
    Write-Host ("content unchanged since {0}; reusing {1}" -f $existing.LastWriteTime, $existing.Name)
    Set-DesktopShortcut -TargetFile $existing.FullName -WorkDir $Primary
    Remove-Item $stage -Recurse -Force
    Write-Host 'done (skipped rebuild).'
    exit 0
}

$outName = 'bili-archive-' + $stamp + $(if ($UseZipFallback) { '.zip' } else { '.7z' })
$coldZip = Join-Path $Primary $outName
if ($UseZipFallback) {
    if (Test-Path $coldZip) { Remove-Item $coldZip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $coldZip -CompressionLevel Optimal -Force
    if (-not (Test-Path $coldZip)) { throw 'ZIP fallback failed to create an archive' }
} else {
    $sevenArgs = @('a', '-t7z', '-mx=5')
    if ($EncryptOn) { $sevenArgs += '-mhe=on'; $sevenArgs += ('-p' + $Password) }
    $sevenArgs += $coldZip
    $sevenArgs += (Join-Path $stage '*')
    $sevenArgs += @('-r', '-y')
    & $SevenZip @sevenArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z failed with exit code $LASTEXITCODE" }
}

$sizeKb = [math]::Round((Get-Item $coldZip).Length / 1KB, 1)
Write-Host ("archive: {0} ({1} KB, {2} file(s))" -f $coldZip, $sizeKb, $inv.Count)
[System.IO.File]::WriteAllText($fpFile, $fp, [System.Text.Encoding]::ASCII)

$utf8 = New-Object System.Text.UTF8Encoding($false)
if ($EncryptOn) {
    [System.IO.File]::WriteAllText((Join-Path $Primary $HintName), $HintText + "`r`n", $utf8)
}

$shortcutTarget = $coldZip
$shortcutDir = $Primary
foreach ($mirror in $Mirrors) {
    if (-not (Test-Path $mirror)) { New-Item -ItemType Directory -Force -Path $mirror | Out-Null }
    $mirrorZip = Join-Path $mirror $outName
    $linkMode = New-HardOrCopy -Source $coldZip -Dest $mirrorZip
    if ($EncryptOn) {
        [System.IO.File]::WriteAllText((Join-Path $mirror $HintName), $HintText + "`r`n", $utf8)
    }
    Write-Host ("mirror: {0} ({1})" -f $mirrorZip, $linkMode)
    $shortcutTarget = $mirrorZip
    $shortcutDir = $mirror
}

Set-DesktopShortcut -TargetFile $shortcutTarget -WorkDir $shortcutDir

# prune old archives in every target
foreach ($dir in $Targets) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Filter 'bili-archive-*' | Where-Object { $_.Name -match '^bili-archive-\d{8}-\d{4}\.(7z|zip)$' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep | ForEach-Object {
            Remove-Item $_.FullName -Force
            Write-Host ('pruned: ' + $_.Name)
        }
}

Remove-Item $stage -Recurse -Force
Write-Host 'done.'
# Explicit exit: without it, powershell.exe -File inherits the exit code of the
# last native command (7z, or Compress-Archive's underlying call), so a
# warning-free run could still report failure.
exit 0
