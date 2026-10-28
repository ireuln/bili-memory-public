#requires -version 5.1
<#
  Read-only self check. No network, no writes, no scheduled-task changes.
  Verifies that the install is coherent before you exercise the features.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\selftest.ps1
    ... -File .\selftest.ps1 -SkipData   (skip query/report reads)

  Exit codes: 0 all passed, 1 one or more failed, 2 config.json missing.
#>
[CmdletBinding()]
param(
    [switch]$SkipData,
    [string]$RootDir = ''
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
if ($RootDir) { $Root = (Resolve-Path $RootDir).Path } else { $Root = Split-Path -Parent $PSCommandPath }
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    [void]$checks.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
}

function Invoke-Child {
    # Not $Args: that name is an automatic variable, so the parameter is never
    # populated and every switch was silently dropped ('-Json' included).
    param([string]$Script, [string]$ArgText = '')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root $Script))
    if ($ArgText) { $argList += $ArgText.Split(' ') }
    $out = & $PsExe @argList 2>&1
    return @{ Exit = $LASTEXITCODE; Out = ($out -join "`n") }
}

$cfgFile = Join-Path $Root 'config.json'
if (-not (Test-Path $cfgFile)) {
    Write-Host 'config.json not found; run setup.ps1 first.' -ForegroundColor Red
    exit 2
}
$cfg = [System.IO.File]::ReadAllText($cfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Add-Check 'config.json parses' $true

$browserCfg = [string]$cfg.BrowserExe
$browserCandidates = @()
if ($browserCfg) {
    $browserCandidates = @($browserCfg)
} else {
    $browserCandidates = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
    )
}
$browserFound = @($browserCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
if ($browserFound.Count -gt 0) {
    Add-Check 'browser exe' $true $browserFound[0]
} else {
    Add-Check 'browser exe' $false 'not found; install Edge/Chrome or set BrowserExe'
}

$seven = [string]$cfg.SevenZip
if ($seven -and (Test-Path $seven)) {
    Add-Check '7-Zip exe' $true $seven
} else {
    Add-Check '7-Zip exe' $true 'not found; plain ZIP fallback (no encryption)'
}

# ---- platform dependencies (clean Windows 10/11 should have all of these) ----
$psv = $PSVersionTable.PSVersion
Add-Check 'PowerShell 5.1+' ($psv.Major -ge 5) ($psv.ToString())

$netRelease = 0
try {
    $netRelease = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release
} catch { }
Add-Check '.NET Framework 4.8+' ($netRelease -ge 528040) ('release ' + $netRelease)

Add-Check 'Compress-Archive' ([bool](Get-Command Compress-Archive -ErrorAction SilentlyContinue)) 'ZIP fallback'
Add-Check 'ScheduledTasks module' ([bool](Get-Module -ListAvailable ScheduledTasks)) 'scheduled automation'
Add-Check 'cmd.exe' (Test-Path (Join-Path $env:SystemRoot 'System32\cmd.exe')) 'start.cmd / launcher'

$winForms = $false
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $winForms = $true } catch { }
Add-Check 'WinForms' $winForms 'tray icon and confirmation dialogs'

$data = [string]$cfg.DataRoot
Add-Check 'DataRoot' ([bool]$data -and (Test-Path $data)) $data

if ($data -and $cfg.Dirs) {
    foreach ($k in @('History', 'Fav', 'Cover', 'Profile', 'Log')) {
        $name = [string]$cfg.Dirs.$k
        if (-not $name) { continue }
        $p = Join-Path $data $name
        Add-Check ('dir ' + $k) (Test-Path $p) $p
    }
}

# Optional content layer: absence is normal (it is filled by a tool of the owner's
# choosing), presence is reported. Never fails the run.
$contentDetail = 'not used (optional)'
if ($data) {
    $contentName = ''
    if ($cfg.Dirs -and $cfg.Dirs.Content) { $contentName = [string]$cfg.Dirs.Content }
    if (-not $contentName) { $contentName = 'content' }
    $contentPath = Join-Path $data $contentName
    if (Test-Path $contentPath) {
        $cc = @(Get-ChildItem -LiteralPath $contentPath -Directory -ErrorAction SilentlyContinue).Count
        $cb = [int64]0
        foreach ($cf in @(Get-ChildItem -LiteralPath $contentPath -Recurse -File -ErrorAction SilentlyContinue)) {
            $cb += [int64]$cf.Length
        }
        $contentDetail = ('' + $cc + ' item(s), ' + [math]::Round($cb / 1MB, 1) + ' MB')
        if ($cb -ge 5GB) { $contentDetail = $contentDetail + ' [over 5 GB]' }
        elseif ($cb -ge 1GB) { $contentDetail = $contentDetail + ' [over 1 GB]' }
    }
}
Add-Check 'content layer (optional)' $true $contentDetail

foreach ($s in @('collect.ps1', 'query.ps1', 'report.ps1', 'backup-package.ps1', 'run-task.ps1')) {
    Add-Check ('script ' + $s) (Test-Path (Join-Path $Root $s))
}

if (-not $SkipData) {
    $q = Invoke-Child 'query.ps1' '-Limit 1 -Json'
    $qOk = $false
    $qDetail = ('exit ' + $q.Exit)
    if ($q.Exit -eq 0) {
        try { $null = $q.Out | ConvertFrom-Json; $qOk = $true; $qDetail = 'JSON parsed' } catch { $qDetail = 'invalid JSON' }
    }
    Add-Check 'query.ps1 -Limit 1 -Json' $qOk $qDetail

    $r = Invoke-Child 'report.ps1' '-Json'
    $rOk = $false
    $rDetail = ('exit ' + $r.Exit)
    if ($r.Exit -eq 0) {
        try { $null = $r.Out | ConvertFrom-Json; $rOk = $true; $rDetail = 'JSON parsed' } catch { $rDetail = 'invalid JSON' }
    }
    Add-Check 'report.ps1 -Json' $rOk $rDetail
}

$v = Invoke-Child 'backup-package.ps1' '-Verify -NoShortcut'
Add-Check 'backup-package.ps1 -Verify' ($v.Exit -eq 0) ('exit ' + $v.Exit)

Write-Host ''
$checks | Format-Table -AutoSize
$failed = @($checks | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
    Write-Host ('FAILED: ' + $failed.Count + ' check(s).') -ForegroundColor Red
    exit 1
}
Write-Host ('OK: ' + $checks.Count + ' check(s) passed.') -ForegroundColor Green
exit 0
