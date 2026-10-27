# Pixel-Buddy – ein kleines Desktop-Figürchen für Claude Code.
# Sitzt unten rechts, döst, wenn nichts los ist, und zeigt Berechtigungsanfragen als
# Sprechblasen, die du per Klick beantwortest. Gefüttert wird es von hook.ps1 über den
# Ordner "queue": <id>.req.json kommt rein, <id>.res.json geht als Antwort zurück.

$ErrorActionPreference = 'Stop'
$BuddyDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir   = Join-Path $env:LOCALAPPDATA 'PixelBuddy'   # Warteschlange, Log, Position
$Queue     = Join-Path $DataDir 'queue'
$StateFile = Join-Path $DataDir 'state.json'
$LogFile   = Join-Path $DataDir 'buddy.log'

function Write-Log($msg) {
    try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  [buddy] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# Nur ein Buddy gleichzeitig
$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\PixelBuddy', [ref]$created)
if (-not $created) { exit 0 }

try {
    New-Item -ItemType Directory -Force $Queue | Out-Null
    # Reste von früher wegräumen (frische Anfragen nicht anfassen)
    Get-ChildItem $Queue -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-3) } | Remove-Item -ErrorAction SilentlyContinue

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null
    [Windows.Forms.Application]::EnableVisualStyles()

    # Fenster, die immer oben liegen, ohne dir den Fokus zu stehlen
    $dll = Join-Path $DataDir ("BuddyWindow-{0}.dll" -f [Environment]::Version)
    if (-not (Test-Path $dll)) {
        $refs = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -match '^(System\.Windows\.Forms|System\.ComponentModel|System\.Drawing|System\.Runtime$|netstandard$)' -and $_.Location } |
            ForEach-Object Location
        Add-Type -OutputAssembly $dll -ReferencedAssemblies $refs -TypeDefinition @'
public class BuddyWindow : System.Windows.Forms.Form {
    public BuddyWindow() {
        FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
        StartPosition = System.Windows.Forms.FormStartPosition.Manual;
        ShowInTaskbar = false;
        DoubleBuffered = true;
        TopMost = true;
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080; // NOACTIVATE | TOPMOST | TOOLWINDOW
            return cp;
        }
    }
}
'@
    }
    Add-Type -Path $dll

    $g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $K = $g0.DpiX / 96; $g0.Dispose()
    function Sc([double]$v) { [int][Math]::Round($v * $K) }
    $PX = [Math]::Max(3, [int][Math]::Round(5 * $K))   # Größe eines Sprite-Pixels

    # ---------------------------------------------------------------- Figur
    # O Umriss, B Körper, L Glanz, D Schatten, E Augen, P Bäckchen, M Mund, S/Y Funke
    $BaseSprite = @(
        '.....S.S.S.....',
        '......SSS......',
        '.....SSYSS.....',
        '......SSS......',
        '.....S.O.S.....',
        '....OOOOOOO....',
        '...OLLBBBBBO...',
        '..OLBBBBBBBBO..',
        '..OBBBBBBBBBO..',
        '.OBBEBBBBBEBBO.',
        '.OBBEBBBBBEBBO.',
        '.OBPBBBMBBBPBO.',
        '.OBBBBBBBBBBBO.',
        '.ODBBBBBBBBBDO.',
        '..ODBBBBBBBDO..',
        '...ODDDDDDDO...',
        '...OBO...OBO...',
        '...OOO...OOO...'
    )
    function New-Frame([string]$eyes) {
        $rows = [Collections.Generic.List[char[]]]::new()
        foreach ($r in $BaseSprite) { $rows.Add($r.ToCharArray()) }
        switch ($eyes) {
            'closed' { foreach ($c in 4, 10) { $rows[9][$c] = 'B' }; foreach ($c in 3, 4, 5, 9, 10, 11) { $rows[10][$c] = 'E' } }
            'happy'  { foreach ($c in 4, 10) { $rows[10][$c] = 'B' }; foreach ($c in 3, 5, 9, 11) { $rows[10][$c] = 'E' } }
            'wide'   { foreach ($c in 4, 10) { $rows[8][$c] = 'E' }; $rows[11][6] = 'M'; $rows[11][8] = 'M' }
        }
        , $rows
    }
    $Frames = @{}
    foreach ($f in 'open', 'closed', 'happy', 'wide') { $Frames[$f] = New-Frame $f }

    function New-Brush($r, $g, $b) { [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb($r, $g, $b)) }
    $Pal = @{
        'O' = New-Brush 74 36 24;   'B' = New-Brush 217 119 87;  'L' = New-Brush 240 160 128
        'D' = New-Brush 179 90 60;  'E' = New-Brush 42 22 16;    'P' = New-Brush 244 166 160
        'M' = New-Brush 90 42 28;   'S' = New-Brush 245 165 36;  'Y' = New-Brush 255 241 184
    }
    $SparkBright = New-Brush 255 205 90
    $AlertBrush  = New-Brush 255 107 74
    $ZBrush      = New-Brush 170 176 186

    $Bang = @('XX', 'XX', 'XX', 'XX', '..', 'XX')
    $Zed  = @('XXX', '.X.', 'XXX')

    $fig = [BuddyWindow]::new()
    $fig.Text = 'Pixel-Buddy'
    $fig.BackColor = [Drawing.Color]::Magenta
    $fig.TransparencyKey = [Drawing.Color]::Magenta
    $fig.Size = [Drawing.Size]::new(23 * $PX, 25 * $PX)

    $script:look = @{ eyes = 'open'; bob = 0; bright = $false; indicator = ''; zphase = 0 }

    function Draw-Pixels($g, $rows, [int]$ox, [int]$oy, [int]$size, $brush) {
        for ($y = 0; $y -lt $rows.Count; $y++) {
            $row = [string]$rows[$y]
            for ($x = 0; $x -lt $row.Length; $x++) {
                if ($row[$x] -ne '.') { $g.FillRectangle($brush, $ox + $x * $size, $oy + $y * $size, $size, $size) }
            }
        }
    }

    $fig.Add_Paint({ param($s, $e)
        $g = $e.Graphics
        $L = $script:look
        $rows = $Frames[$L.eyes]
        $ox = 4 * $PX; $oy = (7 - $L.bob) * $PX
        for ($y = 0; $y -lt $rows.Count; $y++) {
            $row = $rows[$y]
            for ($x = 0; $x -lt $row.Length; $x++) {
                $c = [string]$row[$x]
                if ($c -eq '.') { continue }
                $brush = if ($c -eq 'S' -and $L.bright) { $SparkBright } else { $Pal[$c] }
                $g.FillRectangle($brush, $ox + $x * $PX, $oy + $y * $PX, $PX, $PX)
            }
        }
        if ($L.indicator -eq '!') {
            Draw-Pixels $g $Bang (18 * $PX) ((1 - $L.bob) * $PX) $PX $AlertBrush
        } elseif ($L.indicator -eq 'z') {
            $small = [Math]::Max(2, [int]($PX * 0.6))
            if ($L.zphase -ge 1) { Draw-Pixels $g $Zed (17 * $PX) (4 * $PX) $small $ZBrush }
            if ($L.zphase -ge 2) { Draw-Pixels $g $Zed (19 * $PX) (1 * $PX) $PX $ZBrush }
        }
    })

    # ---------------------------------------------------------------- Sprechblasen
    $Col = @{
        Bubble = [Drawing.Color]::FromArgb(43, 45, 49);   Border = [Drawing.Color]::FromArgb(118, 121, 128)
        Text   = [Drawing.Color]::FromArgb(242, 242, 242); Muted  = [Drawing.Color]::FromArgb(165, 168, 175)
        Code   = [Drawing.Color]::FromArgb(28, 29, 32)
        Allow  = [Drawing.Color]::FromArgb(46, 140, 87);   Always = [Drawing.Color]::FromArgb(40, 98, 160)
        Deny   = [Drawing.Color]::FromArgb(176, 58, 58)
    }
    $BorderPen = [Drawing.Pen]::new($Col.Border, [float][Math]::Max(1, $K * 1.5))
    $BubbleW = Sc 330

    function New-RoundPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
        $p = [Drawing.Drawing2D.GraphicsPath]::new()
        $d = $r * 2
        $p.AddArc($x, $y, $d, $d, 180, 90)
        $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
        $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
        $p.CloseFigure()
        $p
    }

    function New-Bubble([int]$h) {
        $b = [BuddyWindow]::new()
        $b.BackColor = $Col.Bubble
        $b.ForeColor = $Col.Text
        $b.Font = [Drawing.Font]::new('Segoe UI', 9)
        $b.Size = [Drawing.Size]::new($BubbleW, $h)
        $b.Region = [Drawing.Region]::new((New-RoundPath 0 0 $BubbleW $h (Sc 16)))
        $b.Add_Paint({ param($s, $e)
            $e.Graphics.SmoothingMode = 'AntiAlias'
            $e.Graphics.DrawPath($BorderPen, (New-RoundPath 1 1 ($s.Width - 2.5) ($s.Height - 2.5) (Sc 15)))
        })
        $b
    }

    function New-Label($parent, $text, $x, $y, $w, $h, $font, $color) {
        $l = [Windows.Forms.Label]::new()
        $l.Text = $text
        $l.Font = $font
        $l.ForeColor = $color
        $l.BackColor = $parent.BackColor
        $l.AutoEllipsis = $true
        $l.Location = [Drawing.Point]::new($x, $y)
        $l.Size = [Drawing.Size]::new($w, $h)
        $parent.Controls.Add($l)
        $l
    }

    function New-Btn($parent, $text, $x, $y, $w, $h, $color, $id, $choice) {
        $btn = [Windows.Forms.Button]::new()
        $btn.Text = $text
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $btn.FlatAppearance.MouseOverBackColor = [Windows.Forms.ControlPaint]::Light($color, 0.25)
        $btn.BackColor = $color
        $btn.ForeColor = [Drawing.Color]::White
        $btn.Font = [Drawing.Font]::new('Segoe UI Semibold', 9.5)
        $btn.Cursor = 'Hand'
        $btn.TabStop = $false
        $btn.Location = [Drawing.Point]::new($x, $y)
        $btn.Size = [Drawing.Size]::new($w, $h)
        $btn.Region = [Drawing.Region]::new((New-RoundPath 0 0 $w $h (Sc 8)))
        $btn.Tag = @{ id = $id; choice = $choice }
        $btn.Add_Click({ param($s, $e) try { Send-Answer $s.Tag.id $s.Tag.choice } catch { Write-Log "Klick: $_" } })
        $parent.Controls.Add($btn)
    }

    $script:Bubbles = [ordered]@{}
    $script:Handled = @{}

    function Add-PermissionBubble($req, [datetime]$since) {
        $id = [string]$req.id
        $pad = Sc 14; $inner = $BubbleW - 2 * $pad
        $b = New-Bubble (Sc 196)
        New-Label $b $req.title $pad (Sc 10) $inner (Sc 22) ([Drawing.Font]::new('Segoe UI Semibold', 10.5)) $Col.Text | Out-Null
        New-Label $b $req.subtitle $pad (Sc 32) $inner (Sc 18) $b.Font $Col.Muted | Out-Null

        $panel = [Windows.Forms.Panel]::new()
        $panel.BackColor = $Col.Code
        $panel.Location = [Drawing.Point]::new($pad, (Sc 56))
        $panel.Size = [Drawing.Size]::new($inner, (Sc 66))
        $box = [Windows.Forms.TextBox]::new()
        $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'
        $box.BorderStyle = 'None'; $box.TabStop = $false
        $box.BackColor = $Col.Code; $box.ForeColor = $Col.Text
        $box.Font = [Drawing.Font]::new('Consolas', 9)
        $box.Location = [Drawing.Point]::new((Sc 8), (Sc 6))
        $box.Size = [Drawing.Size]::new($inner - (Sc 10), (Sc 56))
        $box.Text = [string]$req.detail
        $panel.Controls.Add($box)
        $b.Controls.Add($panel)

        $gap = Sc 8; $by = Sc 132; $bh = Sc 32
        if ($req.canAlways) {
            $w = [int](($inner - 2 * $gap) / 3)
            New-Btn $b 'Erlauben' $pad $by $w $bh $Col.Allow $id 'allow'
            New-Btn $b 'Immer' ($pad + $w + $gap) $by $w $bh $Col.Always $id 'always'
            New-Btn $b 'Nein' ($pad + 2 * ($w + $gap)) $by ($inner - 2 * ($w + $gap)) $bh $Col.Deny $id 'deny'
        } else {
            $w = [int](($inner - $gap) / 2)
            New-Btn $b 'Erlauben' $pad $by $w $bh $Col.Allow $id 'allow'
            New-Btn $b 'Nein' ($pad + $w + $gap) $by ($inner - $w - $gap) $bh $Col.Deny $id 'deny'
        }

        $link = [Windows.Forms.LinkLabel]::new()
        $link.Text = 'Im Chat entscheiden'
        $link.Font = [Drawing.Font]::new('Segoe UI', 8.5)
        $link.LinkColor = $Col.Muted; $link.ActiveLinkColor = $Col.Text
        $link.LinkBehavior = 'HoverUnderline'
        $link.BackColor = $b.BackColor
        $link.AutoSize = $true
        $link.Location = [Drawing.Point]::new($pad, (Sc 172))
        $link.Tag = $id
        $link.Add_LinkClicked({ param($s, $e) try { Send-Answer $s.Tag 'chat' } catch { Write-Log "Klick: $_" } })
        $b.Controls.Add($link)

        $count = New-Label $b '' ($pad + (Sc 150)) (Sc 172) ($inner - (Sc 150)) (Sc 18) $link.Font $Col.Muted
        $count.TextAlign = 'TopRight'

        $timeout = if ($req.timeout) { [int]$req.timeout } else { 120 }
        $script:Bubbles[$id] = @{ Id = $id; Kind = 'permission'; Form = $b; Countdown = $count; Deadline = $since.AddSeconds($timeout) }
        Update-Layout
        $b.Show()
        [Media.SystemSounds]::Asterisk.Play()
    }

    function Add-NotifyBubble([string]$id, [string]$title, [string]$text, [int]$seconds) {
        $pad = Sc 14
        $b = New-Bubble (Sc 58)
        $t = New-Label $b $title $pad (Sc 9) ($BubbleW - 2 * $pad) (Sc 22) ([Drawing.Font]::new('Segoe UI Semibold', 10.5)) $Col.Text
        $u = New-Label $b $text $pad (Sc 30) ($BubbleW - 2 * $pad) (Sc 18) $b.Font $Col.Muted
        foreach ($c in @($b, $t, $u)) {
            $c.Cursor = 'Hand'
            $c.Tag = $id
            $c.Add_Click({ param($s, $e) try { Close-Bubble $s.Tag } catch {} })
        }
        $script:Bubbles[$id] = @{ Id = $id; Kind = 'notify'; Form = $b; Deadline = (Get-Date).AddSeconds($seconds) }
        Update-Layout
        $b.Show()
        Set-Mood 'happy' 3
    }

    function Close-Bubble([string]$id) {
        if (-not $script:Bubbles.Contains($id)) { return }
        $f = $script:Bubbles[$id].Form
        $script:Bubbles.Remove($id)
        $script:Handled[$id] = Get-Date
        $f.Close(); $f.Dispose()
        Remove-Item (Join-Path $Queue "$id.req.json") -ErrorAction SilentlyContinue
        Update-Layout
    }

    function Send-Answer([string]$id, [string]$choice) {
        $tmp = Join-Path $Queue "$id.restmp"
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json @{ choice = $choice } -Compress))
        Move-Item -Force $tmp (Join-Path $Queue "$id.res.json")
        $script:Handled[$id] = Get-Date
        if ($script:Bubbles.Contains($id)) {
            $f = $script:Bubbles[$id].Form
            $script:Bubbles.Remove($id)
            $f.Close(); $f.Dispose()
            Update-Layout
        }
        if ($choice -in 'allow', 'always') { Set-Mood 'happy' 2 }
    }

    function Update-Layout {
        $wa = [Windows.Forms.Screen]::FromControl($fig).WorkingArea
        $cx = $fig.Left + [int](11.5 * $PX)
        $y = $fig.Top + 2 * $PX
        foreach ($b in @($script:Bubbles.Values)) {
            $f = $b.Form
            $y -= $f.Height
            $x = [Math]::Min([Math]::Max($cx - [int]($f.Width / 2), $wa.Left + (Sc 8)), $wa.Right - $f.Width - (Sc 8))
            $f.Location = [Drawing.Point]::new($x, $y)
            $y -= Sc 8
        }
    }

    # ---------------------------------------------------------------- Stimmung & Animation
    $script:tick = 0
    $script:mood = 'idle'
    $script:moodUntil = Get-Date
    $script:lastActive = Get-Date
    $script:lastLook = ''

    function Set-Mood([string]$m, [double]$sec) {
        $script:mood = $m
        $script:moodUntil = (Get-Date).AddSeconds($sec)
        $script:lastActive = Get-Date
    }

    function Update-Figure {
        $now = Get-Date
        $t = $script:tick
        $L = $script:look
        $waiting = @($script:Bubbles.Values | Where-Object { $_.Kind -eq 'permission' }).Count -gt 0
        $L.indicator = ''; $L.bright = $false
        if ($waiting) {
            $script:lastActive = $now
            $L.eyes = 'wide'; $L.bright = ($t % 2 -eq 0); $L.indicator = '!'
            $every = 2
        } elseif ($script:mood -eq 'happy' -and $now -lt $script:moodUntil) {
            $L.eyes = 'happy'; $every = 1
        } elseif (($now - $script:lastActive).TotalSeconds -gt 60) {
            $L.eyes = 'closed'; $L.indicator = 'z'; $L.zphase = [int][Math]::Floor($t / 4) % 3
            $every = 8
        } else {
            $L.eyes = if ($t % 20 -eq 0) { 'closed' } else { 'open' }
            $every = 4
        }
        $L.bob = [int]([Math]::Floor($t / $every) % 2)
        $sig = "$($L.eyes)|$($L.bob)|$($L.bright)|$($L.indicator)|$($L.zphase)"
        if ($sig -ne $script:lastLook) { $script:lastLook = $sig; $fig.Invalidate() }
    }

    function Sync-Queue {
        $now = Get-Date
        foreach ($file in Get-ChildItem $Queue -Filter '*.req.json' -File) {
            $id = $file.Name -replace '\.req\.json$', ''
            if ($script:Bubbles.Contains($id) -or $script:Handled.ContainsKey($id)) { continue }
            try { $req = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $req | Add-Member -Force -NotePropertyName id -NotePropertyValue $id
            if ($req.kind -eq 'permission') { Add-PermissionBubble $req $file.LastWriteTime }
            else { Add-NotifyBubble $id ([string]$req.title) ([string]$req.subtitle) 8 }
        }
        foreach ($b in @($script:Bubbles.Values)) {
            if ($b.Kind -eq 'permission') {
                $left = ($b.Deadline - $now).TotalSeconds
                if (-not (Test-Path (Join-Path $Queue "$($b.Id).req.json")) -or $left -lt -5) { Close-Bubble $b.Id }
                else { $b.Countdown.Text = 'noch {0} s' -f [Math]::Max(0, [int]$left) }
            } elseif ($now -gt $b.Deadline) {
                Close-Bubble $b.Id
            }
        }
        if ($script:tick % 240 -eq 0) {
            foreach ($k in @($script:Handled.Keys)) { if (($now - $script:Handled[$k]).TotalMinutes -gt 10) { $script:Handled.Remove($k) } }
            Get-ChildItem $Queue -File | Where-Object { $_.LastWriteTime -lt $now.AddMinutes(-5) } | Remove-Item -ErrorAction SilentlyContinue
        }
    }

    # ---------------------------------------------------------------- Position & Bedienung
    function Get-HomePosition {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        [Drawing.Point]::new($wa.Right - $fig.Width - (Sc 24), $wa.Bottom - $fig.Height)
    }
    function Save-State {
        try { ConvertTo-Json @{ x = $fig.Left; y = $fig.Top } | Set-Content $StateFile -Encoding UTF8 } catch {}
    }
    $pos = Get-HomePosition
    try {
        $st = Get-Content $StateFile -Raw | ConvertFrom-Json
        $p = [Drawing.Point]::new([int]$st.x, [int]$st.y)
        $center = [Drawing.Point]::new($p.X + [int]($fig.Width / 2), $p.Y + [int]($fig.Height / 2))
        if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($center) }) { $pos = $p }
    } catch {}
    $fig.Location = $pos

    $script:drag = $null
    $fig.Add_MouseDown({ param($s, $e)
        if ($e.Button -eq 'Left') { $script:drag = @{ start = [Windows.Forms.Cursor]::Position; from = $fig.Location; moved = $false } }
    })
    $fig.Add_MouseMove({ param($s, $e)
        $d = $script:drag
        if ($d -and $e.Button -eq 'Left') {
            $p = [Windows.Forms.Cursor]::Position
            $dx = $p.X - $d.start.X; $dy = $p.Y - $d.start.Y
            if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 3) { $d.moved = $true }
            if ($d.moved) { $fig.Location = [Drawing.Point]::new($d.from.X + $dx, $d.from.Y + $dy); Update-Layout }
        }
    })
    $fig.Add_MouseUp({ param($s, $e)
        if ($e.Button -eq 'Left' -and $script:drag) {
            if ($script:drag.moved) { Save-State } else { Set-Mood 'happy' 1.5 }
            $script:drag = $null
        }
    })

    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $null = $menu.Items.Add('Zurück in die Ecke', $null, { $fig.Location = Get-HomePosition; Save-State; Update-Layout })
    $null = $menu.Items.Add('Buddy beenden', $null, { [Windows.Forms.Application]::Exit() })
    $fig.ContextMenuStrip = $menu

    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 250
    $timer.Add_Tick({
        try { $script:tick++; Sync-Queue; Update-Figure } catch { Write-Log "Tick: $_" }
    })
    $fig.Add_Shown({
        Update-Figure
        Add-NotifyBubble 'hello' 'Hi, ich bin dein Pixel-Buddy!' 'Ich sag Bescheid, wenn Claude was fragt.' 6
        $timer.Start()
    })

    Write-Log 'gestartet'
    [Windows.Forms.Application]::Run($fig)
    $timer.Stop()
    Write-Log 'beendet'
} catch {
    Write-Log "FEHLER: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
