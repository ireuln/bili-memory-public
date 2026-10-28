#requires -version 5.1
<#
  Encoding guard. Windows PowerShell 5.1 decodes a BOM-less .ps1 as the ANSI
  code page (GBK on this machine), so a script that contains Chinese text
  without a UTF-8 BOM is parsed as garbage and fails with misleading
  "missing closing parenthesis" errors.

  Rules enforced here:
    1. Every .ps1 that contains non-ASCII bytes must start with EF BB BF.
    2. Pure-ASCII scripts must NOT have a BOM (keeps diffs and git clean).

    powershell -File .\tools\check-encoding.ps1
    ... -Fix      # add/remove the BOM in place

  Exit codes: 0 clean, 1 problems found.
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [string]$Root = ''
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
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File |
           Where-Object { $_.FullName -notmatch '\\\.git\\' })

$bad = 0
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $start = if ($hasBom) { 3 } else { 0 }
    $nonAscii = $false
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ge 0x80) { $nonAscii = $true; break }
    }

    if ($nonAscii -and -not $hasBom) {
        $bad++
        if ($Fix) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
            [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
            Write-Host ('FIXED  ' + $f.FullName + '  (added BOM)')
        }
        else {
            Write-Host ('NO-BOM ' + $f.FullName + '  (has non-ASCII, will be read as ANSI)')
        }
    }
    elseif (-not $nonAscii -and $hasBom) {
        $bad++
        if ($Fix) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom)
            Write-Host ('FIXED  ' + $f.FullName + '  (removed BOM)')
        }
        else {
            Write-Host ('BOM-ONLY ' + $f.FullName + '  (pure ASCII, BOM is redundant)')
        }
    }
}

if ($bad -gt 0) {
    Write-Host ('FAILED: ' + $bad + ' file(s). Run with -Fix to repair.')
    exit 1
}

Write-Host ('OK: ' + $files.Count + ' script(s) encoded correctly.')
exit 0
