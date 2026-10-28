#requires -version 5.1
<#
  drafts.ps1 - reply-draft scaffolding for the DM archive. Local only.

  This tool never writes a reply and never sends one. It only prepares the
  inputs an AI (or you) needs, and validates what comes back:

    -Queue                 who is waiting for a reply, from metadata only.
                           It reads the DM session list and never touches
                           message bodies.
    -Context -Talker <id>  export that one conversation's context pack.
                           This is the only mode that reads message text, and
                           it must be asked for explicitly, one talker at a time.
    -Validate -Talker <id> check <id>.reply.json against the format and length
                           constraints below.

  Output lives under <DataRoot>\<Dms>\<draftsDir>\ and inherits the DM folder's
  privacy rules: never in the encrypted backup, never in a share payload.

  Examples:
    .\drafts.ps1
    .\drafts.ps1 -Queue -Table
    .\drafts.ps1 -Context -Talker 12590
    .\drafts.ps1 -Validate -Talker 12590

  NOTE: pure ASCII on purpose. Wording comes from config.json's Drafts block.
#>
[CmdletBinding()]
param(
    [switch]$Queue,
    [switch]$Context,
    [switch]$Validate,
    [string]$Talker = '',
    [int]$Turns = 0,
    [switch]$Table
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
$ConfigFile = Join-Path $Root 'config.json'

$Cfg = $null
if (Test-Path $ConfigFile) {
    $Cfg = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}
if (-not $Cfg -or -not $Cfg.DataRoot) {
    Write-Host 'ERROR: config.json missing or has no DataRoot.'
    exit 2
}
. (Join-Path $Root 'lib\ui-lang.ps1')
$Cfg = Merge-UiLanguage -Cfg $Cfg -Root $Root
$DataRoot = [string]$Cfg.DataRoot

function Get-DirName {
    param($C, [string]$Key, [string]$Fallback)
    if ($C -and $C.Dirs) {
        $p = $C.Dirs.PSObject.Properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $Fallback
}

function Get-Text {
    param($C, [string]$Key, [string]$Fallback)
    if ($C -and $C.Text) {
        $p = $C.Text.PSObject.Properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $Fallback
}

# Wording and limits come from config.json so this file stays ASCII.
$Opt = @{
    dir          = 'drafts'
    maxChars     = 120
    shareLabel   = '[share] '
    contextTurns = 20
}
if ($Cfg.Drafts) {
    foreach ($p in $Cfg.Drafts.PSObject.Properties) {
        if ($Opt.ContainsKey($p.Name)) { $Opt[$p.Name] = $p.Value }
    }
}
$MaxChars = [int]$Opt.maxChars
if ($Turns -le 0) { $Turns = [int]$Opt.contextTurns }

$DirDms = Join-Path $DataRoot (Get-DirName $Cfg 'Dms' 'dms')
$SessionsFile = Join-Path $DirDms (Get-Text $Cfg 'dmsSessionsFile' 'dm-sessions.jsonl')
$MsgDir = Join-Path $DirDms 'messages'
$DraftDir = Join-Path $DirDms ([string]$Opt.dir)

if (-not (Test-Path $DirDms)) {
    Write-Host ('ERROR: DM directory not found: ' + $DirDms)
    exit 3
}
if (-not (Test-Path $DraftDir)) { New-Item -ItemType Directory -Force -Path $DraftDir | Out-Null }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertFrom-Ts {
    param([int64]$Epoch)
    if ($Epoch -le 0) { return '' }
    return [DateTimeOffset]::FromUnixTimeSeconds($Epoch).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Get-SafeId {
    param([string]$Text)
    if ($Text -match '^[0-9]+$') { return $Text }
    return ''
}

# ---------------------------------------------------------------- queue
# Metadata only: the session list has talker_id / last_ts / unread / last_from_me and
# no message text at all.

function Invoke-Queue {
    if (-not (Test-Path $SessionsFile)) {
        Write-Host ('ERROR: session list not found: ' + $SessionsFile)
        Write-Host 'Run collect.ps1 -Dms once to build it.'
        exit 3
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $rows = New-Object System.Collections.ArrayList

    foreach ($line in [System.IO.File]::ReadLines($SessionsFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $s = $null
        try { $s = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $s.talker_id) { continue }

        $silent = 0.0
        if ([int64]$s.last_ts -gt 0) { $silent = [math]::Round(($now - [int64]$s.last_ts) / 86400.0, 1) }

        [void]$rows.Add([pscustomobject]@{
            talker_id    = [int64]$s.talker_id
            last_ts      = [int64]$s.last_ts
            last_at      = (ConvertFrom-Ts ([int64]$s.last_ts))
            last_from_me = [bool]$s.last_from_me
            unread       = [int]$s.unread
            days_silent  = $silent
            captured_at  = [string]$s.captured_at
        })
    }

    # Waiting = the last word was theirs. Oldest first, so nothing rots.
    $waiting = @($rows | Where-Object { -not $_.last_from_me } | Sort-Object last_ts)
    $queue = [pscustomobject]@{
        schema    = 1
        generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        sessions  = $rows.Count
        waiting   = $waiting.Count
        items     = $waiting
    }

    $jsonPath = Join-Path $DraftDir 'queue.json'
    [System.IO.File]::WriteAllText($jsonPath, ($queue | ConvertTo-Json -Depth 4), $Utf8NoBom)

    if ($Table) {
        if ($waiting.Count -eq 0) { Write-Host 'nothing waiting for a reply.' }
        else {
            $waiting | ForEach-Object {
                [pscustomobject]@{
                    talker  = $_.talker_id
                    last_at = $_.last_at
                    days    = $_.days_silent
                    unread  = $_.unread
                }
            } | Format-Table -AutoSize | Out-String -Width 120
        }
    }

    Write-Host ('sessions={0} waiting={1}' -f $rows.Count, $waiting.Count)
    Write-Host ('queue -> ' + $jsonPath)
    exit 0
}

# ---------------------------------------------------------------- context

function Invoke-Context {
    $id = Get-SafeId $Talker
    if ($id -eq '') {
        Write-Host 'ERROR: -Context needs -Talker <numeric talker id>.'
        Write-Host 'Run .\drafts.ps1 -Table first to see the waiting ids.'
        exit 2
    }

    $msgFile = Join-Path $MsgDir ($id + '.jsonl')
    if (-not (Test-Path $msgFile)) {
        Write-Host ('ERROR: no message file for talker ' + $id + ': ' + $msgFile)
        exit 3
    }

    $all = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadLines($msgFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $m = $null
        try { $m = $line | ConvertFrom-Json } catch { continue }

        $role = 'them'
        if ($m.from_me) { $role = 'me' }

        $text = [string]$m.content
        $kind = 'text'
        if ([int]$m.type -ne 1) {
            # Cards and shares arrive as JSON blobs; keep the title if there is one.
            $kind = 'other'
            try {
                $inner = $text | ConvertFrom-Json
                if ($inner.title) { $text = [string]$Opt.shareLabel + [string]$inner.title }
                else { $text = '[' + [int]$m.type + ']' }
            }
            catch { $text = '[' + [int]$m.type + ']' }
        }
        if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...' }

        [void]$all.Add([pscustomobject]@{
            ts   = [int64]$m.ts
            role = $role
            kind = $kind
            text = $text
        })
    }

    $all = @($all | Sort-Object ts)
    $tail = @()
    if ($all.Count -gt 0) {
        $start = 0
        if ($all.Count -gt $Turns) { $start = $all.Count - $Turns }
        $tail = @($all | Select-Object -Skip $start)
    }

    $lastThem = $null
    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
        if ($tail[$i].role -eq 'them') { $lastThem = $tail[$i]; break }
    }

    $pack = [pscustomobject]@{
        schema      = 1
        talker_id   = [int64]$id
        generated   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        turns       = $tail
        last_from_them = $lastThem
        constraints = [pscustomobject]@{
            max_chars    = $MaxChars
            auto_send    = $false
            must_be_text = $true
        }
        reply_file  = ($id + '.reply.json')
    }

    $ctxPath = Join-Path $DraftDir ($id + '.ctx.json')
    [System.IO.File]::WriteAllText($ctxPath, ($pack | ConvertTo-Json -Depth 6), $Utf8NoBom)

    # Human/LLM friendly view with an empty draft block and a filled-in example.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# ' + $id)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## context')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| time | who | text |')
    [void]$sb.AppendLine('|---|---|---|')
    foreach ($t in $tail) {
        $who = 'them'
        if ($t.role -eq 'me') { $who = 'me' }
        $safe = ([string]$t.text).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
        [void]$sb.AppendLine('| ' + (ConvertFrom-Ts $t.ts) + ' | ' + $who + ' | ' + $safe + ' |')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## constraints')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- max_chars: ' + $MaxChars)
    [void]$sb.AppendLine('- this tool never sends; you paste it yourself')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## reply')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Write the reply into `' + $id + '.reply.json` as:')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('```json')
    [void]$sb.AppendLine('{ "schema": 1, "talker_id": ' + $id + ', "text": "<your reply>" }')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Then: .\drafts.ps1 -Validate -Talker ' + $id)

    $mdPath = Join-Path $DraftDir ($id + '.md')
    [System.IO.File]::WriteAllText($mdPath, $sb.ToString(), $Utf8NoBom)

    Write-Host ('turns={0} -> {1}' -f $tail.Count, $ctxPath)
    if ($lastThem) { Write-Host ('last from them: ' + (ConvertFrom-Ts ([int64]$lastThem.ts))) }
    exit 0
}

# ---------------------------------------------------------------- validate

function Invoke-Validate {
    $id = Get-SafeId $Talker
    if ($id -eq '') {
        Write-Host 'ERROR: -Validate needs -Talker <numeric talker id>.'
        exit 2
    }

    $replyPath = Join-Path $DraftDir ($id + '.reply.json')
    if (-not (Test-Path $replyPath)) {
        Write-Host ('FAIL: missing ' + $replyPath)
        exit 3
    }

    $problems = New-Object System.Collections.ArrayList
    $r = $null
    try {
        $r = [System.IO.File]::ReadAllText($replyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-Host 'FAIL: reply file is not valid JSON.'
        exit 3
    }

    if ($null -eq $r.schema -or [int]$r.schema -ne 1) { [void]$problems.Add('schema must be 1') }
    if ($null -eq $r.talker_id) { [void]$problems.Add('talker_id is required') }
    elseif ([int64]$r.talker_id -ne [int64]$id) { [void]$problems.Add('talker_id does not match') }

    $text = ''
    if ($null -ne $r.text) { $text = ([string]$r.text).Trim() }
    if ($text -eq '') { [void]$problems.Add('text is empty') }
    elseif ($text.Length -gt $MaxChars) { [void]$problems.Add('text is ' + $text.Length + ' chars, limit is ' + $MaxChars) }
    if ($text.Contains('{{') -or $text.Contains('}}')) { [void]$problems.Add('text still contains an unfilled placeholder') }

    if ($problems.Count -gt 0) {
        Write-Host ('FAIL: ' + $problems.Count + ' problem(s)')
        foreach ($p in $problems) { Write-Host ('  - ' + $p) }
        exit 3
    }

    Write-Host ('PASS: ' + $text.Length + '/' + $MaxChars + ' chars, ready to paste by hand.')
    exit 0
}

# ---------------------------------------------------------------- dispatch

if ($Context) { Invoke-Context }
if ($Validate) { Invoke-Validate }
Invoke-Queue
