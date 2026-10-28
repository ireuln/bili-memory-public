#requires -version 5.1
<#
  Apply the per-feature automation choices from config.json -> Automation.

  Every feature can be "scheduled" or "manual":
    - scheduled : a Windows scheduled task is registered
    - manual    : no task is registered; run it by hand when you want
  "Startup" controls the tray icon: "tray" adds it to the user's Start menu
  startup folder, "none" removes it.

  Choices live in config.json, so they survive re-runs:

    "Automation": {
      "Startup":   "none",
      "History":   "scheduled",
      "Favorites": "scheduled",
      "Follows":   "scheduled",
      "Backup":    "scheduled",
      "BackupCold":"manual"
    }

  Usage:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\register-task.ps1
    ... -File .\register-task.ps1 -DryRun              # show, change nothing
    ... -File .\register-task.ps1 -Backup manual -Save # flip one feature
    ... -File .\register-task.ps1 -Startup tray -Save
    ... -File .\register-task.ps1 -Unregister          # remove tasks + startup

  Command-line flags override config for this run; add -Save to persist them
  back into config.json.
#>
[CmdletBinding()]
param(
    [switch]$Unregister,
    [switch]$Tray,
    [ValidateSet('tray', 'none')]
    [string]$Startup = '',
    [ValidateSet('scheduled', 'manual')]
    [string]$History = '',
    [ValidateSet('scheduled', 'manual')]
    [string]$Favorites = '',
    [ValidateSet('scheduled', 'manual')]
    [string]$Follows = '',
    [ValidateSet('scheduled', 'manual')]
    [string]$Backup = '',
    [ValidateSet('scheduled', 'manual')]
    [string]$BackupCold = '',
    [switch]$Yes,
    [string]$Sampling = 'off',
    [switch]$DryRun,
    [switch]$Save
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
$Runner = Join-Path $Root 'run-task.ps1'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $Runner)) { throw 'run-task.ps1 missing next to this script' }

$CfgFile = Join-Path $Root 'config.json'
if (-not (Test-Path $CfgFile)) { throw 'config.json missing; run setup.ps1 first' }
$Cfg = [System.IO.File]::ReadAllText($CfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$TrayName = if ($Cfg.TrayShortcutName) { [string]$Cfg.TrayShortcutName } else { 'bili-tray.lnk' }
$StartupDir = [Environment]::GetFolderPath('Startup')
$TrayLnk = Join-Path $StartupDir $TrayName

$Tasks = @(
    @{ Key = 'History';    Name = 'DSH-BiliHistory'; Mode = 'history'; Cadence = 'daily';  Time = '04:00'; Timeout = 60; Desc = 'Collect Bilibili watch history (daily).' },
    @{ Key = 'Favorites';  Name = 'DSH-BiliFavs';    Mode = 'fav';     Cadence = 'weekly'; Time = '05:00'; Timeout = 90; Desc = 'Refresh Bilibili favorites + invalid timeline (weekly, Sunday).' },
    @{ Key = 'Follows';    Name = 'DSH-BiliFollows'; Mode = 'follow';  Cadence = 'weekly'; Time = '05:40'; Timeout = 30; Desc = 'Refresh follow groups / special follows / recent top uploaders (weekly, Sunday).' },
    @{ Key = 'Backup';     Name = 'DSH-BiliBackup';  Mode = 'backup';  Cadence = 'weekly'; Time = '06:00'; Timeout = 30; Desc = 'Build archive snapshot (weekly, Sunday).' },
    @{ Key = 'BackupCold'; Name = 'DSH-BiliCold';    Mode = 'cold';    Cadence = 'weekly'; Time = '06:20'; Timeout = 20; Desc = 'Text-only cold copy of history + favorites (weekly, Sunday).' }
)

# Defaults preserve the old behaviour: collection + weekly snapshot scheduled,
# cold copy manual, no tray autostart.
$Auto = [ordered]@{
    Startup    = 'none'
    History    = 'scheduled'
    Favorites  = 'scheduled'
    Follows    = 'scheduled'
    Backup     = 'scheduled'
    BackupCold = 'manual'
}
if ($Cfg.Automation) {
    foreach ($k in @($Auto.Keys)) {
        $p = $Cfg.Automation.PSObject.Properties[$k]
        if ($p -and $p.Value) { $Auto[$k] = [string]$p.Value }
    }
}
if ($Tray) { $Auto.Startup = 'tray' }
if ($PSBoundParameters.ContainsKey('Startup'))    { $Auto.Startup = $Startup }
if ($PSBoundParameters.ContainsKey('History'))    { $Auto.History = $History }
if ($PSBoundParameters.ContainsKey('Favorites'))  { $Auto.Favorites = $Favorites }
if ($PSBoundParameters.ContainsKey('Follows'))    { $Auto.Follows = $Follows }
if ($PSBoundParameters.ContainsKey('Backup'))     { $Auto.Backup = $Backup }
if ($PSBoundParameters.ContainsKey('BackupCold')) { $Auto.BackupCold = $BackupCold }

function Remove-TaskSafe {
    param([string]$Name)
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        if (-not $DryRun) { Unregister-ScheduledTask -TaskName $Name -Confirm:$false | Out-Null }
        Write-Host ('  remove task : ' + $Name)
    }
}

function Remove-TrayShortcut {
    if (Test-Path $TrayLnk) {
        if (-not $DryRun) { Remove-Item $TrayLnk -Force }
        Write-Host ('  remove startup: ' + $TrayLnk)
    }
}

if ($Unregister) {
    Write-Host 'removing every scheduled task and the tray startup shortcut...'
    foreach ($t in $Tasks) { Remove-TaskSafe $t.Name }
    Remove-TaskSafe 'DSH-BiliSample'
    Remove-TrayShortcut
    Write-Host 'done. nothing will run automatically.'
    exit 0
}

# ---- optional high-frequency sampling (OFF by default) -------------------
if ($Sampling -ne 'off') {
    $minutes = 0
    if (-not [int]::TryParse($Sampling, [ref]$minutes) -or $minutes -lt 15) {
        Write-Host 'Sampling needs a whole number of minutes, 15 or more. Example: -Sampling 30' -ForegroundColor Red
        Write-Host 'Nothing was changed.' -ForegroundColor Red
        exit 2
    }
    $perDay = [int](1440 / $minutes)
    Write-Host ''
    Write-Host '================ WARNING ================' -ForegroundColor Yellow
    Write-Host ("Enabling resident sampling every {0} minutes." -f $minutes) -ForegroundColor Yellow
    Write-Host ("That is {0} collection runs per day, versus 1 with the default setup." -f $perDay) -ForegroundColor Yellow
    Write-Host 'RISK: every run hits the same non-public endpoint. Higher frequency' -ForegroundColor Yellow
    Write-Host '      raises the chance of rate limiting, temporary blocks, or the' -ForegroundColor Yellow
    Write-Host '      platform invalidating your session. There is no guarantee that' -ForegroundColor Yellow
    Write-Host '      a blocked account is recoverable by this tool.' -ForegroundColor Yellow
    Write-Host 'GAIN: finer progress samples, so you can tell replays and drop-off' -ForegroundColor Yellow
    Write-Host '      points apart. Nothing more is collected per run.' -ForegroundColor Yellow
    Write-Host ('Turn it off with: -Sampling off') -ForegroundColor Yellow
    Write-Host '=========================================' -ForegroundColor Yellow
    Write-Host ''
    $reply = 'n'
    if ($Yes) { $reply = 'y' } else { $reply = Read-Host 'Type YES to enable' }
    if ($reply -ne 'YES' -and $reply -ne 'y') {
        Write-Host 'cancelled; sampling stays disabled.' -ForegroundColor Green
        exit 0
    }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode history -TimeoutMinutes 10 -Retries 0' -f $Runner
    $action = New-ScheduledTaskAction -Execute $PsExe -Argument $argLine -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes($minutes)) `
        -RepetitionInterval (New-TimeSpan -Minutes $minutes) `
        -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $settings2 = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $sampPrincipal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
    if (-not $DryRun) {
        Register-ScheduledTask -TaskName 'DSH-BiliSample' -Action $action -Trigger $trigger `
            -Settings $settings2 -Principal $sampPrincipal -Force `
            -Description ("High-frequency history sampling every {0} min. Risk: rate limiting / session invalidation." -f $minutes) | Out-Null
    }
    Write-Host ("registered DSH-BiliSample: every {0} min" -f $minutes) -ForegroundColor Green
    exit 0
}

if (Get-ScheduledTask -TaskName 'DSH-BiliSample' -ErrorAction SilentlyContinue) {
    if (-not $DryRun) { Disable-ScheduledTask -TaskName 'DSH-BiliSample' | Out-Null }
    Write-Host 'DSH-BiliSample exists but is disabled.'
}

$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 120) `
    -MultipleInstances IgnoreNew

Write-Host ''
Write-Host 'feature    mode       task'
Write-Host '---------  ---------  ----'
foreach ($t in $Tasks) {
    $state = [string]$Auto[$t.Key]
    Write-Host ('{0,-9}  {1,-9}  {2}' -f $t.Key, $state, $t.Name)
    if ($state -eq 'manual') {
        Remove-TaskSafe $t.Name
        continue
    }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1} -TimeoutMinutes {2}' -f $Runner, $t.Mode, $t.Timeout
    if ($t.Mode -eq 'backup' -or $t.Mode -eq 'cold') { $argLine = $argLine + ' -Yes' }
    $action = New-ScheduledTaskAction -Execute $PsExe -Argument $argLine -WorkingDirectory $Root
    if ($t.Cadence -eq 'daily') {
        $trigger = New-ScheduledTaskTrigger -Daily -At $t.Time
    } else {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $t.Time
    }
    if ($DryRun) {
        Write-Host ('  would register ({0} {1})' -f $t.Cadence, $t.Time)
        continue
    }
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $t.Desc -Force | Out-Null
    $next = (Get-ScheduledTaskInfo -TaskName $t.Name).NextRunTime
    Write-Host ('  registered, next={0}' -f $next)
}

Write-Host ''
Write-Host ('startup    {0,-9}  {1}' -f $Auto.Startup, $TrayLnk)
if ($Auto.Startup -eq 'tray') {
    if ($DryRun) {
        Write-Host '  would create the tray startup shortcut'
    } else {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($TrayLnk)
        $s.TargetPath = $PsExe
        $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'tray.ps1') + '"'
        $s.WorkingDirectory = $Root
        $s.Description = 'Bilibili archive tray indicator'
        $s.Save()
        Write-Host ('  tray shortcut: ' + $TrayLnk)
    }
} else {
    Remove-TrayShortcut
}

if ($Save -and -not $DryRun) {
    if (-not $Cfg.PSObject.Properties['Automation']) {
        $Cfg | Add-Member -NotePropertyName Automation -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $Cfg.Automation = [pscustomobject]@{
        Startup    = $Auto.Startup
        History    = $Auto.History
        Favorites  = $Auto.Favorites
        Follows    = $Auto.Follows
        Backup     = $Auto.Backup
        BackupCold = $Auto.BackupCold
    }
    $json = $Cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($CfgFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('saved choices to ' + $CfgFile)
}

Write-Host ''
Write-Host 'manual runs:'
Write-Host '  run-task.ps1 -Mode history|fav|follow|backup|cold'
Write-Host '  or right-click the tray icon.'
