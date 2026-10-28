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
    .\uninstall.ps1 -NoPause   do not wait for Enter at the end (scripts/tests)

  Exit codes: 0 done, 1 cancelled, 2 config missing and nothing to do, 3 unsafe path.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Check,
    [switch]$RemoveData,
    [switch]$RemoveBackups,
    [switch]$NoPause
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
    try { $Host.UI.RawUI.WindowTitle = 'B印象 - 卸载' } catch { }
    # Wider window so long paths do not wrap mid-token. Ignored when hidden.
    try {
        $bs = $Host.UI.RawUI.BufferSize
        if ($bs.Width -lt 110) { $bs.Width = 110; $Host.UI.RawUI.BufferSize = $bs }
        $ws = $Host.UI.RawUI.WindowSize
        if ($ws.Width -lt 110) { $ws.Width = 110; $Host.UI.RawUI.WindowSize = $ws }
    } catch { }
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

# ---------------------------------------------------------------- formatting
function Format-Size {
    param($Bytes)
    if (-not $Bytes -or $Bytes -le 0) { return '0' }
    if ($Bytes -ge 1GB) { return ([math]::Round([double]$Bytes / 1GB, 2).ToString() + ' GB') }
    if ($Bytes -ge 1MB) { return ([math]::Round([double]$Bytes / 1MB, 1).ToString() + ' MB') }
    if ($Bytes -ge 1KB) { return ([math]::Round([double]$Bytes / 1KB, 0).ToString() + ' KB') }
    return ([string]$Bytes + ' B')
}

function Get-SizeText {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return '0' }
    try {
        $bytes = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        return (Format-Size $bytes)
    } catch { return '?' }
}

function Write-Head {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor $Color
    Write-Host ('  ' + ('-' * 46)) -ForegroundColor DarkGray
}

function Write-Item {
    param([string]$Tag, [string]$Text, [string]$Detail = '', [string]$Color = 'Gray')
    Write-Host ('    [' + $Tag + '] ' + $Text) -ForegroundColor $Color
    if ($Detail) { Write-Host ('          ' + $Detail) -ForegroundColor DarkGray }
}

function Get-ArchiveFiles {
    foreach ($dir in $BackupDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Filter 'bili-archive-*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^bili-archive-\d{8}-\d{4}\.(7z|zip)$' }
    }
}

$archiveFiles = @(Get-ArchiveFiles)
$archiveBytes = 0
foreach ($f in $archiveFiles) { $archiveBytes += $f.Length }

$tempDirs = @(Get-ChildItem $env:TEMP -Directory -Filter 'bili-pkg-*' -ErrorAction SilentlyContinue) +
            @(Get-ChildItem $env:TEMP -Directory -Filter 'bili-cold-*' -ErrorAction SilentlyContinue)

$taskLeft = @(Get-ScheduledTask -TaskName 'DSH-Bili*' -ErrorAction SilentlyContinue)
$dataSize = ''
if ($DataRoot) { if (Test-Path $DataRoot) { $dataSize = Get-SizeText $DataRoot } else { $dataSize = '不存在' } }
$toolSize = Get-SizeText $Root

# ------------------------------------------------------------------ scope
Write-Host ''
Write-Host '  B 印 象 · 卸 载' -ForegroundColor White
Write-Host '  先看清楚要删什么，再动手。' -ForegroundColor DarkGray

Write-Head 'A. 会删除（不需要你确认）' 'Green'
Write-Item '任务' ('计划任务 DSH-Bili* 共 ' + $taskLeft.Count + ' 条')
Write-Item '启动' '开机启动的托盘链接' $TrayLnk
Write-Item '桌面' '桌面上的“最新备份”快捷方式' $DesktopLnk
Write-Item '临时' ('卸载临时目录 ' + $tempDirs.Count + ' 个')

Write-Head 'B. 需要你选择（默认保留）' 'Yellow'
if ($DataRoot) {
    Write-Item '1' ('数据目录 ' + $dataSize) ($DataRoot + '   含登录态，删了要重新扫码')
} else {
    Write-Item '1' '数据目录' '（配置里没有 DataRoot）'
}
if ($archiveFiles.Count -gt 0) {
    Write-Item '2' ('备份包 ' + $archiveFiles.Count + ' 个文件 / ' + (Format-Size $archiveBytes)) '只删 .7z/.zip 文件，备份文件夹保留'
} else {
    Write-Item '2' '备份包' '（没有找到 bili-archive-*.7z/zip）'
}

Write-Head 'C. 不会自动删（留给你自己确认）' 'DarkGray'
Write-Item '工具' ('工具目录 ' + $toolSize) ($Root + '   含 config.json、备份密码提示')
Write-Item '数据' '数据目录里的图片/记录' '选 [1] 才会删；不选就一直留着'

# ------------------------------------------------------------------ checks
$doData = [bool]$RemoveData
$doBackups = [bool]$RemoveBackups
$blocked = $false

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
    Write-Host '  ! 检测到采集/备份可能正在运行，数据目录先保留。' -ForegroundColor Yellow
    foreach ($p in $activeRuns) { Write-Host ('      pid ' + $p.ProcessId) -ForegroundColor DarkGray }
    if (Test-Path $lockFile) { Write-Host ('      锁文件 ' + $lockFile) -ForegroundColor DarkGray }
    Write-Host '    等它跑完再执行一次卸载即可。' -ForegroundColor Yellow
    if ($doData) { $doData = $false; $blocked = $true }
}

if ($Check) {
    Write-Head '残留检查（只读，什么都没改）'
    Write-Host ('    计划任务  ' + $(if ($taskLeft.Count) { ($taskLeft | ForEach-Object { $_.TaskName }) -join ', ' } else { '无' }))
    Write-Host ('    启动链接  ' + $(if (Test-Path $TrayLnk) { '在' } else { '无' }))
    Write-Host ('    桌面链接  ' + $(if (Test-Path $DesktopLnk) { '在' } else { '无' }))
    Write-Host ('    数据目录  ' + $(if ($DataRoot -and (Test-Path $DataRoot)) { '在' } else { '无' }))
    Write-Host ('    备份包    ' + $archiveFiles.Count + ' 个')
    exit 0
}

# ------------------------------------------------------------------ choices
if (-not $Yes -and -not $DryRun) {
    Write-Host ''
    if ($DataRoot) {
        $a = Read-Host ('  删除 [1] 数据目录？' + $DataRoot + '  [y/N]')
        if ($a -match '^[yY]') { $doData = $true }
    }
    if ($archiveFiles.Count -gt 0) {
        $a = Read-Host ('  删除 [2] ' + $archiveFiles.Count + ' 个备份包？文件夹保留  [y/N]')
        if ($a -match '^[yY]') { $doBackups = $true }
    }
}

if ($DryRun) {
    Write-Head '试运行（什么都没改）' 'Yellow'
    Write-Host ('    数据目录  ' + $(if ($doData) { '删除' } else { '保留' }))
    Write-Host ('    备份包    ' + $(if ($doBackups) { '删除文件' } else { '保留' }))
    Write-Host ('    计划任务  ' + $taskLeft.Count + ' 条、启动/桌面链接、' + $tempDirs.Count + ' 个临时目录')
    if ($blocked) { Write-Host '    注意：数据目录因为检测到运行中的任务没有列入删除。' -ForegroundColor Yellow }
    exit 0
}

if (-not $Yes) {
    Write-Host ''
    Write-Host '  上面 [1][2] 的删除不可恢复。' -ForegroundColor Yellow
    $confirm = Read-Host '  确认执行请输入 DELETE（大写），直接回车取消'
    if ($confirm -ne 'DELETE') {
        Write-Host '  已取消，什么都没改。' -ForegroundColor DarkGray
        exit 1
    }
}

# ------------------------------------------------------------------ actions
Write-Head '开始执行' 'Cyan'
Write-Host '  停止托盘进程（如果在跑）…' -ForegroundColor DarkGray
$trayProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + (Join-Path $Root 'tray.ps1') + '*') })
foreach ($p in $trayProcs) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host ('    已停止 pid ' + $p.ProcessId) } catch { }
}

Write-Host '  删除计划任务…' -ForegroundColor DarkGray
$removedTasks = 0
foreach ($name in $TaskNames) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host ('    已删除 ' + $name)
        $removedTasks++
    }
}
if ($removedTasks -eq 0) { Write-Host '    本来就没有' -ForegroundColor DarkGray }

Write-Host '  删除快捷方式…' -ForegroundColor DarkGray
$removedLinks = 0
foreach ($lnk in @($TrayLnk, $DesktopLnk)) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host ('    已删除 ' + (Split-Path $lnk -Leaf)); $removedLinks++ }
}
if ($removedLinks -eq 0) { Write-Host '    本来就没有' -ForegroundColor DarkGray }

if ($tempDirs.Count -gt 0) {
    Write-Host '  清理临时目录…' -ForegroundColor DarkGray
    foreach ($d in $tempDirs) {
        try { Remove-Item $d.FullName -Recurse -Force; Write-Host ('    已删除 ' + $d.Name) } catch { }
    }
}

if ($doData -and $DataRoot) {
    $full = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $toolFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootOfDrive = ($full.Length -eq 3 -and $full.EndsWith(':\'))
    $unsafe = @($env:SystemRoot, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA)
    if ($rootOfDrive -or ($unsafe -contains $full) -or $full -eq $toolFull -or $toolFull.StartsWith($full + '\')) {
        Write-Host ('  拒绝删除不安全路径：' + $full) -ForegroundColor Red
        exit 3
    }
    if (Test-Path $full) {
        Write-Host ('  删除数据目录 ' + $dataSize + ' …') -ForegroundColor DarkGray
        Remove-Item -LiteralPath $full -Recurse -Force
        Write-Host ('    已删除 ' + $full)
    }
} elseif ($DataRoot) {
    Write-Host ('  数据目录已保留：' + $DataRoot) -ForegroundColor DarkGray
}

if ($doBackups) {
    Write-Host '  删除备份包…' -ForegroundColor DarkGray
    foreach ($f in $archiveFiles) {
        try { Remove-Item -LiteralPath $f.FullName -Force; Write-Host ('    已删除 ' + $f.Name) } catch { }
    }
} elseif ($archiveFiles.Count -gt 0) {
    Write-Host ('  备份包已保留：' + $archiveFiles.Count + ' 个（' + (Format-Size $archiveBytes) + '）') -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ result
$taskAfter = @(Get-ScheduledTask -TaskName 'DSH-Bili*' -ErrorAction SilentlyContinue)
Write-Head '完成' 'Green'
Write-Host ('    计划任务剩余  ' + $(if ($taskAfter.Count) { ($taskAfter | ForEach-Object { $_.TaskName }) -join ', ' } else { '0（干净）' }))
Write-Host ('    启动链接      ' + $(if (Test-Path $TrayLnk) { '仍在' } else { '已清除' }))
Write-Host ('    桌面链接      ' + $(if (Test-Path $DesktopLnk) { '仍在' } else { '已清除' }))
Write-Host ('    数据目录      ' + $(if ($DataRoot -and (Test-Path $DataRoot)) { '仍在' } else { '已清除' }))
Write-Host ('    备份包        ' + @(Get-ArchiveFiles).Count + ' 个')
Write-Host ''
Write-Host '  最后一步：手动删除工具目录' -ForegroundColor Yellow
Write-Host ('    ' + $Root) -ForegroundColor Yellow
Write-Host '  里面还有 config.json 和备份密码提示，所以不由脚本代删。' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoPause) {
    try {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
            Write-Host '  按回车关闭窗口…' -ForegroundColor DarkGray
            $null = Read-Host
        }
    } catch { }
}
exit 0
