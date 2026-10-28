#requires -version 5.1
<#
  Pre-publish secret scan.

  Two layers:
    1. Generic patterns that must never appear in a public repo (absolute user
       paths, cookies, tokens, private keys, long digit runs).
    2. Personal patterns read from .secret-patterns - a LOCAL, git-ignored file
       holding your own identifiers (uid, phone, mailbox). Keeping them out of
       this script is the whole point: the scanner itself gets published.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-secrets.ps1
    ... -File .\tools\check-secrets.ps1 -Staged     # only staged files
    ... -File .\tools\check-secrets.ps1 -History    # every commit too

  Exit codes: 0 clean, 1 hit found.
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [switch]$History,
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
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

$gitCandidates = @(
    'git',
    'C:\Program Files\Git\cmd\git.exe'
)
$git = $null
foreach ($g in $gitCandidates) {
    try { $null = & $g --version 2>$null; $git = $g; break } catch { }
}
if (-not $git) { Write-Host 'git not found; cannot scan' -ForegroundColor Red; exit 2 }

# Patterns here must be ASCII-only and use POSIX ERE (git grep does not support
# lookarounds). Anything specific to you - Chinese names, your uid, your phone -
# belongs in .secret-patterns instead, because this file gets published.
$generic = @(
    'C:\\+Users\\+[A-Za-z0-9._-]+',
    'SESSDATA\s*=\s*[A-Za-z0-9%]',
    'bili_jct\s*=\s*[A-Za-z0-9]',
    'gh[pousr]_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '1[3-9][0-9]{9}'
)

$personal = @()
$personalFile = Join-Path $Root '.secret-patterns'
if (Test-Path $personalFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($personalFile)) {
        $s = $line.Trim()
        if ($s -and -not $s.StartsWith('#')) { $personal += $s }
    }
}

$patterns = @($generic) + @($personal)
$hits = 0

function Scan-Tree {
    param([string[]]$ExtraArgs)
    foreach ($pat in $patterns) {
        $args = @('grep', '-n', '-I', '-E', '--', $pat) + $ExtraArgs
        $res = & $git @args 2>$null
        if ($res) {
            foreach ($line in $res) {
                $script:hits++
                if (-not $Quiet) { Write-Host ("HIT  [{0}]  {1}" -f $pat, $line) -ForegroundColor Red }
            }
        }
    }
}

if ($Staged) {
    if (-not $Quiet) { Write-Host 'scanning staged files only...' }
    $stagedFiles = & $git -c core.quotepath=false diff --cached --name-only --diff-filter=ACM
    foreach ($f in $stagedFiles) {
        if (-not (Test-Path $f)) { continue }
        foreach ($pat in $patterns) {
            $res = Select-String -Path $f -Pattern $pat -ErrorAction SilentlyContinue
            foreach ($r in $res) {
                $hits++
                if (-not $Quiet) { Write-Host ("HIT  {0}:{1}  [{2}]" -f $f, $r.LineNumber, $pat) -ForegroundColor Red }
            }
        }
    }
} else {
    if (-not $Quiet) { Write-Host 'scanning tracked files...' }
    Scan-Tree @('--', '.')
    if ($History) {
        if (-not $Quiet) { Write-Host 'scanning full history...' }
        $revs = & $git rev-list --all
        if ($revs) { Scan-Tree $revs }
    }
}

if ($hits -gt 0) {
    Write-Host ("`nFAILED: {0} potential leak(s). Fix before pushing." -f $hits) -ForegroundColor Red
    exit 1
}
if (-not $Quiet) { Write-Host 'CLEAN: no sensitive pattern found.' -ForegroundColor Green }
exit 0
