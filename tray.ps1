#requires -version 5.1
<#
  Notification-area indicator for the Bilibili archive collector.

  Reads status.json written by run-task.ps1 and shows an original "winged V"
  badge: purple field, gold ring, cream mark, with a pulsing glow. The ring
  colour still encodes state:
    green = last run ok        amber = running
    red   = last run failed    grey  = never ran

  The mark is an original graphic in a Code Geass-ish palette; it is not a
  reproduction of any character art or sigil.

  Animation: a NotifyIcon cannot play video, only swap bitmaps, so frames are
  pre-rendered once per colour and cycled by a timer.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tray.ps1
    ... -File .\tray.ps1 -NoAnimation
#>
[CmdletBinding()]
param(
    [switch]$NoAnimation,
    [int]$FrameCount = 12,
    [int]$FrameDelayMs = 90,
    [switch]$PopupPreview,
    [switch]$MenuPreview,
    [int]$PreviewSeconds = 0
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
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Single instance: double-clicking the launcher again must not add a second icon.
$trayMutex = New-Object System.Threading.Mutex($false, 'Local\BiliMemoryTray')
if (-not $trayMutex.WaitOne(0)) { exit 0 }

$Root = Split-Path -Parent $PSCommandPath
$Cfg = [System.IO.File]::ReadAllText((Join-Path $Root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
. (Join-Path $Root 'lib\ui-lang.ps1')
$Cfg = Merge-UiLanguage -Cfg $Cfg -Root $Root
. (Join-Path $Root 'lib\app-log.ps1')
$StatusFile = Join-Path $Root 'status.json'
$DataRoot = [string]$Cfg.DataRoot
$LogDir = Join-Path $DataRoot $Cfg.Dirs.Log
Write-AppLog -Cfg $Cfg -Root $Root -Level info -Message ('tray start pid=' + $PID + ' ui=' + [string]$Cfg.UiLanguage)
Write-AppLog -Cfg $Cfg -Root $Root -Level debug -Message ('root=' + $Root + ' data=' + $DataRoot)

# A single throwing event handler must not take the tray down. By default
# WinForms shows the "unhandled exception" dialog and the process exits, so one
# bad click (or a queued event after a form was disposed) kills the icon until
# the next logon. Catch it, log it, keep running.
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try {
        Write-AppLog -Cfg $Cfg -Root $Root -Level error -Message ('ui exception caught: ' + $e.Exception.GetType().Name + ': ' + $e.Exception.Message)
    } catch { }
})

$L = $Cfg.Tray
function Lbl { param([string]$Key, [string]$Fallback) if ($L -and $L.PSObject.Properties[$Key]) { return [string]$L.PSObject.Properties[$Key].Value } return $Fallback }

$TxtOk = Lbl 'okPrefix' 'Bili archive'
$TxtRunning = Lbl 'running' 'running'
$TxtFail = Lbl 'failed' 'failed'
$TxtUnknown = Lbl 'unknown' 'not run yet'
$MenuHistory = Lbl 'menuHistory' 'Collect history now'
$MenuFav = Lbl 'menuFav' 'Collect favorites now'
$MenuFollow = Lbl 'menuFollow' 'Refresh follows now'
$MenuReport = Lbl 'menuReport' 'Build a report'
$MenuShare = Lbl 'menuShare' 'Build a share card'
$MenuBackup = Lbl 'menuBackup' 'Backup now'
$MenuCold = Lbl 'menuCold' 'Cold text backup now'
$MenuOpen = Lbl 'menuOpen' 'Open archive folder'
$MenuLog = Lbl 'menuLog' 'Open latest log'
$MenuHelp = Lbl 'menuHelp' 'Open help'
$MenuSettings = Lbl 'menuSettings' 'Features & settings'
$MenuUpdate = Lbl 'menuUpdate' 'Check for updates'
$MenuExit = Lbl 'menuExit' 'Exit'
$MenuData = Lbl 'menuData' '数据速览'
$MenuSettingsGroup = Lbl 'menuSettingsGroup' '设置'
$PopupTitle = Lbl 'popupTitle' '数据速览'
$PopupEmpty = Lbl 'popupEmpty' '还没有数据，先采集一次'
$PopupHint = Lbl 'popupHint' '点击别处关闭'
$NoLog = Lbl 'noLog' '还没有日志'

# ---------------------------------------------------------------- drawing

function Get-GlyphPath {
    # Turn a character into a vector path scaled into a target rectangle.
    # The matrix is built explicitly (M11,M12,M21,M22,OffsetX,OffsetY) instead of
    # chaining Scale/Translate, because GDI+ prepends those and the result is
    # easy to get wrong.
    param([string]$Text, [string]$Family, [int]$Style, [System.Drawing.RectangleF]$Target)
    $fam = New-Object System.Drawing.FontFamily $Family
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddString($Text, $fam, $Style, 100, (New-Object System.Drawing.PointF 0, 0), [System.Drawing.StringFormat]::GenericTypographic)
    $b = $p.GetBounds()
    if ($b.Width -le 0 -or $b.Height -le 0) { return $p }
    $sx = $Target.Width / $b.Width
    $sy = $Target.Height / $b.Height
    $ox = $Target.X - $b.X * $sx
    $oy = $Target.Y - $b.Y * $sy
    $m = New-Object System.Drawing.Drawing2D.Matrix -ArgumentList $sx, 0, 0, $sy, $ox, $oy
    $p.Transform($m)
    $m.Dispose(); $fam.Dispose()
    return $p
}
function New-TrayBitmap {
    param([string]$Color, [double]$Phase, [switch]$Animated, [int]$Size = 128)
    $base = switch ($Color) {
        'green' { [System.Drawing.Color]::FromArgb(58, 176, 92) }
        'amber' { [System.Drawing.Color]::FromArgb(240, 176, 32) }
        'red'   { [System.Drawing.Color]::FromArgb(224, 62, 74) }
        default { [System.Drawing.Color]::FromArgb(150, 146, 164) }
    }
    $size = $Size
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $size / 32.0

    # radial-gradient field
    $fp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $fp.AddEllipse((1.4 * $s), (1.4 * $s), (29.2 * $s), (29.2 * $s))
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush $fp
    $pg.CenterPoint = (New-Object System.Drawing.PointF (12.5 * $s), (11 * $s))
    $pg.CenterColor = [System.Drawing.Color]::FromArgb(118, 84, 170)
    $pg.SurroundColors = @([System.Drawing.Color]::FromArgb(42, 26, 68))
    $g.FillPath($pg, $fp)

    if ($Animated) {
        for ($k = 3; $k -ge 1; $k--) {
            $a = [int]((16 + 78 * $Phase) * $k / 6)
            if ($a -lt 1) { continue }
            $gb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, 255, 222, 110))
            $rr = (5 + 2.4 * $k) * $s
            $g.FillEllipse($gb, (16 * $s - $rr), (16 * $s - $rr), (2 * $rr), (2 * $rr))
            $gb.Dispose()
        }
    }

    $ring = New-Object System.Drawing.Pen $base, (2.6 * $s)
    $g.DrawEllipse($ring, (2.0 * $s), (2.0 * $s), (28.0 * $s), (28.0 * $s))

    # the V comes from Segoe UI Bold, so the letterform is a real typeface
    $target = New-Object System.Drawing.RectangleF -ArgumentList (10.2 * $s), (10.2 * $s), (11.6 * $s), (13.8 * $s)
    $vp = Get-GlyphPath -Text 'V' -Family 'Segoe UI' -Style ([int][System.Drawing.FontStyle]::Bold) -Target $target
    $shm = New-Object System.Drawing.Drawing2D.Matrix
    $shm.Translate(0.5 * $s, 0.7 * $s)
    $shp = $vp.Clone()
    $shp.Transform($shm)
    $sb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
    $g.FillPath($sb, $shp)
    $ink = New-Object System.Drawing.Drawing2D.LinearGradientBrush (
        (New-Object System.Drawing.PointF (0), (8 * $s)),
        (New-Object System.Drawing.PointF (0), (26 * $s)),
        [System.Drawing.Color]::White,
        [System.Drawing.Color]::FromArgb(255, 226, 212, 182))
    $g.FillPath($ink, $vp)

    $g.Dispose()
    $fp.Dispose(); $pg.Dispose(); $ring.Dispose()
    $vp.Dispose(); $shp.Dispose(); $shm.Dispose(); $sb.Dispose(); $ink.Dispose()

    return $bmp
}

# ---------------------------------------------------------------- tray

$script:frameCache = @{}
$script:frames = @()
$script:frameIdx = 0
$script:currentColor = ''
$script:popup = $null
$script:popupPinned = $false
$script:popupTimer = $null
$script:popupWasRunning = $null
$script:popupCloseAt = $null
$script:lastRunning = $false
$script:autoUnpinAt = $null
$script:runAlive = $true
$script:popupCloseRect = $null
$script:jobs = @()
$script:popupJobCount = 0
$script:jobScanTick = 0

# Menu groups, top to bottom:
#   1 collect / 2 produce / 3 back up / 4 look at it / 5 settings / exit
# Settings sits alone behind a separator and its own submenu so that a routine
# action ("collect now") can never be mis-clicked for a configuration change.
$context = New-Object System.Windows.Forms.ContextMenuStrip
$miHistory = $context.Items.Add($MenuHistory)
$miFav = $context.Items.Add($MenuFav)
$miFollow = $context.Items.Add($MenuFollow)
[void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miReport = $context.Items.Add($MenuReport)
$miShare = $context.Items.Add($MenuShare)
[void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miBackup = $context.Items.Add($MenuBackup)
$miCold = $context.Items.Add($MenuCold)
[void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miData = $context.Items.Add($MenuData)
$miOpen = $context.Items.Add($MenuOpen)
$miLog = $context.Items.Add($MenuLog)
$miHelp = $context.Items.Add($MenuHelp)
[void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSettingsGroup = New-Object System.Windows.Forms.ToolStripMenuItem $MenuSettingsGroup
$miSettingsGroup.Font = New-Object System.Drawing.Font($miSettingsGroup.Font, [System.Drawing.FontStyle]::Bold)
[void]$context.Items.Add($miSettingsGroup)
$miSettings = $miSettingsGroup.DropDownItems.Add($MenuSettings)
$miUpdate = $miSettingsGroup.DropDownItems.Add($MenuUpdate)
[void]$context.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = $context.Items.Add($MenuExit)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.ContextMenuStrip = $context
$tray.Visible = $true
$tray.Text = $TxtOk + ': ' + $TxtUnknown

function ConvertTo-IcoFile {
    # Assemble a real multi-size .ico (PNG payloads, Vista+). Windows then picks
    # the exact size it needs instead of scaling a 32px bitmap down to 16px.
    param([System.Drawing.Bitmap[]]$Images, [string]$Path)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$Images.Count)
    $offset = 6 + 16 * $Images.Count
    $payloads = New-Object System.Collections.ArrayList
    foreach ($img in $Images) {
        $pms = New-Object System.IO.MemoryStream
        $img.Save($pms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $pms.ToArray()
        $pms.Dispose()
        [void]$payloads.Add($bytes)
        $w = if ($img.Width -ge 256) { 0 } else { $img.Width }
        $h = if ($img.Height -ge 256) { 0 } else { $img.Height }
        $bw.Write([byte]$w); $bw.Write([byte]$h)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($b in $payloads) { $bw.Write($b) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

function New-TrayIcon {
    # Render once at 4x, then downsample to each size: supersampling keeps the
    # small sizes clean without needing a bigger drawing.
    param([string]$Color, [double]$Phase, [switch]$Animated)
    $sizes = @(16, 20, 24, 32, 48)
    $big = New-TrayBitmap -Color $Color -Phase $Phase -Animated:$Animated
    $list = New-Object System.Collections.ArrayList
    foreach ($sz in $sizes) {
        $b = New-Object System.Drawing.Bitmap $sz, $sz
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.DrawImage($big, 0, 0, $sz, $sz)
        $g.Dispose()
        [void]$list.Add($b)
    }
    $tmp = Join-Path $env:TEMP ('bili-ico-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ico')
    ConvertTo-IcoFile -Images $list.ToArray() -Path $tmp
    $ico = New-Object System.Drawing.Icon $tmp
    $big.Dispose()
    foreach ($b in $list) { $b.Dispose() }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $ico
}
function Get-Frames {
    param([string]$Color)
    # Only the "running" state animates; everything else is a single frame.
    $animate = ($Color -eq 'amber') -and (-not $NoAnimation)
    $key = if ($animate) { $Color + '|anim' } else { $Color + '|static' }
    if ($script:frameCache.ContainsKey($key)) { return $script:frameCache[$key] }
    $arr = @()
    if ($animate) {
        for ($i = 0; $i -lt $FrameCount; $i++) {
            $phase = 0.5 - 0.5 * [math]::Cos(2 * [math]::PI * $i / $FrameCount)
            $arr += (New-TrayIcon -Color $Color -Phase $phase -Animated)
        }
    } else {
        $arr += (New-TrayIcon -Color $Color -Phase 0)
    }
    $script:frameCache[$key] = $arr
    return $arr
}
function Set-TrayColor {
    param([string]$Color, [string]$Tooltip)
    if ($Color -ne $script:currentColor) {
        $script:currentColor = $Color
        $script:frames = Get-Frames $Color
        $script:frameIdx = 0
        if ($script:frames.Count -gt 0) { $tray.Icon = $script:frames[0] }
    }
    if ($Tooltip) {
        if ($Tooltip.Length -gt 63) { $Tooltip = $Tooltip.Substring(0, 63) }
        $tray.Text = $Tooltip
    }
}

Set-TrayColor 'grey' ($TxtOk + ': ' + $TxtUnknown)

function Get-Status {
    if (-not (Test-Path $StatusFile)) { return $null }
    try { return ([System.IO.File]::ReadAllText($StatusFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Update-Tray {
    $s = Get-Status
    # A scheduled job can start while nobody is looking: pop the card the first
    # time we see "running", so the job is visible without hunting for the tray.
    $script:jobs = @(Get-RunningJobs)
    $nowRunning = ($script:jobs.Count -gt 0 -or ($s -and [string]$s.state -eq 'running'))
    if ($nowRunning) {
        # status.json can say "running" forever if the wrapper dies; check that
        # a run-task process actually exists before believing it.
        $alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -like '*run-task.ps1*' })
        $script:runAlive = ($alive.Count -gt 0)
    } else {
        $script:runAlive = $true
    }
    if ($nowRunning -and -not $script:lastRunning) {
        # Update-Tray also runs once at the top of this script, before the popup
        # functions are defined, so check the command exists before calling it.
        if (Get-Command Show-DataPopup -ErrorAction SilentlyContinue) {
            if (-not ($script:popup -and -not $script:popup.IsDisposed)) { Show-DataPopup -Auto }
            # an already-open idle card must start ticking too
            if ((Get-Command Start-PopupTimer -ErrorAction SilentlyContinue) -and $script:popup -and -not $script:popup.IsDisposed) { Start-PopupTimer }
        }
    }
    $script:lastRunning = $nowRunning
    if (-not $s) { Set-TrayColor 'grey' ($TxtOk + ': ' + $TxtUnknown); return }
    $state = [string]$s.state
    if ($state -eq 'running') {
        Set-TrayColor 'amber' ($TxtOk + ': ' + $TxtRunning)
    } elseif ($state -eq 'ok') {
        Set-TrayColor 'green' ($TxtOk + ': OK ' + [string]$s.ended)
    } else {
        Set-TrayColor 'red' ($TxtOk + ': ' + $TxtFail + ' ' + [string]$s.ended)
    }
}

function Start-ShareCard {
    # -Open makes share.ps1 hand the finished PNG to the default image viewer.
    # No -NoExit here: the card is the result, the console is just noise.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'share.ps1'), '-Open'
    ) | Out-Null
}
function Start-ScriptVisible {
    param([string]$Script, [string]$Extra = '')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $line = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "' + (Join-Path $Root $Script) + '"'
    if ($Extra) { $line = $line + ' ' + $Extra }
    Start-Process -FilePath $ps -ArgumentList $line | Out-Null
}

# ---------------------------------------------------------------- data popup

function Get-CfgDir {
    param([string]$Key, [string]$Fallback)
    if ($Cfg.Dirs -and $Cfg.Dirs.PSObject.Properties[$Key]) { return [string]$Cfg.Dirs.PSObject.Properties[$Key].Value }
    return $Fallback
}

function Get-DirBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return [int64]0 }
    return [int64]$sum
}

function Get-ArchiveSnapshot {
    # Cheap on purpose: the popup must appear instantly. It counts with regex
    # instead of parsing every line as JSON, and it skips any jsonl that is not
    # named YYYY-MM (稍后观看.jsonl has no view_at and used to inflate numbers).
    $snap = [pscustomobject]@{
        Watch = 0; WatchMonth = 0; Watch7 = 0; ActiveDays7 = 0
        Fav = 0; FavInvalid = 0
        Bytes = [int64]0
        State = 'unknown'; Ended = ''; LastMode = ''
    }
    $histDir = Join-Path $DataRoot (Get-CfgDir 'History' '观看记录')
    $favDir = Join-Path $DataRoot (Get-CfgDir 'Fav' '收藏备份')
    $coverDir = Join-Path $DataRoot (Get-CfgDir 'Cover' '封面图')
    $monthKey = (Get-Date).ToString('yyyy-MM')
    $weekAgo = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7 * 86400
    $days = @{}
    if (Test-Path -LiteralPath $histDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $histDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch '^\d{4}-\d{2}\.jsonl$') { continue }
            $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            $n = 0
            foreach ($m in [regex]::Matches($text, '"view_at"\s*:\s*(\d+)')) {
                $n++
                $t = [int64]$m.Groups[1].Value
                if ($t -ge $weekAgo) {
                    $snap.Watch7++
                    $days[[math]::Floor($t / 86400)] = 1
                }
            }
            $snap.Watch += $n
            if ($f.BaseName -eq $monthKey) { $snap.WatchMonth = $n }
        }
    }
    $snap.ActiveDays7 = $days.Count
    $masterName = '收藏总表.jsonl'
    if ($Cfg.Text -and $Cfg.Text.masterFile) { $masterName = [string]$Cfg.Text.masterFile }
    $master = Join-Path $favDir $masterName
    if (Test-Path -LiteralPath $master) {
        $t = [System.IO.File]::ReadAllText($master, [System.Text.Encoding]::UTF8)
        $snap.Fav = ([regex]::Matches($t, '"folder_id"\s*:')).Count
        $snap.FavInvalid = ([regex]::Matches($t, '"invalid"\s*:\s*true')).Count
    }
    $snap.Bytes = (Get-DirBytes $histDir) + (Get-DirBytes $favDir) + (Get-DirBytes $coverDir)
    $s = Get-Status
    if ($s) { $snap.State = [string]$s.state; $snap.Ended = [string]$s.ended }
    $lr = Join-Path $DataRoot 'last-result.json'
    if (Test-Path -LiteralPath $lr) {
        try { $snap.LastMode = [string]([System.IO.File]::ReadAllText($lr, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).mode } catch { }
    }
    return $snap
}

function New-RoundedPath {
    param([System.Drawing.RectangleF]$Rect, [single]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc(($Rect.Right - $d), $Rect.Y, $d, $d, 270, 90)
    $p.AddArc(($Rect.Right - $d), ($Rect.Bottom - $d), $d, $d, 0, 90)
    $p.AddArc($Rect.X, ($Rect.Bottom - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-StateColor {
    switch ($script:popupState) {
        'ok' { return [System.Drawing.Color]::FromArgb(58, 176, 92) }
        'running' { return [System.Drawing.Color]::FromArgb(240, 176, 32) }
        'fail' { return [System.Drawing.Color]::FromArgb(224, 62, 74) }
        default { return [System.Drawing.Color]::FromArgb(150, 146, 164) }
    }
}

function Start-PopupTimer {
    # Only repaint while a job is actually running: the clock in the status band
    # is the one thing that changes. An idle card used to redraw every second
    # for nothing.
    if ($script:popupTimer) { return }
    $script:popupTimer = New-Object System.Windows.Forms.Timer
    $script:popupTimer.Interval = 1000
    $script:popupTimer.add_Tick({
        if (-not $script:popup -or $script:popup.IsDisposed) {
            if ($script:popupTimer) { $script:popupTimer.Stop(); $script:popupTimer = $null }
            return
        }
        $st = Get-Status
        # Rescanning processes costs a WMI round trip; once every 5 s is plenty
        # for a list that changes only when a job starts or ends.
        $script:jobScanTick = [int]$script:jobScanTick + 1
        $script:jobScanTick = $script:jobScanTick % 5
        if ($script:jobScanTick -eq 0 -or $null -eq $script:jobs) {
            $script:jobs = @(Get-RunningJobs)
        }
        $liveJobs = @($script:jobs)
        $running = ($liveJobs.Count -gt 0 -or ($st -and [string]$st.state -eq 'running'))
        if ($liveJobs.Count -ne $script:popupJobCount) {
            $oldH = $script:popup.Height
            $newH = Get-PopupHeight $liveJobs.Count
            if ($newH -ne $oldH) {
                $script:popup.Height = $newH
                $script:popup.Top = $script:popup.Top - ($newH - $oldH)
            }
            $script:jobs = $liveJobs
            $script:popupJobCount = $liveJobs.Count
        }
        if ($script:autoUnpinAt -and (Get-Date) -gt $script:autoUnpinAt) { $script:autoUnpinAt = $null; $script:popupPinned = $false }
        if ($running) {
            $script:popupWasRunning = $true
            $script:popupCloseAt = $null
            $script:popup.Invalidate()
            return
        }
        if ($script:popupWasRunning) {
            $script:popupWasRunning = $false
            $script:popupCloseAt = (Get-Date).AddSeconds(4)
        }
        if ($script:popupCloseAt -and (Get-Date) -gt $script:popupCloseAt) { $script:popup.Close(); return }
        if (-not $script:popupCloseAt) { $script:popupTimer.Stop(); $script:popupTimer = $null }
    })
    $script:popupTimer.Start()
}

function Get-RunningJobs {
    # Ground truth from the OS: every live run-task process, with the mode it
    # was started in. status.json only ever describes one job, so with two
    # groups running it is not enough to tell them apart.
    $jobs = New-Object System.Collections.ArrayList
    try {
        foreach ($proc in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if (-not $proc.CommandLine) { continue }
            if ($proc.CommandLine -notlike '*run-task.ps1*') { continue }
            $m = [regex]::Match($proc.CommandLine, '-Mode\s+(\w+)')
            $modeName = 'task'
            if ($m.Success) { $modeName = $m.Groups[1].Value }
            [void]$jobs.Add([pscustomobject]@{ Mode = $modeName; Started = $proc.CreationDate; Pid = $proc.ProcessId })
        }
    } catch { }
    return @($jobs)
}

function Get-PopupHeight {
    param([int]$JobCount)
    # one band is the base layout; each extra running job adds a band
    $rows = [math]::Min($JobCount, 3)
    if ($rows -lt 1) { return 214 }
    return 214 + 38 * ($rows - 1)
}

function Get-ModeLabel {
    param([string]$Mode)
    switch ($Mode) {
        'history' { return '观看记录' }
        'fav' { return '收藏夹' }
        'follow' { return '关注分组' }
        'backup' { return '完整备份' }
        'cold' { return '冷备份' }
        default { return '' }
    }
}

function Get-ElapsedText {
    # 'mm:ss' under an hour, 'h:mm:ss' above it; empty when the stamp is unusable.
    param([string]$Started)
    if (-not $Started) { return '' }
    try {
        $t0 = [datetime]::ParseExact($Started, 'yyyy-MM-dd HH:mm:ss', $null)
        $span = (Get-Date) - $t0
        if ($span.TotalSeconds -lt 0) { return '' }
        if ($span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds) }
        return ('{0:00}:{1:00}' -f [int]$span.TotalMinutes, $span.Seconds)
    } catch { return '' }
}

function Get-ShortTime {
    param([string]$Stamp)
    if (-not $Stamp) { return '' }
    try { return ([datetime]::ParseExact($Stamp, 'yyyy-MM-dd HH:mm:ss', $null)).ToString('HH:mm') } catch { return '' }
}

function Show-DataPopup {
    param([switch]$Auto)
    # Toggle: a second double-click closes the card instead of stacking one more.
    if ($script:popup -and -not $script:popup.IsDisposed) {
        if (-not $Auto) { $script:popup.Close(); return }
        $script:popup.BringToFront()
        return
    }
    $snap = Get-ArchiveSnapshot
    $script:popupSnap = $snap
    $script:popupState = $snap.State
    $script:popupShown = Get-Date
    $script:jobs = @(Get-RunningJobs)
    $script:popupJobCount = $script:jobs.Count

    $w = 348
    $h = Get-PopupHeight $script:jobs.Count
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.Width = $w
    $f.Height = $h
    $f.BackColor = [System.Drawing.Color]::FromArgb(26, 19, 42)

    $cursor = [System.Windows.Forms.Cursor]::Position
    $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
    $x = $cursor.X - [int]($w / 2)
    if ($x -lt $area.Left + 8) { $x = $area.Left + 8 }
    if ($x + $w -gt $area.Right - 8) { $x = $area.Right - $w - 8 }
    $y = $area.Bottom - $h - 10
    $f.Left = $x
    $f.Top = $y

    $f.Add_Paint({
        param($sender, $e)
        try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $s = $script:popupSnap
        $accent = Get-StateColor
        $cardRect = New-Object System.Drawing.RectangleF 0.5, 0.5, ($sender.Width - 1.5), ($sender.Height - 1.5)
        $card = New-RoundedPath -Rect $cardRect -Radius 10
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(26, 19, 42))
        $g.FillPath($bg, $card)
        $border = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(150, $accent.R, $accent.G, $accent.B)), 1.2
        $g.DrawPath($border, $card)

        $fam = New-Object System.Drawing.FontFamily 'Microsoft YaHei UI'
        $fTitle = New-Object System.Drawing.Font $fam, 10.5, ([System.Drawing.FontStyle]::Bold)
        $fLabel = New-Object System.Drawing.Font $fam, 8.25
        $fNum = New-Object System.Drawing.Font $fam, 16.5, ([System.Drawing.FontStyle]::Bold)
        $fSmall = New-Object System.Drawing.Font $fam, 8.25
        $cTitle = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(236, 230, 248))
        $cLabel = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(158, 150, 180))
        $cNum = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(248, 241, 222))
        $cDim = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 142, 168))

        $g.DrawString(($TxtOk + ' · ' + $PopupTitle), $fTitle, $cTitle, 16, 12)

        # ---- status bands: one row per live job, so concurrent work is visible
        $st = Get-Status
        $liveState = 'unknown'
        $bands = @()
        $jobs = @($script:jobs)
        if ($jobs.Count -gt 0) {
            $liveState = 'running'
            foreach ($j in ($jobs | Select-Object -First 3)) {
                $verb = '正在采集'
                if ($j.Mode -eq 'backup' -or $j.Mode -eq 'cold') { $verb = '正在备份' }
                $jobStart = ''
                try { $jobStart = $j.Started.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
                $bands += @{
                    Color = [System.Drawing.Color]::FromArgb(240, 176, 32)
                    Title = ($verb + '：' + (Get-ModeLabel $j.Mode))
                    Right = ('已用 ' + (Get-ElapsedText $jobStart))
                }
            }
        }
        $bandTitle = $TxtUnknown
        $bandRight = ''
        $bandColor = [System.Drawing.Color]::FromArgb(150, 146, 164)
        if ($bands.Count -eq 0) {
            # nothing live: show the last finished job instead
            if ($st) {
                $modeLabel = Get-ModeLabel ([string]$st.mode)
                switch ([string]$st.state) {
                    'running' {
                        # stale: status says running but no process is left
                        $liveState = 'fail'
                        $bands += @{ Color = [System.Drawing.Color]::FromArgb(224, 62, 74); Title = '上次运行未正常结束'; Right = '' }
                    }
                    'ok' {
                        $liveState = 'ok'
                        $bTitle = '上次成功'
                        if ($modeLabel) { $bTitle = '上次成功：' + $modeLabel }
                        $bands += @{ Color = [System.Drawing.Color]::FromArgb(58, 176, 92); Title = $bTitle; Right = (Get-ShortTime ([string]$st.ended)) }
                    }
                    default {
                        $liveState = 'fail'
                        $bands += @{ Color = [System.Drawing.Color]::FromArgb(224, 62, 74); Title = $TxtFail; Right = (Get-ShortTime ([string]$st.ended)) }
                    }
                }
            } else {
                $bands += @{ Color = [System.Drawing.Color]::FromArgb(150, 146, 164); Title = $TxtUnknown; Right = '' }
            }
        }
        if ($liveState -eq 'unknown' -and $bands.Count -gt 0 -and $bands[0].Color.R -gt 200) { $liveState = 'running' }
        $script:popupState = $liveState
        $bandColor = $bands[0].Color
        $accent = $bandColor

        $bandRect = New-Object System.Drawing.RectangleF 16, 34, ($sender.Width - 32), 40
        $bandPath = New-RoundedPath -Rect $bandRect -Radius 8
        $bandFill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, $bandColor.R, $bandColor.G, $bandColor.B))
        $g.FillPath($bandFill, $bandPath)
        $bandPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(130, $bandColor.R, $bandColor.G, $bandColor.B)), 1
        $g.DrawPath($bandPen, $bandPath)
        $fBand = New-Object System.Drawing.Font $fam, 9, ([System.Drawing.FontStyle]::Bold)
        $bandIndex = 0
        $extraBands = 0
        foreach ($b in $bands) {
            $by = 34 + 38 * $bandIndex
            $rowRect = New-Object System.Drawing.RectangleF 16, $by, ($sender.Width - 32), 34
            $rowPath = New-RoundedPath -Rect $rowRect -Radius 8
            $rowFill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, $b.Color.R, $b.Color.G, $b.Color.B))
            $g.FillPath($rowFill, $rowPath)
            $rowPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(120, $b.Color.R, $b.Color.G, $b.Color.B)), 1
            $g.DrawPath($rowPen, $rowPath)
            $rowDot = New-Object System.Drawing.SolidBrush $b.Color
            $g.FillEllipse($rowDot, 29, ($by + 13), 9, 9)
            $g.DrawString($b.Title, $fBand, $cTitle, 46, ($by + 8))
            if ($b.Right) {
                $rightSize = $g.MeasureString($b.Right, $fBand)
                $g.DrawString($b.Right, $fBand, $cTitle, ($sender.Width - 16 - 14 - $rightSize.Width), ($by + 8))
            }
            $rowFill.Dispose(); $rowPen.Dispose(); $rowDot.Dispose()
            if ($bandIndex -gt 0) { $extraBands++ }
            $bandIndex++
        }
        $shift = 38 * $extraBands

        $cols = @(
            @{ X = 16; Label = '累计观看'; Value = ('{0:N0}' -f $s.Watch) },
            @{ X = 124; Label = '本月'; Value = ('{0:N0}' -f $s.WatchMonth) },
            @{ X = 232; Label = '收藏'; Value = ('{0:N0}' -f $s.Fav) }
        )
        foreach ($c in $cols) {
            $g.DrawString($c.Label, $fLabel, $cLabel, $c.X, (88 + $shift))
            $g.DrawString($c.Value, $fNum, $cNum, $c.X, (102 + $shift))
        }

        if ($s.Watch -eq 0 -and $s.Fav -eq 0) {
            $g.DrawString($PopupEmpty, $fSmall, $cDim, 16, (150 + $shift))
        } else {
            $g.DrawString(('近 7 天 {0:N0} 条 · {1} 天有活动' -f $s.Watch7, $s.ActiveDays7), $fSmall, $cLabel, 16, (150 + $shift))
            $invalidText = ('收藏失效 {0:N0}' -f $s.FavInvalid)
            $iSize = $g.MeasureString($invalidText, $fSmall)
            $g.DrawString($invalidText, $fSmall, $cLabel, ($sender.Width - 16 - $iSize.Width), (150 + $shift))
        }

        $mb = $s.Bytes / 1MB
        if ($mb -ge 1024) { $sizeText = '{0:N1} GB' -f ($mb / 1024) }
        elseif ($mb -ge 10) { $sizeText = '{0:N0} MB' -f $mb }
        elseif ($mb -ge 1) { $sizeText = '{0:N1} MB' -f $mb }
        else { $sizeText = '{0:N0} KB' -f ($s.Bytes / 1KB) }
        $g.DrawString($sizeText, $fSmall, $cDim, 16, (186 + $shift))

        # explicit close affordance: a card that just sits there with no button
        # reads as a bug even when clicking elsewhere dismisses it
        $script:popupCloseRect = New-Object System.Drawing.RectangleF (($sender.Width - 30)), 6, 22, 22
        $cClose = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 182, 205))
        $fClose = New-Object System.Drawing.Font $fam, 11, ([System.Drawing.FontStyle]::Bold)
        $g.DrawString([string][char]0x00D7, $fClose, $cClose, ($sender.Width - 27), 8)
        $cClose.Dispose(); $fClose.Dispose()

        $bg.Dispose(); $border.Dispose(); $card.Dispose()
        $cTitle.Dispose(); $cLabel.Dispose(); $cNum.Dispose(); $cDim.Dispose()
        $fTitle.Dispose(); $fLabel.Dispose(); $fNum.Dispose(); $fSmall.Dispose(); $fam.Dispose()
        $fBand.Dispose()
        } catch {
            try { Write-AppLog -Cfg $Cfg -Root $Root -Level error -Message ('popup paint failed: ' + $_.Exception.Message) } catch { }
        }
    })
    $f.Add_Deactivate({
        # Guard against closing instantly: Activate() may not win the race with
        # the hidden main form, and a 0 ms Deactivate would flash the card.
        if ($script:popupPinned) { return }
        if ($script:popup -and (((Get-Date) - $script:popupShown).TotalMilliseconds -gt 250)) { $script:popup.Close() }
    })
    $f.Add_MouseDown({
        param($sender, $e)
        # Close via $sender, never via $script:popup: FormClosed sets that to
        # $null, and a queued MouseDown after that used to kill the whole tray
        # with "cannot call a method on a null-valued expression".
        try {
            if (-not $script:popupCloseRect -or -not $e) { return }
            if (-not $script:popupCloseRect.Contains($e.X, $e.Y)) { return }
            if ($sender -and -not $sender.IsDisposed) { $sender.Close() }
            elseif ($script:popup -and -not $script:popup.IsDisposed) { $script:popup.Close() }
        } catch {
            try { Write-AppLog -Cfg $Cfg -Root $Root -Level error -Message ('popup mousedown failed: ' + $_.Exception.Message) } catch { }
        }
    })
    $f.Add_KeyDown({
        param($sender, $e)
        try {
            if (-not $e -or $e.KeyCode -ne [System.Windows.Forms.Keys]::Escape) { return }
            if ($sender -and -not $sender.IsDisposed) { $sender.Close() }
            elseif ($script:popup -and -not $script:popup.IsDisposed) { $script:popup.Close() }
        } catch {
            try { Write-AppLog -Cfg $Cfg -Root $Root -Level error -Message ('popup keydown failed: ' + $_.Exception.Message) } catch { }
        }
    })
    $f.Add_FormClosed({
        $script:popup = $null
        if ($script:popupTimer) { $script:popupTimer.Stop(); $script:popupTimer = $null }
    })
    $script:popup = $f
    $script:popupWasRunning = $null
    $script:popupCloseAt = $null
    if ($Auto) {
        # A card that closes the moment focus moves is useless when it fires by
        # itself, so hold it for a few seconds before honouring focus loss.
        $script:popupPinned = $true
        $script:autoUnpinAt = (Get-Date).AddSeconds(8)
    }
    $f.Show()
    $f.Activate()

    # Repainting only makes sense while a job runs (the clock moves); when the
    # card is opened idle there is nothing to animate.
    $stNow = Get-Status
    if ($stNow -and [string]$stNow.state -eq 'running') { Start-PopupTimer }
    if ($PreviewSeconds -gt 0) {
        # preview mode: keep the card on screen long enough to look at it
        $script:popupPinned = $true
        $script:previewTimer = New-Object System.Windows.Forms.Timer
        $script:previewTimer.Interval = ($PreviewSeconds * 1000)
        $script:previewTimer.add_Tick({
            $script:previewTimer.Stop()
            if ($script:popup -and -not $script:popup.IsDisposed) { $script:popup.Close() }
        })
        $script:previewTimer.Start()
    }
}

$miHistory.add_Click({ Invoke-Safe { Start-Run 'history' } $MenuHistory })
function Get-SoundMode {
    # Mirrors src\UiNotice.cs: soft = our own low chime, system = stock
    # MessageBox with its built-in chime, off = silent.
    # Re-read the file every time: the tray lives for days and the setting must
    # take effect without restarting it.
    try {
        $cfgFile = Join-Path $Root 'config.json'
        if (Test-Path -LiteralPath $cfgFile) {
            $text = [System.IO.File]::ReadAllText($cfgFile, [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($text, '"Sound"\s*:\s*"(soft|system|off)"')
            if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
        }
    } catch { }
    return 'soft'
}

function Play-SoftChime {
    try {
        $wav = Join-Path $Root 'assets\chime-soft.wav'
        if (Test-Path -LiteralPath $wav) {
            $player = New-Object System.Media.SoundPlayer $wav
            $player.Play()
        }
    } catch { }
}

function Show-Notice {
    param([string]$Title, [string]$Text, [string]$Kind = 'info')
    $mode = Get-SoundMode
    if ($mode -eq 'system') {
        $icon = switch ($Kind) { 'warn' { 'Warning' } 'error' { 'Error' } 'ask' { 'Question' } default { 'Information' } }
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $icon)
        return
    }
    if ($mode -eq 'soft') { Play-SoftChime }
    $prefix = switch ($Kind) { 'warn' { '注意：' } 'error' { '错误：' } 'ask' { '确认：' } default { '' } }
    [void][System.Windows.Forms.MessageBox]::Show($Text, ($prefix + $Title), 'OK', 'None')
}
function Open-SettingsGui {
    # The launcher's name is non-ASCII, so never hardcode it: a script read
    # under the ANSI code page would look for "B鍗拌薄.exe" and Start-Process
    # would throw "cannot run this command: the system cannot find the file".
    # Pick the biggest exe that is not the uninstaller (those carry a dash).
    $exe = Get-ChildItem $Root -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-*' } |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($exe) { Start-Process -FilePath $exe.FullName -ArgumentList '-settings'; return }
    Show-Notice $MenuSettings ('找不到启动器：' + (Join-Path $Root 'setup.ps1')) 'warn'
    Start-ScriptVisible 'setup.ps1'
}

function Open-HelpDoc {
    $candidates = @(
        (Join-Path $Root 'docs\能力说明.md'),
        (Join-Path $Root 'docs\README.md'),
        (Join-Path $Root 'README.md')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { Start-Process notepad.exe $c; return } }
    Start-Process explorer.exe (Join-Path $Root 'docs')
}

function Open-LatestLog {
    $latest = $null
    if (Test-Path -LiteralPath $LogDir) {
        $latest = Get-ChildItem -LiteralPath $LogDir -Filter *.log -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($latest) { Start-Process notepad.exe $latest.FullName }
    else { Show-Notice $MenuLog $NoLog 'info' }
}

function Invoke-Safe {
    # A tray menu click used to raise an unhandled CmdletInvocationException and
    # pop the .NET "JIT debugging" dialog. Swallow it, log it, tell the user.
    param([scriptblock]$Action, [string]$What)
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        Write-AppLog -Cfg $Cfg -Root $Root -Level error -Message ('tray action failed [' + $What + ']: ' + $msg)
        Show-Notice $What $msg 'error'
    }
}

$miFav.add_Click({ Invoke-Safe { Start-Run 'fav' } $MenuFav })
$miFollow.add_Click({ Invoke-Safe { Start-Run 'follow' } $MenuFollow })
$miReport.add_Click({ Invoke-Safe { Start-ScriptVisible 'report.ps1' } $MenuReport })
$miShare.add_Click({ Invoke-Safe { Start-ShareCard } $MenuShare })
$miBackup.add_Click({ Invoke-Safe { Start-Run 'backup' } $MenuBackup })
$miCold.add_Click({ Invoke-Safe { Start-Run 'cold' } $MenuCold })
$miData.add_Click({ Invoke-Safe { Show-DataPopup } $MenuData })
$miOpen.add_Click({
    Invoke-Safe {
        if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
        Start-Process explorer.exe $DataRoot
    } $MenuOpen
})
$miLog.add_Click({ Invoke-Safe { Open-LatestLog } $MenuLog })
$miHelp.add_Click({ Invoke-Safe { Open-HelpDoc } $MenuHelp })
$miSettings.add_Click({ Invoke-Safe { Open-SettingsGui } $MenuSettings })
$miUpdate.add_Click({ Invoke-Safe { Start-ScriptVisible 'check-update.ps1' } $MenuUpdate })
$miExit.add_Click({
    try { Write-AppLog -Cfg $Cfg -Root $Root -Level info -Message 'tray exit' } catch { }
    if ($script:popup -and -not $script:popup.IsDisposed) { $script:popup.Close() }
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
# Double-click now opens the data card; the log moved into the menu where it is
# a deliberate choice rather than an accident of double-clicking.
$tray.add_DoubleClick({ Invoke-Safe { Show-DataPopup } $MenuData })

function Start-Run {
    param([string]$Mode)

    # Say why a click did nothing. Two jobs at once fight over the same browser
    # profile, so the second is refused by run-task -- silently, until now.
    $st = Get-Status
    if ($st -and [string]$st.state -eq 'running') {
        $live = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine -like '*run-task.ps1*' })
        if ($live.Count -gt 0) {
            $busyLabel = Get-ModeLabel ([string]$st.mode)
            if (-not $busyLabel) { $busyLabel = '任务' }
            $wantLabel = Get-ModeLabel $Mode
            $elapsed = Get-ElapsedText ([string]$st.started)
            $head = '当前正在执行：' + $busyLabel
            if ($elapsed) { $head = $head + '（已用 ' + $elapsed + '）' }
            if ([string]$st.mode -eq $Mode) {
                $tail = '这一项已经在跑了，等它结束就好。'
            } else {
                $tail = '同时跑两个会争抢同一个浏览器配置，所以「' + $wantLabel + '」没有启动。请等它结束后再点。'
            }
            $msg = @($head, '', $tail) -join [Environment]::NewLine
            Show-Notice '任务已在运行' $msg 'warn'
            if (-not ($script:popup -and -not $script:popup.IsDisposed)) { Show-DataPopup -Auto }
            return
        }
    }

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = Join-Path $Root 'run-task.ps1'
    Write-AppLog -Cfg $Cfg -Root $Root -Level info -Message ('tray action: run-task -Mode ' + $Mode)
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runner + '"'), '-Mode', $Mode
    ) | Out-Null
    Start-Sleep -Milliseconds 800
    Update-Tray
    # Show progress immediately rather than waiting for the next poll.
    if (-not ($script:popup -and -not $script:popup.IsDisposed)) { Show-DataPopup -Auto }
}

$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 15000
$statusTimer.add_Tick({ Update-Tray })
$statusTimer.Start()

if (-not $NoAnimation) {
    $animTimer = New-Object System.Windows.Forms.Timer
    $animTimer.Interval = $FrameDelayMs
    $animTimer.add_Tick({
        if ($script:frames.Count -lt 2) { return }
        $script:frameIdx = ($script:frameIdx + 1) % $script:frames.Count
        $tray.Icon = $script:frames[$script:frameIdx]
    })
    $animTimer.Start()
}

Update-Tray

$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$form.Opacity = 0
$form.Width = 1
$form.Height = 1

# -PopupPreview: show the card immediately. Used to eyeball the layout and to
# take a screenshot without a human clicking the tray icon.
# Re-run the state check now that every function exists: a job that was
# already running when the tray started must still pop the card.
Update-Tray

if ($PopupPreview) { Show-DataPopup }
if ($MenuPreview) { $context.Show([System.Windows.Forms.Cursor]::Position) }
if ($PreviewSeconds -gt 0) {
    $script:globalPreviewTimer = New-Object System.Windows.Forms.Timer
    $script:globalPreviewTimer.Interval = ($PreviewSeconds * 1000)
    $script:globalPreviewTimer.add_Tick({ [System.Windows.Forms.Application]::Exit() })
    $script:globalPreviewTimer.Start()
}

[System.Windows.Forms.Application]::Run($form)
$statusTimer.Stop()
$tray.Visible = $false
$tray.Dispose()
