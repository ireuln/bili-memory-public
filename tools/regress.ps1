#requires -version 5.1
<#
  One-command regression for this repo.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\regress.ps1
    ... -WithGui      also run gui-smoke (needs a desktop session)
    ... -SkipAnalyzer skip PSScriptAnalyzer (e.g. module not installed)

  Steps:
    [1/5] check-encoding   : every .ps1 must follow the BOM rule
    [2/5] PSScriptAnalyzer : errors fail the run, warnings are reported
    [3/5] selftest         : read-only install checks (no network, no writes)
    [4/5] tests            : Pester behaviour tests for lib\ helpers
    [5/5] gui-smoke        : optional tray smoke (process + UIA + file diff)

  Exit codes: 0 all pass, 1 one or more failed, 2 bad repo root.
  ASCII-only on purpose: the product targets Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [switch]$WithGui,
    [switch]$SkipAnalyzer,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSCommandPath }
# This script lives in tools\, so -File resolves Root to the tools dir.
if (-not (Test-Path (Join-Path $Root 'collect.ps1'))) {
    $parent = Split-Path -Parent $Root
    if ($parent -and (Test-Path (Join-Path $parent 'collect.ps1'))) { $Root = $parent }
}
if (-not (Test-Path (Join-Path $Root 'collect.ps1'))) {
    Write-Host "not a B-Impression repo root: $Root" -ForegroundColor Red
    exit 2
}

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $env:TEMP ("bili-regress-$stamp.log")
$results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Step, [string]$State, [string]$Detail = '')
    [void]$results.Add([pscustomobject]@{ Step = $Step; State = $State; Detail = $Detail })
    $color = switch ($State) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  [" + $State + "] " + $Step + "  " + $Detail) -ForegroundColor $color
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("[..] " + $Name)
    try {
        $r = & $Body
        return $r
    } catch {
        Add-Result $Name 'FAIL' $_.Exception.Message
        return $null
    }
}

Write-Host ("B-Impression regression  root=" + $Root)
Write-Host ("log: " + $logFile)
Start-Transcript -Path $logFile -Force | Out-Null

# --- [1/5] encoding ----------------------------------------------------------
$enc = Invoke-Step 'check-encoding' {
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\check-encoding.ps1') 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Out = ($out -join "`n") }
}
if ($enc) {
    if ($enc.Code -eq 0) { Add-Result 'check-encoding' 'PASS' 'all .ps1 follow the BOM rule' }
    else { Add-Result 'check-encoding' 'FAIL' (($enc.Out -split "`n" | Where-Object { $_ -match 'NO-BOM|BOM-ONLY|FAILED' } | Select-Object -First 3) -join ' | ') }
}

# --- [2/5] PSScriptAnalyzer --------------------------------------------------
if ($SkipAnalyzer) {
    Add-Result 'PSScriptAnalyzer' 'SKIP' 'requested'
} else {
    $settingsPath = Join-Path $Root '.psscriptanalyzer.psd1'
    $pssaOut = $null
    $haveModule = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
    if ($haveModule) {
        $pssaOut = Invoke-Step 'PSScriptAnalyzer' {
            Import-Module PSScriptAnalyzer -ErrorAction Stop
            $f = Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $settingsPath -ErrorAction Stop
            [pscustomobject]@{ Errors = @($f | Where-Object Severity -eq 'Error'); Warnings = @($f | Where-Object Severity -eq 'Warning') }
        }
    } elseif (Get-Command pwsh -ErrorAction SilentlyContinue) {
        # The module may live in the PowerShell 7 module paths only.
        $probe = Join-Path $env:TEMP ("pssa-probe-$stamp.ps1")
        $body = @'
Import-Module PSScriptAnalyzer -ErrorAction Stop
$f = Invoke-ScriptAnalyzer -Path "__ROOT__" -Recurse -Settings "__SETTINGS__" -ErrorAction Stop
"errors=" + @($f | Where-Object Severity -eq 'Error').Count
"warnings=" + @($f | Where-Object Severity -eq 'Warning').Count
@($f | Where-Object Severity -eq 'Error' | Select-Object -First 10 | ForEach-Object { $_.RuleName + " " + (Split-Path $_.ScriptName -Leaf) + " L" + $_.Line })
'@
        $body = $body.Replace('__ROOT__', $Root).Replace('__SETTINGS__', $settingsPath)
        [System.IO.File]::WriteAllText($probe, $body, (New-Object System.Text.UTF8Encoding($false)))
        try {
            $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1
            $code = $LASTEXITCODE
            $lineE = ($out | Where-Object { $_ -match '^errors=(\d+)' })
            $lineW = ($out | Where-Object { $_ -match '^warnings=(\d+)' })
            $eCount = if ($lineE) { [int]([regex]::Match($lineE, 'errors=(\d+)').Groups[1].Value) } else { -1 }
            $wCount = if ($lineW) { [int]([regex]::Match($lineW, 'warnings=(\d+)').Groups[1].Value) } else { -1 }
            if ($code -eq 0 -and $eCount -ge 0) {
                Add-Result 'PSScriptAnalyzer' 'PASS' ("via pwsh 7: errors=" + $eCount + " warnings=" + $wCount)
                if ($eCount -gt 0) {
                    $results[$results.Count - 1].State = 'FAIL'
                    $results[$results.Count - 1].Detail = ($eCount.ToString() + ' error(s) via pwsh 7')
                }
            } else {
                Add-Result 'PSScriptAnalyzer' 'SKIP' 'pwsh 7 cannot load the module'
            }
        } finally {
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        }
    } else {
        Add-Result 'PSScriptAnalyzer' 'SKIP' 'module not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
    }
    if ($haveModule -and $pssaOut) {
        $e = $pssaOut.Errors.Count
        $w = $pssaOut.Warnings.Count
        if ($e -gt 0) { Add-Result 'PSScriptAnalyzer' 'FAIL' ($e.ToString() + ' error(s), ' + $w + ' warning(s)') }
        else { Add-Result 'PSScriptAnalyzer' 'PASS' ('0 error(s), ' + $w + ' warning(s)') }
    }
}

# --- [3/5] selftest ----------------------------------------------------------
if (-not (Test-Path (Join-Path $Root 'config.json'))) {
    Add-Result 'selftest' 'SKIP' 'no config.json yet (run setup.ps1 first)'
} else {
$st = Invoke-Step 'selftest' {
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'selftest.ps1') -SkipData 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
if ($st) {
    if ($st.Code -eq 0) {
        $okLine = ($st.Out -split "`n" | Where-Object { $_ -match '^OK:' } | Select-Object -First 1)
        Add-Result 'selftest' 'PASS' ($okLine -replace '^\s+', '')
    } else {
        Add-Result 'selftest' 'FAIL' ('exit ' + $st.Code + '; see ' + $logFile)
    }
}

}

# --- [4/5] behaviour tests ---------------------------------------------------
$tests = Invoke-Step 'tests' {
    $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\run.ps1') 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
if ($tests) {
    if ($tests.Code -eq 0) {
        $line = ($tests.Out -split "`n" | Where-Object { $_ -match '^Pester' } | Select-Object -First 1)
        if (-not $line) { $line = 'ok' }
        Add-Result 'tests' 'PASS' ($line -replace '^\s+', '')
    } else {
        Add-Result 'tests' 'FAIL' ('exit ' + $tests.Code + '; see ' + $logFile)
    }
}

# --- [5/5] gui smoke (optional) ---------------------------------------------
if ($WithGui) {
    $gs = Invoke-Step 'gui-smoke' {
        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'gui-smoke.ps1') -MutexSuffix regress 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
    }
    if ($gs) {
        if ($gs.Code -eq 0) { Add-Result 'gui-smoke' 'PASS' 'tray window + single instance + clean exit' }
        else { Add-Result 'gui-smoke' 'FAIL' ('exit ' + $gs.Code + '; see ' + $logFile) }
    }
} else {
    Add-Result 'gui-smoke' 'SKIP' 'use -WithGui to enable'
}

Stop-Transcript | Out-Null

$failed = @($results | Where-Object State -eq 'FAIL')
Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($failed.Count -gt 0) {
    Write-Host ('FAILED: ' + $failed.Count + ' step(s). Log: ' + $logFile) -ForegroundColor Red
    exit 1
}
Write-Host ('OK: ' + $results.Count + ' step(s). Log: ' + $logFile) -ForegroundColor Green
exit 0
