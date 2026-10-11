# Draws the power-symbol icon: pc\assets\app.ico (16..256) and the iOS 1024px AppIcon.
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

function Draw([int]$s, [bool]$fullBleed) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object System.Drawing.RectangleF 0, 0, $s, $s
    $top = [System.Drawing.Color]::FromArgb(52, 211, 153); $bottom = [System.Drawing.Color]::FromArgb(5, 150, 105)
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $top, $bottom, 90
    if ($fullBleed) { $g.FillRectangle($bg, $rect) }  # iOS masks the corners itself
    else { $g.FillEllipse($bg, 0.5, 0.5, $s - 1, $s - 1) }
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([Math]::Max(1.6, 0.085 * $s))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $c = $s / 2.0; $r = 0.25 * $s
    $g.DrawArc($pen, $c - $r, $c - $r + 0.02 * $s, 2 * $r, 2 * $r, 300, 300)
    $g.DrawLine($pen, $c, $c - 1.2 * $r, $c, $c - 0.2 * $r)
    $g.Dispose()
    $bmp
}

function Png($bmp) { $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }

[System.IO.File]::WriteAllBytes((Join-Path $root 'ios\Assets.xcassets\AppIcon.appiconset\icon-1024.png'), (Png (Draw 1024 $true)))

$sizes = 16, 24, 32, 48, 64, 256
$frames = foreach ($s in $sizes) { , (Png (Draw $s $false)) }
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$frames[$i].Length); $bw.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $bw.Write($f) }
[System.IO.File]::WriteAllBytes((Join-Path $root 'pc\assets\app.ico'), $out.ToArray())
