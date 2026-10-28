#requires -version 5.1
<#
  Build the two thin GUI launchers:

    bin\B印象.exe          runs start.cmd
    bin\B印象-卸载.exe     runs uninstall.ps1

  They are tiny C# wrappers (source in src\), not a reimplementation of the
  tool. Unsigned; SmartScreen/antivirus may warn on first run.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1
#>
[CmdletBinding()]
param([string]$OutDir = '')

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
if (-not $OutDir) { $OutDir = Join-Path $Root 'bin' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$csc = ''
foreach ($c in @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)) {
    if (Test-Path $c) { $csc = $c; break }
}
if (-not $csc) { throw 'csc.exe not found (.NET Framework 4.x is required to build the launchers).' }

$prefix = [string][char]0x5370 + [string][char]0x8C61          # 印象
$launcherName = 'B' + $prefix + '.exe'
$uninstallName = 'B' + $prefix + '-' + [char]0x5378 + [char]0x8F7D + '.exe'  # 卸载

$tmpLauncher = Join-Path $OutDir '_launcher.exe'
$tmpUninstall = Join-Path $OutDir '_uninstall.exe'

& $csc /nologo /target:winexe /codepage:65001 /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /out:"$tmpLauncher" (Join-Path $Root 'src\Launcher.cs') (Join-Path $Root 'src\SettingsForm.cs') (Join-Path $Root 'src\UiNotice.cs') (Join-Path $Root 'src\NoticeDialog.cs')
if ($LASTEXITCODE -ne 0) { throw ('launcher compile failed: ' + $LASTEXITCODE) }
& $csc /nologo /target:winexe /codepage:65001 /r:System.Windows.Forms.dll /out:"$tmpUninstall" (Join-Path $Root 'src\Uninstaller.cs') (Join-Path $Root 'src\UiNotice.cs') (Join-Path $Root 'src\NoticeDialog.cs')
if ($LASTEXITCODE -ne 0) { throw ('uninstaller compile failed: ' + $LASTEXITCODE) }

Move-Item -LiteralPath $tmpLauncher -Destination (Join-Path $OutDir $launcherName) -Force
Move-Item -LiteralPath $tmpUninstall -Destination (Join-Path $OutDir $uninstallName) -Force

Write-Host ('built: ' + (Join-Path $OutDir $launcherName))
Write-Host ('built: ' + (Join-Path $OutDir $uninstallName))
