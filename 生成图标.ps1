<#
  生成图标.ps1 —— 给「深大电量」画图标，输出 icon.ico（16/24/32/48/64/128/256）
  参考了 Codeful_Thinking 的 appicon-forge：渐变底 + 可独立设置的圆角 + 图标集合 + 文字

  用法：
    powershell -ExecutionPolicy Bypass -File 生成图标.ps1 -Preview        # 出 preview.png 看效果
    powershell -ExecutionPolicy Bypass -File 生成图标.ps1                 # 覆盖 icon.ico
    powershell -ExecutionPolicy Bypass -File 生成图标.ps1 -Preset violet -Glyph power -Label "电"
    powershell -ExecutionPolicy Bypass -File 生成图标.ps1 -Overlay logo.png   # 叠一张自己的图

  参数：
    -Style    line（线框风，浅底深线）| solid（渐变实心）
    -Preset   blue | violet | green | amber | slate     配色（solid 用）
    -Bg/-Ink  线框风的底色 / 线条色，可传 #RRGGBB
    -Glyph    bolt | power | battery | none             图形
    -Label    角标文字，如 "电"（留空则不画）
    -LabelRotate 文字旋转角度
    -Radius   四角统一的圆角百分比；也可用 -RadiusTL/-RadiusTR/-RadiusBR/-RadiusBL 单独设
    -Overlay  本地 PNG 路径，居中叠上去（替代 Glyph）
#>
param(
    [string]$Out = (Join-Path $PSScriptRoot 'icon.ico'),
    [switch]$Preview,
    [ValidateSet('line', 'solid')]
    [string]$Style = 'line',
    [ValidateSet('blue', 'violet', 'green', 'amber', 'slate')]
    [string]$Preset = 'blue',
    [string]$Bg = '',
    [string]$Ink = '',
    [ValidateSet('bolt', 'power', 'battery', 'none')]
    [string]$Glyph = 'bolt',
    [string]$Label = '',
    [double]$LabelRotate = 0,
    [double]$Radius = 23,
    [Nullable[double]]$RadiusTL = $null,
    [Nullable[double]]$RadiusTR = $null,
    [Nullable[double]]$RadiusBR = $null,
    [Nullable[double]]$RadiusBL = $null,
    [string]$Overlay = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$Presets = @{
    blue   = @{ Top = @(99, 200, 255); Bottom = @(11, 107, 203) }
    violet = @{ Top = @(162, 140, 255); Bottom = @(88, 52, 190) }
    green  = @{ Top = @(126, 231, 176); Bottom = @(14, 138, 95) }
    amber  = @{ Top = @(255, 205, 120); Bottom = @(214, 120, 20) }
    slate  = @{ Top = @(148, 163, 184); Bottom = @(51, 65, 85) }
}
$p = $Presets[$Preset]
$Top    = [System.Drawing.Color]::FromArgb(255, $p.Top[0], $p.Top[1], $p.Top[2])
$Bottom = [System.Drawing.Color]::FromArgb(255, $p.Bottom[0], $p.Bottom[1], $p.Bottom[2])

$lineBg   = if ($Bg)  { $Bg }  else { '#F4F4F5' }
$lineInk  = if ($Ink) { $Ink } else { '#2B2B30' }
$lineEdge = '#E4E4E7'

if ($null -eq $RadiusTL) { $RadiusTL = $Radius }
if ($null -eq $RadiusTR) { $RadiusTR = $Radius }
if ($null -eq $RadiusBR) { $RadiusBR = $Radius }
if ($null -eq $RadiusBL) { $RadiusBL = $Radius }

# 归一化坐标，按尺寸缩放
$Bolt = @(
    @(0.560, 0.040), @(0.215, 0.575), @(0.450, 0.575),
    @(0.380, 0.960), @(0.790, 0.410), @(0.535, 0.410)
)

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h,
    [single]$tl, [single]$tr, [single]$br, [single]$bl) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    # 顺时针：左上 → 右上 → 右下 → 左下；半径为 0 的角直接连线
    $d = 2
    if ($tl -gt 0) { $path.AddArc($x, $y, $tl * $d, $tl * $d, 180, 90) } else { $path.AddLine($x, $y, $x, $y) }
    if ($tr -gt 0) { $path.AddArc($x + $w - $tr * $d, $y, $tr * $d, $tr * $d, 270, 90) } else { $path.AddLine($x + $w, $y, $x + $w, $y) }
    if ($br -gt 0) { $path.AddArc($x + $w - $br * $d, $y + $h - $br * $d, $br * $d, $br * $d, 0, 90) } else { $path.AddLine($x + $w, $y + $h, $x + $w, $y + $h) }
    if ($bl -gt 0) { $path.AddArc($x, $y + $h - $bl * $d, $bl * $d, $bl * $d, 90, 90) } else { $path.AddLine($x, $y + $h, $x, $y + $h) }
    $path.CloseFigure()
    $path
}

function New-LineBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [single]($size * 0.03)
    $w   = [single]($size - 2 * $pad)
    $r   = [single]($w * 0.235)

    # 底板：浅灰填充 + 细边
    $bgPath = New-RoundRect $pad $pad $w $w $r $r $r $r
    $bgBrush = New-Object System.Drawing.SolidBrush((Convert-Hex $lineBg))
    $g.FillPath($bgBrush, $bgPath)
    $edgePen = New-Object System.Drawing.Pen((Convert-Hex $lineEdge), [single][math]::Max(1.0, $size * 0.012))
    $g.DrawPath($edgePen, $bgPath)
    $edgePen.Dispose()

    $stroke = [single][math]::Max(1.0, $size * 0.042)
    if ($size -le 32) { $stroke = [single][math]::Max(1.0, $size * 0.080) }
    $pen = New-Object System.Drawing.Pen((Convert-Hex $lineInk), $stroke)
    $pen.StartCap  = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap    = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin  = [System.Drawing.Drawing2D.LineJoin]::Round

    # 竖着的电池
    $bw = [single]($w * 0.40)
    $bh = [single]($w * 0.56)
    $bx = [single]($pad + ($w - $bw) / 2)
    $by = [single]($pad + ($w - $bh) / 2 + $w * 0.045)
    $br = [single]($bw * 0.13)
    $bodyPath = New-RoundRect $bx $by $bw $bh $br $br $br $br
    $g.DrawPath($pen, $bodyPath)

    # 顶部小触点
    $nubW = [single]($bw * 0.24)
    $nubH = [single]($w * 0.055)
    $nx = [single]($bx + ($bw - $nubW) / 2)
    $ny = [single]($by - $nubH - $stroke * 0.20)
    $nr = [single]($nubW * 0.35)
    if ($size -ge 24) {
        $nubPath = New-RoundRect $nx $ny $nubW $nubH $nr $nr $nr $nr
        $g.DrawPath($pen, $nubPath)
    }

    # 中间的小闪电（实心）
    $innerFactor = 0.70
    if ($size -le 32) { $innerFactor = 0.95 }
    $inner = [single]($bw * $innerFactor)
    $ox = [single]($bx + ($bw - $inner) / 2)
    $oy = [single]($by + ($bh - $inner) / 2)
    $pts = @()
    foreach ($pt in $Bolt) {
        $pts += New-Object System.Drawing.PointF([single]($ox + $pt[0] * $inner), [single]($oy + $pt[1] * $inner))
    }
    $boltPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $boltPath.AddPolygon($pts)
    $inkBrush = New-Object System.Drawing.SolidBrush((Convert-Hex $lineInk))
    $g.FillPath($inkBrush, $boltPath)

    $pen.Dispose()
    $g.Dispose()
    $bmp
}

function Convert-Hex([string]$hex) {
    [System.Drawing.ColorTranslator]::FromHtml($hex)
}
function New-IconBitmap([int]$size) {
    if ($Style -eq 'line') { return (New-LineBitmap $size) }
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    # 底板
    $pad = [single]($size * 0.04)
    $w   = [single]($size - 2 * $pad)
    $rTL = [single]($w * $RadiusTL / 100)
    $rTR = [single]($w * $RadiusTR / 100)
    $rBR = [single]($w * $RadiusBR / 100)
    $rBL = [single]($w * $RadiusBL / 100)
    $rect = New-RoundRect $pad $pad $w $w $rTL $rTR $rBR $rBL
    $ptA = New-Object System.Drawing.PointF(0, 0)
    $ptB = New-Object System.Drawing.PointF($size, $size)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($ptA, $ptB, $Top, $Bottom)
    $g.FillPath($brush, $rect)

    # 顶部高光
    # 高光铺满整块底板，靠渐变的 alpha 收边，避免中间留一条接缝
    $g.SetClip($rect)
    $glossRect = New-RoundRect $pad $pad $w $w $rTL $rTR $rBR $rBL
    $ptG1 = New-Object System.Drawing.PointF(0, 0)
    $ptG2 = New-Object System.Drawing.PointF(0, [single]($size))
    $gloss = New-Object System.Drawing.Drawing2D.LinearGradientBrush($ptG1, $ptG2, [System.Drawing.Color]::FromArgb(66, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $g.FillPath($gloss, $glossRect)
    $g.ResetClip()

    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))

    # 图形区（标签存在时上半部分画图形，下半画文字）
    $hasLabel = -not [string]::IsNullOrWhiteSpace($Label)
    $artScale = if ($hasLabel) { 0.50 } else { 0.92 }
    $artOffsetY = if ($hasLabel) { -0.17 } else { 0 }
    $k = $artScale / 0.92

    if ($Overlay -and (Test-Path $Overlay)) {
        $img = [System.Drawing.Image]::FromFile((Resolve-Path $Overlay))
        $target = [single]($w * 0.60 * $k)
        $ox = $pad + ($w - $target) / 2
        $oy = $pad + ($w - $target) / 2 + [single]($w * $artOffsetY)
        $g.DrawImage($img, $ox, $oy, $target, $target)
        $img.Dispose()
    }
    elseif ($Glyph -eq 'bolt') {
        $pts = @()
        $inner = $w * $artScale
        $offX = $pad + ($w - $inner) / 2
        $offY = $pad + ($w - $inner) / 2 + [single]($w * $artOffsetY)
        foreach ($pt in $Bolt) {
            $pts += New-Object System.Drawing.PointF([single]($offX + $pt[0] * $inner), [single]($offY + $pt[1] * $inner))
        }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddPolygon($pts)
        $g.FillPath($white, $path)
    }
    elseif ($Glyph -eq 'power') {
        $penW = [single][math]::Max(1.0, $size * 0.075 * $k)
        $pen = New-Object System.Drawing.Pen($white, $penW)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $d = [single]($w * 0.46 * $k)
        $cx = $pad + $w / 2
        $cy = $pad + $w / 2 + [single]($w * $artOffsetY)
        $g.DrawArc($pen, ($cx - $d / 2), ($cy - $d / 2), $d, $d, 300, 300)
        $g.DrawLine($pen, $cx, ($cy - $d * 0.62), $cx, ($cy - $d * 0.06))
        $pen.Dispose()
    }
    elseif ($Glyph -eq 'battery') {
        $bw = [single]($w * 0.52 * $k); $bh = [single]($w * 0.30 * $k)
        $bx = $pad + ($w - $bw) / 2
        $by = $pad + ($w - $bh) / 2 + [single]($w * $artOffsetY) - [single]($w * 0.03)
        $pen = New-Object System.Drawing.Pen($white, [single][math]::Max(1.0, $size * 0.045 * $k))
        $rr = New-RoundRect $bx $by $bw $bh ([single]($bw * 0.12)) ([single]($bw * 0.12)) ([single]($bw * 0.12)) ([single]($bw * 0.12))
        $g.DrawPath($pen, $rr)
        $g.FillRectangle($white, ($bx + $bw * 0.12), ($by + $bh * 0.22), ($bw * 0.42), ($bh * 0.56))
        $g.FillRectangle($white, ($bx + $bw + $bw * 0.03), ($by + $bh * 0.32), ($bw * 0.08), ($bh * 0.36))
        $pen.Dispose()
    }

    # 文字
    if ($hasLabel) {
        $fs = [single]($w * 0.26)
        $font = New-Object System.Drawing.Font('Microsoft YaHei UI', $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $state = $g.Save()
        $g.TranslateTransform(($pad + $w / 2), ($pad + $w * 0.78))
        if ($LabelRotate -ne 0) { $g.RotateTransform([single]$LabelRotate) }
        $g.DrawString($Label, $font, $white, 0, 0, $fmt)
        $g.Restore($state)
        $font.Dispose()
    }

    $g.Dispose()
    $bmp
}

function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
    # 小尺寸用 32bpp DIB（老格式），兼容性最好；256 才用 PNG
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $locked = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $locked.Stride
    $raw = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($locked)

    $andStride = [int]([math]::Floor(($w + 31) / 32) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40)
    $bw.Write([int32]$w)
    $bw.Write([int32]($h * 2))
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]0)
    $bw.Write([uint32]($w * $h * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $stride, $w * 4) }
    $zero = New-Object byte[] $andStride
    for ($y = 0; $y -lt $h; $y++) { $bw.Write($zero, 0, $andStride) }
    $bw.Flush()
    $ms.ToArray()
}
function Get-PngBytes([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $ms.ToArray()
}

if ($Preview) {
    $png = Join-Path $PSScriptRoot 'preview.png'
    $big = New-IconBitmap 256
    $big.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()
    Write-Output "preview -> $png"
    exit 0
}

# 拼 ICO：ICONDIR + ICONDIRENTRY * n + PNG 数据
$sizes = 16, 24, 32, 48, 64, 128, 256
$frames = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $bytes = if ($s -ge 256) { Get-PngBytes $bmp } else { Get-DibBytes $bmp }
    $frames += , @{ Size = $s; Data = $bytes }
    $bmp.Dispose()
}

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$frames.Count)

$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $bw.Write([byte]$dim)
    $bw.Write([byte]$dim)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$f.Data.Length)
    $bw.Write([uint32]$offset)
    $offset += $f.Data.Length
}
foreach ($f in $frames) { $bw.Write([byte[]]$f.Data) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Out, $ms.ToArray())
$bw.Dispose(); $ms.Dispose()

Write-Output ("icon -> {0} ({1} bytes, {2} sizes, preset={3}, glyph={4})" -f $Out, (Get-Item $Out).Length, $frames.Count, $Preset, $Glyph)










