#requires -version 5.1
<#
  Robust wrapper around collect.ps1 / backup-package.ps1 for scheduled use.

  Adds what a bare scheduled task lacks:
    - single-instance lock   (two runs can never overlap and fight over the profile)
    - hard timeout           (kills the whole process tree, not just the parent)
    - bounded retry          (transient network/CDP failures retry, real ones don't loop forever)
    - status.json            (machine-readable state for the tray indicator)
    - per-run log file       (stdout/stderr captured, nothing lost)

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-task.ps1 -Mode history
    ... -Mode fav -TimeoutMinutes 90
    ... -Mode backup
    ... -Mode cold        (text-only cold copy, see backup-cold.ps1)
#>
[CmdletBinding()]
param(
    [ValidateSet('history', 'fav', 'backup', 'follow', 'cold')]
    [string]$Mode = 'history',
    [int]$TimeoutMinutes = 60,
    [int]$Retries = 2,
    [int]$RetryDelaySec = 120,
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
$Cfg = [System.IO.File]::ReadAllText((Join-Path $Root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$DataRoot = [string]$Cfg.DataRoot
$LogDir = Join-Path $DataRoot $Cfg.Dirs.Log
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# Two lock groups: anything that drives the collector browser must serialise
# (one profile, one CDP port), while backup/cold only touch the disk and can run
# alongside a collection instead of being refused.
$diskJob = $Mode -in @('backup', 'cold')
$LockFile = Join-Path $Root $(if ($diskJob) { 'run-backup.lock' } else { 'run.lock' })
# Separate status slots for the same reason: a backup finishing must not
# overwrite the "collecting favourites" state the user is watching.
$StatusFile = Join-Path $Root $(if ($diskJob) { 'status-backup.json' } else { 'status.json' })
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# When launched from a PowerShell 7 host, PSModulePath points at PS7 modules and
# the child Windows PowerShell 5.1 then cannot autoload its own cmdlets. Put the
# 5.1 module roots back at the front of the list before spawning anything.
$v51Modules = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
foreach ($modRoot in @($v51Modules, (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'))) {
    if ($env:PSModulePath -notlike ('*' + $modRoot + '*')) {
        $env:PSModulePath = $modRoot + ';' + $env:PSModulePath
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runLog = Join-Path $LogDir ("run-$Mode-$stamp.log")

function Write-Status {
    param([hashtable]$Data)
    try {
        $Data['updated'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ($Data | ConvertTo-Json -Depth 4) | Set-Content -Path $StatusFile -Encoding UTF8
    } catch { }
}

function Get-TargetScript {
    switch ($Mode) {
        'history' { return @{ File = (Join-Path $Root 'collect.ps1'); Args = '-MaxPages 20' } }
        'fav'     { return @{ File = (Join-Path $Root 'collect.ps1'); Args = '-Fav' } }
        'follow'  { return @{ File = (Join-Path $Root 'collect.ps1'); Args = '-Follow' } }
        'backup'  { return @{ File = (Join-Path $Root 'backup-package.ps1'); Args = '' } }
        'cold'    { return @{ File = (Join-Path $Root 'backup-cold.ps1'); Args = '' } }
    }
}

# ---- single instance lock -------------------------------------------------
$lock = $null
try {
    $lock = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Write-Host "another run holds the lock ($LockFile); exiting."
    exit 9
}

try {
    $target = Get-TargetScript
    if (-not (Test-Path $target.File)) { throw ("missing target script: " + $target.File) }
    if ($Yes -and ($Mode -eq 'backup' -or $Mode -eq 'cold') -and $target.Args -notmatch '(^|\s)-Yes(\s|$)') {
        $target.Args = ($target.Args + ' -Yes').Trim()
    }

    # Refuse to start if some other process already has the collector browser
    # open. Never kill it: an earlier version did exactly that and destroyed a
    # 40-minute manual collection run.
    $profileDir = Join-Path $DataRoot $Cfg.Dirs.Profile
    $busy = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
              Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $profileDir + '*') })
    if ($busy.Count -gt 0 -and $Mode -notin @('backup', 'cold')) {
        # Do NOT write status.json here: the run that owns that browser is very
        # likely still going, and overwriting its "running" with "fail" makes the
        # tray report a failure for a job that is fine.
        Write-Host 'collector browser already in use; exiting without touching it.'
        exit 8
    }

    $attempt = 0
    $exitCode = 1
    $startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    while ($attempt -lt [Math]::Max(1, $Retries + 1)) {
        $attempt++
        Write-Status @{ mode = $Mode; state = 'running'; attempt = $attempt; exit = $null; started = $startedAt; message = 'running'; log = $runLog }

        $errFile = $runLog + '.err'
        $argString = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $target.File
        if ($target.Args) { $argString = $argString + ' ' + $target.Args }

        # System.Diagnostics rather than Start-Process -PassThru: the latter can
        # hand back a process object with no retained handle, leaving ExitCode
        # null and making every successful run look like a failure.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $PsExe
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $Root

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $timeoutMs = [int]($TimeoutMinutes * 60 * 1000)
        $finished = $proc.WaitForExit($timeoutMs)
        if (-not $finished) {
            Write-Host ("timeout after {0} min, killing pid {1}" -f $TimeoutMinutes, $proc.Id)
            & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $exitCode = 124
        } else {
            $proc.WaitForExit()
            if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode } else { $exitCode = 1 }
        }

        # drain and persist the captured output
        try {
            $stdout = ''
            if ($outTask.Wait(10000)) { $stdout = $outTask.Result }
            $stderr = ''
            if ($errTask.Wait(10000)) { $stderr = $errTask.Result }
            [System.IO.File]::WriteAllText($runLog, $stdout, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($errFile, $stderr, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        $proc.Dispose()

        # Only clean up after OUR process was force-killed on timeout. Killing
        # browsers by path alone would also murder an unrelated manual run.
        if ($exitCode -eq 124) {
            $stale = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
                       Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $DataRoot + '*') })
            foreach ($s in $stale) { try { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
            if ($stale.Count -gt 0) { Write-Host ("cleaned {0} browser process(es) after timeout" -f $stale.Count) }
        }

        if ($exitCode -eq 0) { break }
        if ($attempt -le $Retries) {
            Write-Host ("attempt {0} failed (exit {1}); retrying in {2}s" -f $attempt, $exitCode, $RetryDelaySec)
            Start-Sleep -Seconds $RetryDelaySec
        }
    }

    $tail = ''
    if (Test-Path $runLog) {
        # we now persist the captured output ourselves, so it is UTF-8
        $tail = (Get-Content $runLog -Encoding UTF8 -Tail 3) -join ' | '
    }
    Write-Status @{
        mode    = $Mode
        state   = $(if ($exitCode -eq 0) { 'ok' } else { 'fail' })
        attempt = $attempt
        exit    = $exitCode
        started = $startedAt
        ended   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        message = $tail
        log     = $runLog
    }
    Write-Host ("done: mode={0} exit={1} attempts={2}" -f $Mode, $exitCode, $attempt)
    exit $exitCode
}
catch {
    Write-Status @{ mode = $Mode; state = 'fail'; attempt = 0; exit = 1; started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); message = $_.Exception.Message; log = $runLog }
    Write-Host ("FATAL: " + $_.Exception.Message)
    exit 1
}
finally {
    # Last line of defence: if we ever leave without writing a terminal state,
    # status.json stays "running" forever, the tray keeps showing a job that is
    # not there, and the lock blocks every later run.
    try {
        if (Test-Path $StatusFile) {
            $cur = [System.IO.File]::ReadAllText($StatusFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ([string]$cur.state -eq 'running') {
                Write-Status @{
                    mode    = $Mode
                    state   = 'fail'
                    attempt = $(if ($attempt) { $attempt } else { 0 })
                    exit    = $(if ($exitCode) { $exitCode } else { 1 })
                    started = $(if ($startedAt) { $startedAt } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
                    ended   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    message = 'wrapper exited without writing a final status'
                    log     = $runLog
                }
            }
        }
    } catch { }
    if ($lock) { $lock.Dispose() }
    if (Test-Path $LockFile) { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}
