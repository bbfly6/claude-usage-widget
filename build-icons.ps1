# 위젯 헤더의 픽셀아트 SVG path를 다양한 사이즈의 PNG + multi-res ICO로 변환
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$srcDir = Join-Path $PSScriptRoot 'src'
$orange = [System.Drawing.Color]::FromArgb(217, 119, 87)

# SVG viewBox 0 0 24 24 기준 좌표 (flat: x1,y1,x2,y2,...)
$bodyCoords = @(
    20.998, 10.949,  24, 10.949,  24, 14.051,
    21, 14.051,  21, 17.079,
    19.513, 17.079,  19.513, 20,
    18, 20,  18, 17.079,
    16.513, 17.079,  16.513, 20,
    15, 20,  15, 17.079,
    9, 17.079,  9, 20,
    7.488, 20,  7.488, 17.079,
    6, 17.079,  6, 20,
    4.487, 20,  4.487, 17.079,
    3, 17.079,  3, 14.05,
    0, 14.05,  0, 10.95,
    3, 10.95,  3, 5,
    20.998, 5,  20.998, 10.949
)
$eyeLCoords = @(6, 10.949, 7.488, 10.949, 7.488, 8.102, 6, 8.102, 6, 10.949)
$eyeRCoords = @(16.51, 10.949, 18, 10.949, 18, 8.102, 16.51, 8.102, 16.51, 10.949)

function ConvertTo-Points([double[]]$flat, [double]$scale) {
    $count = $flat.Count / 2
    $pts = New-Object 'System.Drawing.PointF[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        $x = [float]($flat[$i * 2] * $scale)
        $y = [float]($flat[$i * 2 + 1] * $scale)
        $pts[$i] = New-Object System.Drawing.PointF $x, $y
    }
    return , $pts
}

function New-PixelIcon([int]$size, [string]$outPath) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = $size / 24.0
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate

    $path.AddPolygon((ConvertTo-Points $bodyCoords $s))
    $path.AddPolygon((ConvertTo-Points $eyeLCoords $s))
    $path.AddPolygon((ConvertTo-Points $eyeRCoords $s))

    $brush = New-Object System.Drawing.SolidBrush $orange
    $g.FillPath($brush, $path)

    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "  generated: $(Split-Path $outPath -Leaf) ($size x $size)"
}

foreach ($sz in 16, 32, 48, 64, 128, 256) {
    New-PixelIcon -size $sz -outPath (Join-Path $srcDir "icon-$sz.png")
}

# Multi-resolution ICO (PNG-embedded)
$sizes = 16, 32, 48, 256
$pngData = @()
foreach ($sz in $sizes) {
    $pngData += , ([System.IO.File]::ReadAllBytes((Join-Path $srcDir "icon-$sz.png")))
}

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ms
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$dataOffset = 6 + ($sizes.Count * 16)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]
    $dim = if ($sz -ge 256) { [byte]0 } else { [byte]$sz }
    $bw.Write($dim); $bw.Write($dim)
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$pngData[$i].Length)
    $bw.Write([UInt32]$dataOffset)
    $dataOffset += $pngData[$i].Length
}
foreach ($d in $pngData) { $bw.Write($d) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $srcDir "icon.ico"), $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Write-Host ''
Write-Host '=== icon files ==='
Get-ChildItem $srcDir -Filter 'icon*' | Sort-Object Name | Format-Table Name, Length -AutoSize
