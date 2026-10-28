#requires -version 5.1
<#
  Minimal application log used by the GUI scripts.

  Level comes from config.json -> LogLevel:
    normal  (default) : startup, menu actions, warnings, errors
    debug             : also config paths and extra diagnostics

  File: <DataRoot>\<LogDir>\app-YYYYMMDD.log
  Fallback (no DataRoot yet): %TEMP%\bili-memory-logs\app-YYYYMMDD.log
#>
function Get-AppLogFile {
    param($Cfg, [string]$Root)
    $dir = ''
    if ($Cfg -and $Cfg.DataRoot -and $Cfg.Dirs -and $Cfg.Dirs.Log) {
        $dir = Join-Path ([string]$Cfg.DataRoot) ([string]$Cfg.Dirs.Log)
    }
    if (-not $dir -or -not (Test-Path $dir)) {
        $dir = Join-Path $env:TEMP 'bili-memory-logs'
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ('app-' + (Get-Date -Format 'yyyyMMdd') + '.log'))
}

function Write-AppLog {
    param($Cfg, [string]$Root, [string]$Level, [string]$Message)
    try {
        $lvl = 'normal'
        if ($Cfg -and $Cfg.LogLevel) { $lvl = [string]$Cfg.LogLevel }
        if ($lvl -ne 'debug' -and $Level -eq 'debug') { return }
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + ' [' + $Level + '] ' + $Message
        Add-Content -LiteralPath (Get-AppLogFile -Cfg $Cfg -Root $Root) -Value $line -Encoding UTF8
    } catch { }
}
