#requires -version 5.1
<#
  Test entry point. Windows ships Pester 3.4, so this runs with zero install.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1

  Exit codes: 0 all pass (or Pester unavailable -> skip), 1 failures.
  ASCII-only on purpose: the product targets Windows PowerShell 5.1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host 'SKIP: Pester is not installed (Windows ships 3.4; this should not happen).'
    exit 0
}

Import-Module Pester -ErrorAction Stop
$script = Join-Path $PSScriptRoot 'lib.tests.ps1'
if (-not (Test-Path $script)) { Write-Host ('missing: ' + $script); exit 2 }

$r = Invoke-Pester -Script $script -PassThru
Write-Host ('Pester ' + $pester.Version + ': passed ' + $r.PassedCount + ' / failed ' + $r.FailedCount + ' / skipped ' + $r.SkippedCount)
if ($r.FailedCount -gt 0) { exit 1 }
exit 0
