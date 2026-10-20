<#
  Generates the PlexiChore app icon (tablet + display glyph on a violet->cyan gradient tile).
  Output: src/PlexiChore.App/Assets/PlexiChore.ico (16..256 px, PNG-compressed entries) and logo-256.png.
  Usage: powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\src\PlexiChore.App\Assets'))
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Max(0.5, $r * 2)
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Render([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)
    $f = $s / 256.0
    $violet = [System.Drawing.Color]::FromArgb(255, 124, 77, 255)
    $cyan = [System.Drawing.Color]::FromArgb(255, 0, 229, 255)

    # Tile
    $tile = New-RoundRect (4*$f) (4*$f) (248*$f) (248*$f) (56*$f)
    $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new(0,0)), ([System.Drawing.PointF]::new($s,$s)), $violet, $cyan
    $g.FillPath($lg, $tile)
    # soft top highlight
    $hl = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new(0,0)), ([System.Drawing.PointF]::new(0,$s+1)), ([System.Drawing.Color]::FromArgb(60,255,255,255)), ([System.Drawing.Color]::FromArgb(0,255,255,255))
    $g.FillPath($hl, $tile)

    $white = [System.Drawing.Color]::White
    $ink = [System.Drawing.Color]::FromArgb(255, 30, 20, 70)
    $sw = [Math]::Max(1.6, 14*$f)
    # Monitor (back, upper-left)
    $mon = New-RoundRect (40*$f) (56*$f) (132*$f) (92*$f) (14*$f)
    $pen = New-Object System.Drawing.Pen $white, $sw
    $pen.LineJoin = 'Round'
    $g.DrawPath($pen, $mon)
    # Stand
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $white), [single](98*$f), [single](148*$f), [single](16*$f), [single](24*$f))
    $base = New-RoundRect (74*$f) (168*$f) (64*$f) (14*$f) (7*$f)
    $g.FillPath((New-Object System.Drawing.SolidBrush $white), $base)

    # Tablet (front, lower-right) with a gap ring so it reads as overlapping
    $gap = New-RoundRect (118*$f) (98*$f) (108*$f) (128*$f) (22*$f)
    $g.FillPath($lg, $gap)
    $tab = New-RoundRect (128*$f) (108*$f) (88*$f) (108*$f) (16*$f)
    $g.FillPath((New-Object System.Drawing.SolidBrush $white), $tab)
    # Tablet screen
    $scr = New-RoundRect (138*$f) (120*$f) (68*$f) (78*$f) (8*$f)
    $sg = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new(138*$f,120*$f)), ([System.Drawing.PointF]::new(206*$f,198*$f)), ([System.Drawing.Color]::FromArgb(255,58,34,140)), ([System.Drawing.Color]::FromArgb(255,0,120,160))
    $g.FillPath($sg, $scr)
    if ($s -ge 32) {
        # home dot
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $ink), [single](167*$f), [single](202*$f), [single](10*$f), [single](8*$f))
    }
    $g.Dispose()
    return $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
    $b = Render $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($s -eq 256) { $b.Save((Join-Path $OutDir 'logo-256.png'), [System.Drawing.Imaging.ImageFormat]::Png) }
    $b.Dispose()
    $pngs += , $ms.ToArray()
}

# Pack ICO (PNG entries are valid in ICO since Vista)
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$len); $w.Write([UInt32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'PlexiChore.ico'), $out.ToArray())
Write-Host "Wrote $(Join-Path $OutDir 'PlexiChore.ico')"

