#requires -version 5.1
<#
  Read-only update check. It does NOT download or replace anything.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\check-update.ps1
    ... -Quiet     (exit code only: 0 up to date, 1 newer, 2 check failed)

  Uses version.json -> repo and GitHub's public releases API. No telemetry:
  the only request is to api.github.com, and only when you run this script.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
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
$InfoFile = Join-Path $Root 'version.json'
if (-not (Test-Path $InfoFile)) { if (-not $Quiet) { Write-Host 'version.json missing.' }; exit 2 }
$Info = [System.IO.File]::ReadAllText($InfoFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$current = [string]$Info.version
$repoUrl = [string]$Info.repo
$m = [regex]::Match($repoUrl, 'github\.com/([^/]+)/([^/#]+)')
if (-not $m.Success) { if (-not $Quiet) { Write-Host 'repo URL in version.json is not a GitHub URL.' }; exit 2 }
$api = 'https://api.github.com/repos/' + $m.Groups[1].Value + '/' + $m.Groups[2].Value + '/releases/latest'

$headers = @{ 'User-Agent' = 'bili-memory-update-check'; 'Accept' = 'application/vnd.github+json' }
try {
    $release = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 20
} catch {
    if (-not $Quiet) {
        Write-Host ('update check unavailable: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('repo: ' + $repoUrl + '  (not published yet?)')
    }
    exit 2
}

$latest = ([string]$release.tag_name).TrimStart('v', 'V')
$latestCore = ($latest -split '-')[0]
$currentCore = ($current -split '-')[0]
$newer = $false
try { $newer = ([version]$latestCore -gt [version]$currentCore) } catch { $newer = ($latestCore -ne $currentCore) }

if ($Quiet) {
    if ($newer) { exit 1 } else { exit 0 }
}

Write-Host ('current : ' + $current)
Write-Host ('latest  : ' + $latest)
if ($newer) {
    Write-Host ('newer release: ' + $release.html_url) -ForegroundColor Green
    Write-Host 'download it, close the tray, replace the scripts, keep config.json and DataRoot.'
    exit 1
}
Write-Host 'up to date.' -ForegroundColor Green
exit 0
