<#
  深大宿舍电量查询 —— 可分发版（带常驻热键）
  · 首次运行弹设置向导（主题 / 校区 / 楼栋 / 房间号 / 快捷键）
  · 卡片右上角齿轮随时改设置
  · -Agent 常驻：注册全局热键 + 托盘图标 + 后台预取，按热键几乎秒开

  数据源：SIMS 电控网上查询系统 http://192.168.84.3:9090/cgcSims/（需校内网）

  用法：
    szu-power.ps1            打开卡片（有常驻进程时由它代劳，最快）
    szu-power.ps1 -Setup     打开设置向导
    szu-power.ps1 -Install   建快捷方式 + 开机自启 + 打开设置向导
    szu-power.ps1 -Agent     常驻（热键/托盘），一般由开机自启调用
    szu-power.ps1 -Fetch     只刷新缓存数据后退出（内部用）
    szu-power.ps1 -Console   命令行输出（调试用）
#>
param(
    [switch]$Install,
    [switch]$Setup,
    [switch]$Console,
    [switch]$Agent,
    [switch]$Fetch
)

$ErrorActionPreference = 'Stop'

$Script:Root    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:Base    = 'http://192.168.84.3:9090/cgcSims'
$Script:DataDir = Join-Path $env:LOCALAPPDATA 'szu-power'
$Script:CfgFile = Join-Path $Script:DataDir 'config.json'
$Script:CacheFile = Join-Path $Script:DataDir 'cache.json'
$Script:FlagFile  = Join-Path $Script:DataDir 'show.flag'
$Script:LogFile = Join-Path $Script:DataDir 'history.csv'
$Script:Icon    = Join-Path $Script:Root 'icon.ico'
$Script:MutexName = 'Local\szu-power-agent'
$Script:Gbk     = [System.Text.Encoding]::GetEncoding(936)
$Script:Inv     = [System.Globalization.CultureInfo]::InvariantCulture

$Script:Campuses = @(
    @{ Name = '北校区';     Client = '192.168.84.1'   }
    @{ Name = '南校区';     Client = '192.168.84.110' }
    @{ Name = '西丽校区';   Client = '172.21.101.11'  }
    @{ Name = '深大新斋区'; Client = '192.168.84.87'  }
)

function SzuLog([string]$m) {
    if (-not $env:SZU_DEBUG) { return }
    try { Add-Content (Join-Path $env:TEMP 'szu-log.txt') ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8 } catch { }
}

function Brush([string]$hex) {
    if (-not $hex) { return $null }
    (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
}

# ============================ 配色 ============================

function Get-EffectiveTheme([string]$theme) {
    if ($theme -ne 'auto') { return $theme }
    $light = $true
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        $light = ($v -eq 1)
    } catch { }
    if ($light) { 'light' } else { 'dark' }
}

function Get-Palette([string]$theme) {
    if ((Get-EffectiveTheme $theme) -eq 'light') {
        return @{
            CardBg = '#FFFFFFFF'; Border = '#22000000'; Shadow = 0.16
            Title = '#E4000000';  Sub = '#8A000000'
            ChipBg = '#0C000000'; ChipFg = '#66000000'
            Accent = '#FF0F6CBD'; Grid = '#12000000'; Axis = '#66000000'
            Date = '#66000000';   Value = '#CC000000'
            Area = '#1F0F6CBD';   DotIn = '#FFFFFFFF'; IconBg = '#1A0F6CBD'
            InBg = '#FFF7F7F7';   InBorder = '#22000000'; InFg = '#E4000000'
            BtnBg = '#FF0F6CBD';  BtnFg = '#FFFFFFFF';     GhostFg = '#66000000'
            Err = '#FFC42B1C'
            PillBg = '#0D000000'; PillFg = '#8A000000'; PillHover = '#14000000'
            PillSel = '#1A0F6CBD'; PillSelBorder = '#800F6CBD'; PillSelFg = '#FF0F6CBD'
            BtnHover = '#FF115EA8'
        }
    }
    return @{
        CardBg = '#F52B2B2B'; Border = '#26FFFFFF'; Shadow = 0.60
        Title = '#FFFFFFFF';  Sub = '#8CFFFFFF'
        ChipBg = '#0CFFFFFF'; ChipFg = '#5CFFFFFF'
        Accent = '#FF4CC2FF'; Grid = '#18FFFFFF'; Axis = '#5AFFFFFF'
        Date = '#66FFFFFF';   Value = '#CCFFFFFF'
        Area = '#1E4CC2FF';   DotIn = '#FF1E1E1E'; IconBg = '#264CC2FF'
        InBg = '#14FFFFFF';   InBorder = '#33FFFFFF'; InFg = '#FFFFFFFF'
        BtnBg = '#FF4CC2FF';  BtnFg = '#FF101010';     GhostFg = '#B0FFFFFF'
        Err = '#FFFF6B6B'
        PillBg = '#1AFFFFFF'; PillFg = '#B0FFFFFF'; PillHover = '#2EFFFFFF'
        PillSel = '#2E4CC2FF'; PillSelBorder = '#804CC2FF'; PillSelFg = '#FFFFFFFF'
        BtnHover = '#FF6FD0FF'
    }
}

# ============================ 电控系统接口 ============================

function Get-GbkPercent([string]$s) {
    ($Script:Gbk.GetBytes($s) | ForEach-Object { '%{0:X2}' -f $_ }) -join ''
}

function Invoke-Sims([string]$Path, [string]$Body) {
    $url = $Script:Base + $Path
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout          = 20000
    $req.ReadWriteTimeout = 20000
    $req.UserAgent        = 'Mozilla/5.0'
    $req.Referer          = $Script:Base + '/login.do'
    if ($Body) {
        $req.Method        = 'POST'
        $req.ContentType   = 'application/x-www-form-urlencoded'
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream()
        $st.Write($bytes, 0, $bytes.Length)
        $st.Close()
    }
    $resp = $req.GetResponse()
    $ms = New-Object System.IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $resp.Close()
    $Script:Gbk.GetString($ms.ToArray())
}

function Get-Buildings([string]$client) {
    $html = Invoke-Sims ('/login.do?task=station&client=' + $client) $null
    $list = @()
    foreach ($m in [regex]::Matches($html, '<option value="(\d+)">([^<]+)</option>')) {
        $name = $m.Groups[2].Value.Trim()
        if ($name) { $list += [pscustomobject]@{ Id = $m.Groups[1].Value; Name = $name } }
    }
    $list
}

function Resolve-RoomId([string]$client, [string]$building, [string]$room) {
    $bid = $null
    foreach ($b in (Get-Buildings $client)) {
        if ($b.Name -eq $building) { $bid = $b.Id }
    }
    if (-not $bid) { throw ("电控系统里没有楼栋「{0}」" -f $building) }
    $body = 'client={0}&buildingId={1}&buildingName={2}&roomName={3}&select=%20%B2%E9%D1%AF%20' -f `
        $client, $bid, (Get-GbkPercent $building), (Get-GbkPercent $room)
    $html = Invoke-Sims '/login.do' $body
    $m = [regex]::Match($html, 'name="roomId"\s+value="(\d+)"')
    if (-not $m.Success) { throw ("房间「{0}」没查到，确认是 {1} 里的三位房间号" -f $room, $building) }
    $m.Groups[1].Value
}

# ============================ 配置 / 缓存 ============================

function Read-Config {
    if (-not (Test-Path $Script:CfgFile)) { return $null }
    try {
        $o = Get-Content $Script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $o.client -or -not $o.building -or -not $o.room) { return $null }
        @{
            theme       = if ($o.theme) { [string]$o.theme } else { 'dark' }
            campus      = [string]$o.campus
            client      = [string]$o.client
            building    = [string]$o.building
            room        = [string]$o.room
            roomId      = if ($o.roomId) { [string]$o.roomId } else { '' }
            hotkey      = if ($null -ne $o.hotkey) { [string]$o.hotkey } else { 'CTRL + ALT + E' }
            holdSeconds = if ($o.holdSeconds) { [int]$o.holdSeconds } else { 20 }
        }
    } catch { $null }
}

function Save-Config($cfg) {
    if (-not (Test-Path $Script:DataDir)) { New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null }
    ($cfg | ConvertTo-Json) | Set-Content -Path $Script:CfgFile -Encoding UTF8
}

function Save-Cache($data) {
    try {
        if (-not (Test-Path $Script:DataDir)) { New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null }
        $o = [pscustomobject]@{
            ts       = (Get-Date).ToString('s')
            remain   = $data.Last.Remain
            used     = $data.Last.Used
            bought   = $data.Last.Bought
            date     = $data.Last.Date
            dayUse   = $data.DayUse
            recharge = $data.Recharge
            avg      = $data.Avg
            series   = @($data.Series | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Value = $_.Value } })
        }
        ($o | ConvertTo-Json -Depth 5) | Set-Content -Path $Script:CacheFile -Encoding UTF8
    } catch { }
}

function Read-Cache {
    if (-not (Test-Path $Script:CacheFile)) { return $null }
    try {
        $o = Get-Content $Script:CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $lt = [pscustomobject]@{ Remain = [double]$o.remain; Used = [double]$o.used; Bought = [double]$o.bought; Date = [string]$o.date }
        $series = @()
        foreach ($s in @($o.series)) { $series += [pscustomobject]@{ Label = [string]$s.Label; Value = [double]$s.Value } }
        [pscustomobject]@{
            Last = $lt; Series = $series
            DayUse = $o.dayUse; Recharge = $o.recharge; Avg = $o.avg; FetchedAt = $o.ts
        }
    } catch { $null }
}

function Test-AgentRunning {
    $m = $null
    try { $m = [System.Threading.Mutex]::OpenExisting($Script:MutexName); $m.Dispose(); $true } catch { $false }
}

# ============================ 快捷方式 ============================

function New-Shortcut([string]$Path, [string]$Args, [string]$Desc) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($Path)
    $s.TargetPath       = "$env:SystemRoot\System32\wscript.exe"
    $s.Arguments        = $Args
    $s.WorkingDirectory = $Script:Root
    $s.IconLocation     = $Script:Icon
    $s.Description      = $Desc
    $s.WindowStyle      = 1
    $s.Save()
}

function Get-VbsPath { Join-Path $Script:Root 'szu-power.vbs' }

function New-DesktopShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'
    New-Shortcut $lnk ('"' + (Get-VbsPath) + '"') '查宿舍剩余电量'
    $lnk
}

function Set-ShortcutHotkey([string]$hk) {
    if (-not $hk) { return }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'
    if (-not (Test-Path $lnk)) { return }
    try {
        $norm = ($hk -replace '\s*\+\s*', '+').ToUpper()
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $s.Hotkey = $norm
        $s.Save()
    } catch { SzuLog ('hotkey ERR: ' + $_.Exception.Message) }
}

function Update-Autostart($cfg) {
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) '深大电量热键.lnk'
    $hasKey = [bool]$cfg.hotkey
    # 热键交给常驻进程处理，快捷方式热键就不再需要（避免双触发）
    $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'
    if (Test-Path $deskLnk) {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut($deskLnk); $s.Hotkey = ''; $s.Save()
        } catch { }
    }
    if ($hasKey) {
        New-Shortcut $startup ('"' + (Get-VbsPath) + '" -Agent') '深大电量热键常驻'
        if (-not (Test-AgentRunning)) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Get-VbsPath) + '" -Agent') -WindowStyle Hidden
        }
    } else {
        if (Test-Path $startup) { Remove-Item $startup -Force -ErrorAction SilentlyContinue }
    }
}

# ============================ 数据 ============================

function Get-PowerData($cfg) {
    $roomId = $cfg.roomId
    if (-not $roomId) {
        $roomId = Resolve-RoomId $cfg.client $cfg.building $cfg.room
    }
    $today = (Get-Date).Date
    $begin = $today.AddDays(-7).ToString('yyyy-MM-dd')
    $end   = $today.ToString('yyyy-MM-dd')
    $body  = 'hiddenType=&isHost=&beginTime={0}&endTime={1}&type=2&client={2}&roomId={3}&roomName={4}&building=' -f `
        $begin, $end, $cfg.client, $roomId, (Get-GbkPercent $cfg.room)
    $html = Invoke-Sims '/selectList.do' $body

    $rowRx = [regex]'(?s)<tr[^>]*>\s*<td width="13%"[^>]*>\s*(\d+)\s*</td>\s*<td width="13%"[^>]*>\s*([^<]*?)\s*</td>\s*<td width="13%"[^>]*>\s*([\d.]+)\s*</td>\s*<td width="13%"[^>]*>\s*([\d.]+)\s*</td>\s*<td width="13%"[^>]*>\s*([\d.]+)\s*</td>\s*<td width="22%"[^>]*>\s*(\d{4}-\d{2}-\d{2})'
    $rows = @()
    foreach ($m in $rowRx.Matches($html)) {
        $rows += [pscustomobject]@{
            Remain = [double]$m.Groups[3].Value
            Used   = [double]$m.Groups[4].Value
            Bought = [double]$m.Groups[5].Value
            Date   = $m.Groups[6].Value
        }
    }
    $rows = @($rows | Sort-Object Date)
    if (-not $rows.Count) {
        if ($cfg.roomId) {
            # 缓存的 roomId 可能失效，重新解析一次再查
            $cfg.roomId = ''
            return Get-PowerData $cfg
        }
        throw ("房间 {0} 查到了，但没有用电数据（系统还没更新，或房间号不对）" -f $cfg.room)
    }

    $last = $rows[-1]
    $prev = if ($rows.Count -ge 2) { $rows[-2] } else { $null }
    $series = @()
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $d = [math]::Round($rows[$i].Used - $rows[$i - 1].Used, 2)
        $series += [pscustomobject]@{ Label = $rows[$i].Date.Substring(5); Value = [math]::Max($d, 0) }
    }
    $series = @($series | Select-Object -Last 5)

    [pscustomobject]@{
        Last     = $last
        Prev     = $prev
        Series   = $series
        DayUse   = if ($prev) { [math]::Round($last.Used - $prev.Used, 2) } else { $null }
        Recharge = if ($prev) { [math]::Round($last.Bought - $prev.Bought, 2) } else { 0 }
        Avg      = if ($series.Count) { [math]::Round((($series | Measure-Object Value -Average).Average), 2) } else { 0 }
        RoomId   = $roomId
    }
}

function Write-History($data) {
    try {
        if (-not (Test-Path $Script:DataDir)) { New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null }
        if (-not (Test-Path $Script:LogFile)) {
            'query_time,data_date,remain,used_total,bought_total' | Set-Content -Path $Script:LogFile -Encoding UTF8
        }
        ('{0},{1},{2},{3},{4}' -f (Get-Date).ToString('s'), $data.Last.Date, $data.Last.Remain, $data.Last.Used, $data.Last.Bought) |
            Add-Content -Path $Script:LogFile -Encoding UTF8
    } catch { }
}

# ============================ 设置向导 ============================

function Show-Setup($cfg) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $Script:st = @{
        theme    = if ($cfg) { $cfg.theme } else { 'dark' }
        campus   = if ($cfg) { $cfg.campus } else { '南校区' }
        client   = if ($cfg) { $cfg.client } else { '192.168.84.110' }
        building = if ($cfg) { $cfg.building } else { '' }
        room     = if ($cfg) { $cfg.room } else { '' }
        hotkey   = if ($cfg) { [string]$cfg.hotkey } else { 'CTRL + ALT + E' }
        roomId   = if ($cfg) { [string]$cfg.roomId } else { '' }
    }
    $Script:setupResult = $null
    $pal = Get-Palette $Script:st.theme

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="True" Topmost="True" ResizeMode="NoResize" FocusVisualStyle="{x:Null}"
        SizeToContent="Height" Width="400" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI">
  <Border x:Name="card" CornerRadius="10" Background="%%CBG%%" BorderBrush="%%BORDER%%" BorderThickness="1" Padding="18,15,18,14">
    <Border.Effect>
      <DropShadowEffect BlurRadius="24" ShadowDepth="2" Direction="270" Opacity="%%SHADOW%%" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <StackPanel x:Name="hdr" Orientation="Horizontal">
        <Border x:Name="hdrIcon" Width="26" Height="26" CornerRadius="7" Background="%%ICONBG%%">
          <TextBlock x:Name="hdrGlyph" Text="&#x2699;" FontSize="14" Foreground="%%ACCENT%%" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock x:Name="titleTb" Text="深大电量 · 设置" FontSize="13.5" FontWeight="SemiBold" Foreground="%%TITLE%%" Margin="9,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock x:Name="subTb" Text="填完保存，之后想改再点卡片上的齿轮" FontSize="10.5" Foreground="%%SUB%%" Margin="0,8,0,0"/>

      <TextBlock x:Name="lblTheme" Text="主题" FontSize="10.5" Foreground="%%SUB%%" Margin="0,14,0,0"/>
      <WrapPanel x:Name="themeRow" Margin="0,5,0,0"/>

      <TextBlock x:Name="lblCampus" Text="校区" FontSize="10.5" Foreground="%%SUB%%" Margin="0,8,0,0"/>
      <WrapPanel x:Name="campusRow" Margin="0,5,0,0"/>

      <TextBlock x:Name="lblBuilding" Text="楼栋" FontSize="10.5" Foreground="%%SUB%%" Margin="0,8,0,0"/>
      <WrapPanel x:Name="buildingRow" Margin="0,5,0,0"/>

      <Grid Margin="0,10,0,0">
        <StackPanel HorizontalAlignment="Left">
          <TextBlock x:Name="lblRoom" Text="房间号（三位，如 101）" FontSize="10.5" Foreground="%%SUB%%"/>
          <TextBox x:Name="roomTb" Width="112" Height="28" Margin="0,5,0,0" FontSize="12" Padding="8,4,8,4"
                   Background="%%INBG%%" Foreground="%%INFG%%" BorderBrush="%%INBR%%" CaretBrush="%%INFG%%" BorderThickness="1"/>
        </StackPanel>
        <StackPanel HorizontalAlignment="Right" Width="200">
          <TextBlock x:Name="lblHotkey" Text="快捷键（点框按下组合键）" FontSize="10.5" Foreground="%%SUB%%"/>
          <Grid Margin="0,5,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="hkTb" Grid.Column="0" Height="28" FontSize="11.5" Padding="8,4,8,4" IsReadOnly="True"
                     Background="%%INBG%%" Foreground="%%INFG%%" BorderBrush="%%INBR%%" CaretBrush="%%INFG%%" BorderThickness="1"/>
            <Border x:Name="hkClear" Grid.Column="1" Width="26" Height="28" Margin="6,0,0,0" CornerRadius="6"
                    Background="%%INBG%%" BorderBrush="%%INBR%%" BorderThickness="1">
              <TextBlock Text="&#x2715;" FontSize="11" Foreground="%%SUB%%" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Grid>
        </StackPanel>
      </Grid>

      <TextBlock x:Name="warnTb" FontSize="10" Foreground="%%ERR%%" Margin="0,7,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
      <TextBlock x:Name="tipTb" Text="支持 Ctrl / Alt / Shift / Win 任意组合（如 Win+Alt+E）；清空 = 不设热键。热键由常驻小进程接管，托盘图标右键可退出。" FontSize="9.5" Foreground="%%SUB%%" Margin="0,8,0,0" TextWrapping="Wrap"/>
      <TextBlock x:Name="errTb" FontSize="10.5" Foreground="%%ERR%%" Margin="0,8,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>

      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Border x:Name="btnCancel" CornerRadius="6" Padding="14,6,14,7" Margin="0,0,8,0" Background="#00000000" BorderThickness="1" BorderBrush="%%BORDER%%">
          <TextBlock Text="取消" FontSize="12" Foreground="%%GHOSTFG%%"/>
        </Border>
        <Border x:Name="btnSave" CornerRadius="6" Padding="18,6,18,7" Background="%%BTNBG%%">
          <TextBlock Text="保存" FontSize="12" FontWeight="SemiBold" Foreground="%%BTNFG%%"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

    $xaml = $xaml.Replace('%%CBG%%', $pal.CardBg).Replace('%%BORDER%%', $pal.Border).Replace('%%SHADOW%%', $pal.Shadow)
    $xaml = $xaml.Replace('%%ICONBG%%', $pal.IconBg).Replace('%%ACCENT%%', $pal.Accent).Replace('%%TITLE%%', $pal.Title).Replace('%%SUB%%', $pal.Sub)
    $xaml = $xaml.Replace('%%INBG%%', $pal.InBg).Replace('%%INBR%%', $pal.InBorder).Replace('%%INFG%%', $pal.InFg)
    $xaml = $xaml.Replace('%%BTNBG%%', $pal.BtnBg).Replace('%%BTNFG%%', $pal.BtnFg).Replace('%%GHOSTFG%%', $pal.GhostFg).Replace('%%ERR%%', $pal.Err)

    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $Script:win = $w
    $w.Opacity = 1

    function Pill-Hover($bd, [bool]$enter) {
        if (-not $Script:st) { return }
        $p = Get-Palette $Script:st.theme
        $val = [string]$bd.Tag
        $sel = ($val -eq $Script:st.theme) -or ($val -eq $Script:st.campus) -or ($val -eq $Script:st.building)
        if ($sel) { return }
        $bd.Background = Brush ($(if ($enter) { $p.PillHover } else { $p.PillBg }))
    }

    function New-Pill([string]$text, [string]$value) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.CornerRadius = New-Object System.Windows.CornerRadius(12)
        $bd.Padding      = New-Object System.Windows.Thickness(11,4,11,5)
        $bd.Margin       = New-Object System.Windows.Thickness(0,0,6,6)
        $bd.BorderThickness = New-Object System.Windows.Thickness(1)
        $bd.Cursor = 'Hand'
        $bd.Tag = $value
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = 11.5
        $bd.Child = $tb
        $bd.Add_MouseEnter({ param($s, $e) Pill-Hover $s $true })
        $bd.Add_MouseLeave({ param($s, $e) Pill-Hover $s $false })
        $bd
    }

    function Style-Pill($bd, [bool]$selected) {
        $p = Get-Palette $Script:st.theme
        $bd.Background   = Brush ($(if ($selected) { $p.PillSel } else { $p.PillBg }))
        $bd.BorderBrush  = Brush ($(if ($selected) { $p.PillSelBorder } else { '#00000000' }))
        $bd.Child.Foreground = Brush ($(if ($selected) { $p.PillSelFg } else { $p.PillFg }))
    }

    function Update-Pills {
        $rows = @{
            'themeRow'    = $Script:st.theme
            'campusRow'   = $Script:st.campus
            'buildingRow' = $Script:st.building
        }
        foreach ($k in $rows.Keys) {
            $row = $Script:win.FindName($k)
            if (-not $row) { continue }
            foreach ($bd in $row.Children) {
                if ($bd -is [System.Windows.Controls.Border]) { Style-Pill $bd ([string]$bd.Tag -eq $rows[$k]) }
            }
        }
    }

    function Update-HkBox {
        $p = Get-Palette $Script:st.theme
        $tb = $Script:win.FindName('hkTb')
        if ($Script:st.hotkey) {
            $tb.Text = $Script:st.hotkey
            $tb.Foreground = Brush $p.InFg
        } else {
            $tb.Text = '未设置（不设热键）'
            $tb.Foreground = Brush $p.Sub
        }
    }

    function Test-HotkeyConflict([string]$hk) {
        if (-not $hk) { return $null }
        $spec = Get-HotkeySpec $hk
        if (-not $spec) { return $null }
        # 常驻进程正占着自己配置的那个组合，属于正常，不算冲突
        if ($cfg -and $cfg.hotkey -and $hk -eq $cfg.hotkey -and (Test-AgentRunning)) { return $null }
        try {
            if (-not ('SzHotkey' -as [type])) {
                Add-Type -TypeDefinition $Script:HotkeyCs -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
            }
            $probe = New-Object SzHotkey
            $ok = $probe.Register($spec.Mods, $spec.Vk)
            $probe.Unregister()
            if (-not $ok) { return '这个组合被系统或别的程序占用了：保存也能保存，但按下去可能不生效' }
        } catch { }
        $null
    }

    function Update-HotkeyWarning {
        $tb = $Script:win.FindName('warnTb')
        if (-not $tb) { return }
        $msg = Test-HotkeyConflict $Script:st.hotkey
        if ($msg) { $tb.Text = $msg; $tb.Visibility = 'Visible' }
        else { $tb.Visibility = 'Collapsed' }
    }

    function Restyle {
        try {
            $p = Get-Palette $Script:st.theme
            $c = $Script:win.FindName('card')
            $c.Background  = Brush $p.CardBg
            $c.BorderBrush = Brush $p.Border
            if ($c.Effect) { $c.Effect.Opacity = [double]$p.Shadow }
            $Script:win.FindName('titleTb').Foreground = Brush $p.Title
            $Script:win.FindName('subTb').Foreground   = Brush $p.Sub
            $Script:win.FindName('tipTb').Foreground   = Brush $p.Sub
            $Script:win.FindName('hdrGlyph').Foreground = Brush $p.Accent
            $Script:win.FindName('hdrIcon').Background  = Brush $p.IconBg
            $Script:win.FindName('errTb').Foreground    = Brush $p.Err
            $Script:win.FindName('warnTb').Foreground   = Brush $p.Err
            foreach ($n in 'lblTheme','lblCampus','lblBuilding','lblRoom','lblHotkey') {
                $Script:win.FindName($n).Foreground = Brush $p.Sub
            }
            foreach ($n in 'roomTb','hkTb') {
                $t = $Script:win.FindName($n)
                $t.Background  = Brush $p.InBg
                $t.Foreground  = Brush $p.InFg
                $t.BorderBrush = Brush $p.InBorder
                $t.CaretBrush  = Brush $p.InFg
            }
            $clr = $Script:win.FindName('hkClear')
            $clr.Background  = Brush $p.InBg
            $clr.BorderBrush = Brush $p.InBorder
            $clr.Child.Foreground = Brush $p.Sub
            $Script:win.FindName('btnSave').Background = Brush $p.BtnBg
            $Script:win.FindName('btnSave').Child.Foreground = Brush $p.BtnFg
            $Script:win.FindName('btnCancel').Child.Foreground = Brush $p.GhostFg
            $Script:win.FindName('btnCancel').BorderBrush = Brush $p.Border
            Update-Pills
            Update-HkBox
        } catch { SzuLog ('Restyle ERR: ' + $_.Exception.Message) }
    }

    function Rebuild-Buildings {
        $row = $Script:win.FindName('buildingRow')
        $row.Children.Clear()
        $list = @()
        $fail = $null
        try { $list = @(Get-Buildings $Script:st.client) } catch { $fail = $_.Exception.Message }

        if (-not $list.Count) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = if ($fail) { '拉不到楼栋列表，先连校园网' } else { '这个校区没有可选楼栋' }
            $tb.FontSize = 11
            $tb.Foreground = Brush (Get-Palette $Script:st.theme).Err
            [void]$row.Children.Add($tb)
            return
        }
        foreach ($b in $list) {
            $bd = New-Pill $b.Name $b.Name
            $bd.Add_MouseLeftButtonDown({
                param($s, $e)
                $Script:st.building = [string]$s.Tag
                Update-Pills
                $Script:win.FindName('errTb').Visibility = 'Collapsed'
            })
            [void]$row.Children.Add($bd)
        }
        Update-Pills
    }

    foreach ($t in @(@('dark','深色'), @('light','浅色'), @('auto','跟随系统'))) {
        $bd = New-Pill $t[1] $t[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $Script:st.theme = [string]$s.Tag
            SzuLog ('theme click -> ' + $Script:st.theme)
            Restyle
        })
        [void]$Script:win.FindName('themeRow').Children.Add($bd)
    }

    foreach ($c in $Script:Campuses) {
        $bd = New-Pill $c.Name $c.Name
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $Script:st.campus = [string]$s.Tag
            foreach ($cc in $Script:Campuses) { if ($cc.Name -eq $Script:st.campus) { $Script:st.client = $cc.Client } }
            Rebuild-Buildings
            Update-Pills
        })
        [void]$Script:win.FindName('campusRow').Children.Add($bd)
    }

    $Script:win.FindName('roomTb').Text = $Script:st.room
    Rebuild-Buildings
    Restyle
    Update-HotkeyWarning

    $Script:win.FindName('roomTb').Add_TextChanged({
        param($s, $e)
        $Script:st.room = ($s.Text -replace '\s', '')
    })

    # 快捷键：按组合键录入，Backspace/Delete 清空
    $Script:winDown = $false
    $Script:winKeySeen = $false
    $Script:winKeyUp = {
        param($s, $e)
        if ($e.Key -eq 'LWin' -or $e.Key -eq 'RWin') { $Script:winDown = $false }
    }
    $Script:win.Add_KeyUp($Script:winKeyUp)

    $Script:win.FindName('hkTb').Add_PreviewKeyDown({
        param($s, $e)
        $k = $e.Key
        if ($k -eq 'System') { $k = $e.SystemKey }   # Alt 组合会走 SystemKey
        $name = $k.ToString()
        SzuLog ('hk key: ' + $name + ' mods=' + $e.KeyboardDevice.Modifiers + ' winDown=' + $Script:winDown)

        if ($name -eq 'LWin' -or $name -eq 'RWin') { $Script:winDown = $true; $Script:winKeySeen = $true; return }
        if ($name -eq 'Back' -or $name -eq 'Delete') {
            $e.Handled = $true
            $Script:st.hotkey = ''
            Update-HkBox
            return
        }
        if ($name -match '^(Left|Right)(Ctrl|Alt|Shift)$' -or $name -eq 'Escape') { return }
        $e.Handled = $true

        $mods = @()
        $m = $e.KeyboardDevice.Modifiers
        if ($Script:winDown -or ($m -band [System.Windows.Input.ModifierKeys]::Windows)) { $mods += 'WIN' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Control) { $mods += 'CTRL' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Alt)     { $mods += 'ALT' }
        if ($m -band [System.Windows.Input.ModifierKeys]::Shift)   { $mods += 'SHIFT' }

        if ($name -match '^D(\d)$') { $name = $Matches[1] }
        elseif ($name -match '^F([1-9]|1[0-2])$') { $name = $name }
        elseif ($name -match '^[A-Z]$') { $name = $name }
        else { $name = $null }

        $err = $Script:win.FindName('errTb')
        if (-not $name) {
            $err.Text = '这个键不认，用 A-Z / 0-9 / F1-F12'
            $err.Visibility = 'Visible'
            return
        }
        if ($mods.Count -eq 0) {
            $err.Text = '至少带一个修饰键（Ctrl / Alt / Shift / Win），不然打字会误触'
            $err.Visibility = 'Visible'
            return
        }
        $Script:st.hotkey = ($mods -join ' + ') + ' + ' + $name
        Update-HkBox
        $err.Visibility = 'Collapsed'
        Update-HotkeyWarning
    })

    # ✕ 清空热键
    $Script:win.FindName('hkClear').Add_MouseLeftButtonDown({
        param($s, $e)
        $Script:st.hotkey = ''
        Update-HkBox
        $Script:win.FindName('errTb').Visibility = 'Collapsed'
        Update-HotkeyWarning
    })

    $btnIn = {
        param($s, $e)
        $p = Get-Palette $Script:st.theme
        switch ([string]$s.Tag) {
            'save'  { $s.Background = Brush $p.BtnHover }
            'ghost' { $s.Background = Brush $p.PillSel }
            'chip'  { $s.Background = Brush $p.InBorder }
        }
    }
    $btnOut = {
        param($s, $e)
        $p = Get-Palette $Script:st.theme
        switch ([string]$s.Tag) {
            'save'  { $s.Background = Brush $p.BtnBg }
            'ghost' { $s.Background = Brush '#00000000' }
            'chip'  { $s.Background = Brush $p.InBg }
        }
    }
    foreach ($pair in @(@('btnSave', 'save'), @('btnCancel', 'ghost'), @('hkClear', 'chip'))) {
        $el = $Script:win.FindName($pair[0])
        $el.Tag = $pair[1]
        $el.Cursor = 'Hand'
        $el.Add_MouseEnter($btnIn)
        $el.Add_MouseLeave($btnOut)
    }

    $Script:win.FindName('btnCancel').Add_MouseLeftButtonDown({ param($s, $e) $Script:win.Close() })
    $Script:win.FindName('btnSave').Add_MouseLeftButtonDown({
        param($s, $e)
        $err = $Script:win.FindName('errTb')
        $room = $Script:st.room
        if (-not $Script:st.building) { $err.Text = '选一个楼栋'; $err.Visibility = 'Visible'; return }
        if ($room -notmatch '^\d{3,4}$') { $err.Text = '房间号填三位数，比如 101'; $err.Visibility = 'Visible'; return }

        # 冲突只提示，不拦着保存
        Update-HotkeyWarning

        $err.Text = '正在核对房间…'; $err.Visibility = 'Visible'
        $roomId = ''
        try {
            $roomId = Resolve-RoomId $Script:st.client $Script:st.building $room
        } catch {
            $err.Text = $_.Exception.Message
            $err.Visibility = 'Visible'
            return
        }
        $Script:setupResult = @{
            theme       = $Script:st.theme
            campus      = $Script:st.campus
            client      = $Script:st.client
            building    = $Script:st.building
            room        = $room
            roomId      = $roomId
            hotkey      = [string]$Script:st.hotkey
            holdSeconds = if ($cfg -and $cfg.holdSeconds) { $cfg.holdSeconds } else { 20 }
        }
        $Script:win.Close()
    })

    $Script:win.FindName('hdr').Add_MouseLeftButtonDown({ param($s, $e) try { $Script:win.DragMove() } catch { } })
    $Script:win.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })

    [void]$w.ShowDialog()
    $Script:setupResult
}

# ============================ 结果卡片 ============================

function Show-Card($data, $cfg, [string]$errText, [switch]$NoBlock, [switch]$IsAgent, [switch]$Warm) {
    $Script:suppressFade = $Warm.IsPresent
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $p = Get-Palette $cfg.theme
    $Script:cardResult = 'close'
    $header = '深大电量 · ' + $cfg.campus + ' ' + $cfg.building + ' ' + $cfg.room

    if ($errText) {
        $sub = '查询失败'
        $e2 = $errText -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        $body = @'
      <TextBlock Text="%%ERRTEXT%%" Foreground="%%ERR%%" FontSize="11.5" TextWrapping="Wrap" Margin="2,14,2,0"/>
'@
        $body = $body.Replace('%%ERRTEXT%%', $e2)
    } else {
        $last = $data.Last
        $remainTxt = $last.Remain.ToString('0.00', $Script:Inv)
        $dayTxt = if ($null -ne $data.DayUse) { [double]$data.DayUse.ToString('0.##', $Script:Inv) } else { '--' }
        $sub = '数据 ' + $last.Date
        if ($data.Avg -gt 0) { $sub += ('  ·  约还可用 {0} 天' -f [math]::Floor($last.Remain / $data.Avg)) }
        if ($data.Recharge -gt 0.01) { $sub += ('  ·  刚充了 {0} 度' -f $data.Recharge.ToString('0.##', $Script:Inv)) }

        $series = $data.Series
        $cw = 344.0; $topY = 24.0; $botY = 64.0; $padL = 36.0; $padR = 10.0
        $maxV = ($series | Measure-Object Value -Maximum).Maximum
        if (-not $maxV -or $maxV -le 0) { $maxV = 1 }
        $maxV = [math]::Ceiling($maxV / 4.0) * 4
        $n = $series.Count
        $xs = @(); $ys = @()
        for ($i = 0; $i -lt $n; $i++) {
            $x = if ($n -eq 1) { $cw / 2 } else { $padL + $i * (($cw - $padL - $padR) / ($n - 1)) }
            $y = $botY - ($series[$i].Value / $maxV) * ($botY - $topY)
            $xs += $x; $ys += $y
        }
        $sb = New-Object System.Text.StringBuilder
        function Add-X([string]$fmt, [object[]]$a) { [void]$sb.AppendFormat($Script:Inv, $fmt, $a) }

        $fGrid = '<Line X1="{0}" Y1="{1}" X2="{2}" Y2="{1}" Stroke="' + $p.Grid + '" StrokeThickness="1"/>'
        $fTick = '<TextBlock Canvas.Left="0" Canvas.Top="{0}" Width="18" Text="{1}" TextAlignment="Right" FontSize="9" Foreground="' + $p.Axis + '"/>'
        $fArea = '<Polygon Points="{0}" Fill="' + $p.Area + '"/>'
        $fLine = '<Polyline Points="{0}" Stroke="' + $p.Accent + '" StrokeThickness="2" StrokeLineJoin="Round"/>'
        $fDot  = '<Ellipse Canvas.Left="{0}" Canvas.Top="{1}" Width="7" Height="7" Fill="' + $p.DotIn + '" Stroke="' + $p.Accent + '" StrokeThickness="2"/>'
        $fVal  = '<TextBlock Canvas.Left="{0}" Canvas.Top="{1}" Width="40" Text="{2}" TextAlignment="Center" FontSize="9.5" Foreground="' + $p.Value + '"/>'
        $fDate = '<TextBlock Canvas.Left="{0}" Canvas.Top="68" Width="40" Text="{1}" TextAlignment="Center" FontSize="9" Foreground="' + $p.Date + '"/>'

        foreach ($frac in 0.0, 0.5, 1.0) {
            $gy = $botY - $frac * ($botY - $topY)
            Add-X $fGrid @($padL, $gy.ToString('0.#', $Script:Inv), ($cw - $padR))
            Add-X $fTick @((($gy - 7).ToString('0.#', $Script:Inv)), ([math]::Round($maxV * $frac).ToString('0', $Script:Inv)))
        }
        if ($n -ge 2) {
            $area = (@(for ($i = 0; $i -lt $n; $i++) { ('{0:0.0},{1:0.0}' -f $xs[$i], $ys[$i]) }) -join ' ') + (' {0:0.0},{1:0.0} {2:0.0},{3:0.0}' -f $xs[-1], $botY, $xs[0], $botY)
            Add-X $fArea @($area)
            $pts = (@(for ($i = 0; $i -lt $n; $i++) { ('{0:0.0},{1:0.0}' -f $xs[$i], $ys[$i]) }) -join ' ')
            Add-X $fLine @($pts)
        }
        for ($i = 0; $i -lt $n; $i++) {
            Add-X $fDot @((($xs[$i] - 3.5).ToString('0.#', $Script:Inv)), (($ys[$i] - 3.5).ToString('0.#', $Script:Inv)))
            Add-X $fVal @((($xs[$i] - 20).ToString('0.#', $Script:Inv)), (($ys[$i] - 20).ToString('0.#', $Script:Inv)), ($series[$i].Value.ToString('0.##', $Script:Inv)))
            Add-X $fDate @((($xs[$i] - 20).ToString('0.#', $Script:Inv)), $series[$i].Label)
        }
        $chart = $sb.ToString()

        $body = @'
      <StackPanel Orientation="Horizontal" Margin="2,14,0,2">
        <TextBlock Text="%%REMAIN%%" Foreground="%%TITLE%%" FontSize="30" FontWeight="Light"/>
        <TextBlock Text=" 度" Foreground="%%SUB2%%" FontSize="13" VerticalAlignment="Bottom" Margin="1,0,0,7"/>
        <StackPanel Margin="26,2,0,0">
          <TextBlock Text="昨日用电" Foreground="%%SUB2%%" FontSize="10.5"/>
          <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
            <TextBlock Text="%%DAY%%" Foreground="%%TITLE%%" FontSize="17"/>
            <TextBlock Text=" 度" Foreground="%%SUB2%%" FontSize="11" VerticalAlignment="Bottom" Margin="1,0,0,3"/>
          </StackPanel>
        </StackPanel>
      </StackPanel>
      <TextBlock Text="近 5 天每日用电（度）" Foreground="%%SUB2%%" FontSize="9.5" Margin="2,10,0,0"/>
      <Canvas Width="344" Height="86" Margin="0,4,0,0">
%%CHART%%
      </Canvas>
'@
        $body = $body.Replace('%%REMAIN%%', $remainTxt).Replace('%%DAY%%', $dayTxt).Replace('%%CHART%%', $chart)
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize" FocusVisualStyle="{x:Null}"
        SizeToContent="Height" Width="376" FontFamily="Microsoft YaHei UI">
  <Border CornerRadius="9" Background="%%CBG%%" BorderBrush="%%BORDER%%" BorderThickness="1" Padding="15,13,15,11">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="2" Direction="270" Opacity="%%SHADOW%%" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <Grid>
        <StackPanel Orientation="Horizontal">
          <Border Width="28" Height="28" CornerRadius="7" Background="%%ICONBG%%" VerticalAlignment="Top">
            <TextBlock Text="&#x26A1;" FontSize="15" Foreground="%%ACCENT%%" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="10,0,0,0">
            <TextBlock Text="%%HEADER%%" Foreground="%%TITLE%%" FontSize="13.5" FontWeight="SemiBold"/>
            <TextBlock Text="%%SUBTXT%%" Foreground="%%SUB2%%" FontSize="11" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Border x:Name="gearBtn" Width="22" Height="22" CornerRadius="5" Margin="0,0,6,0" Cursor="Hand" ToolTip="设置">
            <Border.Style>
              <Style TargetType="Border">
                <Setter Property="Background" Value="%%CHIPBG%%"/>
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="%%ICONBG%%"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </Border.Style>
            <TextBlock Text="&#x2699;" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center">
              <TextBlock.Style>
                <Style TargetType="TextBlock">
                  <Setter Property="Foreground" Value="%%CHIPFG%%"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=Border}}" Value="True">
                      <Setter Property="Foreground" Value="%%ACCENT%%"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </TextBlock.Style>
            </TextBlock>
          </Border>
          <Border Width="22" Height="22" CornerRadius="5" Cursor="Hand" ToolTip="回车 / 点击关闭">
            <Border.Style>
              <Style TargetType="Border">
                <Setter Property="Background" Value="%%CHIPBG%%"/>
                <Style.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="%%ICONBG%%"/>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </Border.Style>
            <TextBlock Text="&#x2715;" FontSize="10.5" HorizontalAlignment="Center" VerticalAlignment="Center">
              <TextBlock.Style>
                <Style TargetType="TextBlock">
                  <Setter Property="Foreground" Value="%%CHIPFG%%"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=Border}}" Value="True">
                      <Setter Property="Foreground" Value="%%ACCENT%%"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </TextBlock.Style>
            </TextBlock>
          </Border>
        </StackPanel>
      </Grid>
%%BODY%%
    </StackPanel>
  </Border>
</Window>
'@

    $xaml = $xaml.Replace('%%HEADER%%', $header).Replace('%%SUBTXT%%', $sub).Replace('%%BODY%%', $body)
    $xaml = $xaml.Replace('%%CBG%%', $p.CardBg).Replace('%%BORDER%%', $p.Border).Replace('%%SHADOW%%', $p.Shadow)
    $xaml = $xaml.Replace('%%ICONBG%%', $p.IconBg).Replace('%%ACCENT%%', $p.Accent).Replace('%%TITLE%%', $p.Title)
    $xaml = $xaml.Replace('%%SUB2%%', $p.Sub).Replace('%%CHIPBG%%', $p.ChipBg).Replace('%%CHIPFG%%', $p.ChipFg)
    $xaml = $xaml.Replace('%%ERR%%', $p.Err)

    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $Script:w = $w

    $wa = [System.Windows.SystemParameters]::WorkArea
    $w.Left = $wa.Right - $w.Width - 16
    $w.Top  = $wa.Bottom - 200 - 16
    $w.Opacity = 0

    $Script:w.FindName('gearBtn').Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true
        $Script:cardResult = 'settings'
        $Script:w.Close()
    })

    $w.Add_Loaded({
        $Script:w.Top = [System.Windows.SystemParameters]::WorkArea.Bottom - $Script:w.ActualHeight - 16
        if (-not $Script:suppressFade) {
            $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120)))
            $Script:w.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
            $Script:w.Activate()
        }
    })
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Enter' -or $e.Key -eq 'Escape' -or $e.Key -eq 'Space') { $s.Close() } })
    $w.Add_MouseLeftButtonDown({ $Script:w.Close() })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([int]$cfg.holdSeconds)
    $timer.Add_Tick({
        $timer.Stop()
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
        $fadeOut.Add_Completed({ $Script:w.Close() })
        $Script:w.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeOut)
    })
    $timer.Start()

    if ($NoBlock) {
        $w.Show()
        return $w
    }
    [void]$w.ShowDialog()
    $Script:cardResult
}

# ============================ 热键 / 常驻进程 ============================

$Script:HotkeyCs = @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class SzHotkey : NativeWindow
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event EventHandler Pressed;

    public SzHotkey()
    {
        var cp = new CreateParams();
        cp.Caption = "SzPowerHotkey";
        cp.X = -200; cp.Y = -200;
        cp.Width = 1; cp.Height = 1;
        CreateHandle(cp);
    }

    public bool Register(uint mods, uint vk)
    {
        UnregisterHotKey(Handle, 1);
        return RegisterHotKey(Handle, 1, mods | 0x4000u, vk);
    }

    public void Unregister() { UnregisterHotKey(Handle, 1); }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312)
        {
            var h = Pressed;
            if (h != null) h(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
'@

function Get-HotkeySpec([string]$hk) {
    if (-not $hk) { return $null }
    $parts = @($hk -split '\s*\+\s*' | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $null }
    $key = $parts[-1]
    $mods = 0
    foreach ($p in $parts[0..($parts.Count - 2)]) {
        switch ($p.ToUpper()) {
            'CTRL'  { $mods = $mods -bor 2 }
            'ALT'   { $mods = $mods -bor 1 }
            'SHIFT' { $mods = $mods -bor 4 }
            'WIN'   { $mods = $mods -bor 8 }
        }
    }
    $vk = 0
    if ($key -match '^[A-Z]$') { $vk = [int][char]$key }
    elseif ($key -match '^\d$') { $vk = 0x30 + [int]$key }
    elseif ($key -match '^F(\d{1,2})$') { $vk = 0x70 + ([int]$Matches[1] - 1) }
    else { return $null }
    @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}

function Show-Quick {
    try {
        # 用缓存秒开，缓存由 -Fetch 后台刷新
        $card = $Script:card
        if ($card) { try { $card.Close() } catch { } }
        $data = Read-Cache
        $err = $null
        if (-not $data) {
            try {
                $data = Get-PowerData $Script:cfg
                Save-Cache $data
                Write-History $data
            } catch { $err = $_.Exception.Message }
        }
        $Script:card = Show-Card $data $Script:cfg $err -NoBlock -IsAgent
        # 顺手起后台刷新，下次按更准
        Start-Prefetch
    } catch {
        # 任何异常都不能让常驻进程陪葬
        SzuLog ('Show-Quick ERR: ' + $_.Exception.Message)
    }
}

function Start-Prefetch {
    if ($Script:prefetching) { return }
    $Script:prefetching = $true
    try {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Get-VbsPath) + '" -Fetch') -WindowStyle Hidden | Out-Null
    } catch { }
    $Script:prefetchCooldown = (Get-Date)
}

function Run-Agent {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

    $created = $false
    try { $Script:mutex = New-Object System.Threading.Mutex($true, $Script:MutexName, [ref]$created) } catch { return }
    if (-not $created) { return }

    $cfg = Read-Config
    if (-not $cfg) { return }
    $Script:cfg = $cfg
    $Script:card = $null
    $Script:prefetching = $false

    # ---- 托盘 ----
    $ni = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path $Script:Icon) { $ni.Icon = New-Object System.Drawing.Icon($Script:Icon) }
    else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    $ni.Text = '深大电量'
    $ni.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $menu.Items.Add('查看电量')
    $miSet  = $menu.Items.Add('设置…')
    $miQuit = $menu.Items.Add('退出常驻')
    $ni.ContextMenuStrip = $menu

    $miOpen.Add_Click({ Show-Quick })
    $ni.Add_MouseDoubleClick({ Show-Quick })
    $miSet.Add_Click({
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$Script:Ps1+'"'),'-Setup') -WindowStyle Hidden
    })
    $miQuit.Add_Click({
        $ni.Visible = $false
        $ni.Dispose()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    })

    # ---- 全局热键 ----
    if (-not ('SzHotkey' -as [type])) {
        Add-Type -TypeDefinition $Script:HotkeyCs -ReferencedAssemblies 'System.Windows.Forms','System.Drawing'
    }
    $hip = New-Object SzHotkey
    $hip.Add_Pressed({ Show-Quick })

    function Apply-Hotkey($c) {
        $spec = Get-HotkeySpec $c.hotkey
        $hip.Unregister()
        if ($spec) {
            $ok = $hip.Register($spec.Mods, $spec.Vk)
            SzuLog ("register hotkey {0} -> {1}" -f $c.hotkey, $ok)
        }
    }
    Apply-Hotkey $cfg

    # ---- 定时器：预取 / 配置变更 / 外部触发 ----
    $tPrefetch = New-Object System.Windows.Threading.DispatcherTimer
    $tPrefetch.Interval = [TimeSpan]::FromMinutes(10)
    $tPrefetch.Add_Tick({ Start-Prefetch })
    $tPrefetch.Start()

    $cfgStamp = (Get-Item $Script:CfgFile).LastWriteTime
    $tWatch = New-Object System.Windows.Threading.DispatcherTimer
    $tWatch.Interval = [TimeSpan]::FromSeconds(2)
    $tWatch.Add_Tick({
        $f = Get-Item $Script:CfgFile -ErrorAction SilentlyContinue
        if ($f -and $f.LastWriteTime -ne $cfgStamp) {
            $cfgStamp = $f.LastWriteTime
            $c = Read-Config
            if ($c) { $Script:cfg = $c; Apply-Hotkey $c; SzuLog 'config reloaded' }
        }
        # 外部（桌面图标）触发的显示请求
        if (Test-Path $Script:FlagFile) {
            Remove-Item $Script:FlagFile -Force -ErrorAction SilentlyContinue
            Show-Quick
        }
    })
    $tWatch.Start()

    # 首次：没有缓存就先同步抓一次（后台等 1 秒，不挡热键）
    if (-not (Test-Path $Script:CacheFile)) {
        try {
            $d = Get-PowerData $Script:cfg
            Save-Cache $d
        } catch { }
    }

    # 预热：悄悄渲染一张透明卡片再关掉，避免第一次按热键卡半秒
    try {
        $cd = Read-Cache
        if ($cd) {
            $ww = Show-Card $cd $Script:cfg $null -NoBlock -Warm
            Start-Sleep -Milliseconds 250
            $ww.Close()
            $Script:card = $null
        }
    } catch { SzuLog ('warm ERR: ' + $_.Exception.Message) }

    [System.Windows.Threading.Dispatcher]::Run()
}

# ============================ 入口 ============================

$Script:Ps1 = $MyInvocation.MyCommand.Path

if ($Console) {
    $cfg = Read-Config
    if (-not $cfg) { Write-Output '还没有配置：先跑一次不带 -Console 的图形界面完成设置。'; exit 1 }
    $d = Get-PowerData $cfg
    Write-Output ('校区：{0}  {1}  {2}' -f $cfg.campus, $cfg.building, $cfg.room)
    Write-Output ('剩余电量：{0} 度' -f $d.Last.Remain.ToString('0.00', $Script:Inv))
    if ($null -ne $d.DayUse) { Write-Output ('昨日用电：{0} 度' -f $d.DayUse.ToString('0.##', $Script:Inv)) }
    Write-Output ('近5天：' + (($d.Series | ForEach-Object { '{0}={1}' -f $_.Label, $_.Value }) -join '  '))
    exit 0
}

if ($Fetch) {
    $cfg = Read-Config
    if ($cfg) {
        try {
            $d = Get-PowerData $cfg
            Save-Cache $d
            Write-History $d
            if ($d.RoomId -and $d.RoomId -ne $cfg.roomId) { $cfg.roomId = $d.RoomId; Save-Config $cfg }
        } catch { SzuLog ('fetch ERR: ' + $_.Exception.Message) }
    }
    exit 0
}

if ($Agent) { Run-Agent; exit 0 }

if ($Install) {
    $cfg = Read-Config
    [void](New-DesktopShortcut)
    $Setup = $true
}

$cfg = Read-Config
if (-not $cfg -or $Setup) {
    $cfg = Show-Setup $cfg
    if (-not $cfg) { exit 0 }
    Save-Config $cfg
    Update-Autostart $cfg
    if ($Setup) { exit 0 }
}

# 有常驻进程时，让它来画卡片：写个信号文件，400ms 内出图
if (Test-AgentRunning) {
    try {
        Set-Content -Path $Script:FlagFile -Value (Get-Date).ToString('s') -Encoding ASCII
        exit 0
    } catch { }
}

while ($true) {
    $data = $null; $err = $null
    try {
        $data = Get-PowerData $cfg
        Save-Cache $data
        Write-History $data
    } catch { $err = $_.Exception.Message }

    $r = Show-Card $data $cfg $err
    if ($r -eq 'settings') {
        $new = Show-Setup $cfg
        if ($new) {
            $cfg = $new
            Save-Config $cfg
            Update-Autostart $cfg
        }
        continue
    }
    break
}




