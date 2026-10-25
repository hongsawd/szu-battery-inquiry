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
    [switch]$Fetch,
    [switch]$Demo,
    [switch]$Repair
)

$ErrorActionPreference = 'Stop'

# 兜底：任何终止性错误都留一份栈，别让窗口“什么都没发生”
trap {
    $m = ($_ | Out-String) + "`n" + $_.ScriptStackTrace
    try { Add-Content (Join-Path $env:TEMP 'szu-crash.txt') ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch { }
    exit 1
}


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
            WarnBg = '#1FFFC42B1C'; WarnBr = '#66FFC42B1C'
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
        WarnBg = '#26FF6B6B'; WarnBr = '#66FF6B6B'
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
            autostart   = if ($null -ne $o.autostart) { [bool]$o.autostart } else { $true }
            fastMode    = if ($null -ne $o.fastMode) { [bool]$o.fastMode } else { $true }
            scale       = if ($o.scale) { [double]$o.scale } else { 1.0 }
            holdSeconds = if ($null -ne $o.holdSeconds) { [int]$o.holdSeconds } else { 20 }
            warnBelow   = if ($null -ne $o.warnBelow) { [double]$o.warnBelow } else { 20 }
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

function New-Shortcut([string]$LnkPath, [string]$ScriptFile, [string]$Desc) {
    # 直接指向 .vbs 本身：不依赖 Arguments。
    # （曾用 wscript.exe + Arguments，参数一旦丢失，wscript 会弹"脚本宿主设置"而不是运行程序）
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($LnkPath)
    $s.TargetPath       = $ScriptFile
    $s.Arguments        = ''
    $s.WorkingDirectory = $Script:Root
    $s.IconLocation     = $Script:Icon
    $s.Description      = $Desc
    $s.WindowStyle      = 1
    $s.Save()
}

function Get-VbsPath { Join-Path $Script:Root 'szu-power.vbs' }
function Get-AgentVbsPath { Join-Path $Script:Root 'agent.vbs' }

function New-DesktopShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'
    New-Shortcut $lnk (Get-VbsPath) '查宿舍剩余电量'
    $lnk
}

function Repair-Shortcuts($cfg) {
    [void](New-DesktopShortcut)
    if ($cfg) { Update-Autostart $cfg }
    Write-Output ('已重建快捷方式：' + (Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'))
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
    # 只有「开了自启」且「设了热键」才需要常驻：自启只是为了热键随时可用
    $hasKey = ([bool]$cfg.autostart) -and [bool]$cfg.hotkey
    # 热键交给常驻进程处理，快捷方式热键就不再需要（避免双触发）
    $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '深大电量.lnk'
    if (Test-Path $deskLnk) {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut($deskLnk); $s.Hotkey = ''; $s.Save()
        } catch { }
    }
    if ($hasKey) {
        New-Shortcut $startup (Get-AgentVbsPath) '深大电量热键常驻'
        if (-not (Test-AgentRunning)) {
            Start-Process -FilePath (Get-AgentVbsPath) -WindowStyle Hidden
        }
    } else {
        if (Test-Path $startup) { Remove-Item $startup -Force -ErrorAction SilentlyContinue }
        if ($Script:isAgent) {
            # 自己就是那个常驻进程；配置已落盘，直接退出即可
            SzuLog 'autostart off -> exit agent'
            [System.Environment]::Exit(0)
        }
        # 其他情况：常驻进程会在 2 秒内读到配置变化，自己退场（见 Run-Agent 的配置监视器）
    }
}

# ============================ 数据 ============================

function Get-Rows([string]$client, [string]$roomId, [string]$room, [datetime]$from, [datetime]$to) {
    $body = 'hiddenType=&isHost=&beginTime={0}&endTime={1}&type=2&client={2}&roomId={3}&roomName={4}&building=' -f `
        $from.ToString('yyyy-MM-dd'), $to.ToString('yyyy-MM-dd'), $client, $roomId, (Get-GbkPercent $room)
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
    $rows
}

function Get-PowerData($cfg) {
    $roomId = $cfg.roomId
    if (-not $roomId) {
        $roomId = Resolve-RoomId $cfg.client $cfg.building $cfg.room
    }
    $today = (Get-Date).Date

    # 服务端一次最多回 20 条记录，所以拆两段抓：最近 20 天 + 再往前 20 天，拼起来凑够一个月
    $w1 = @(Get-Rows $cfg.client $roomId $cfg.room $today.AddDays(-19) $today)
    $w2 = @()
    if ($w1.Count -ge 18) {
        $w2 = @(Get-Rows $cfg.client $roomId $cfg.room $today.AddDays(-34) $today.AddDays(-20))
    }
    $seen = @{}
    foreach ($r in @($w1 + $w2)) { $seen[$r.Date] = $r }
    $rows = @($seen.Values | Sort-Object Date)

    if (-not $rows.Count) {
        if ($cfg.roomId) {
            $cfg.roomId = ''
            return Get-PowerData $cfg
        }
        throw ("房间 {0} 查到了，但没有用电数据（系统还没更新，或房间号不对）" -f $cfg.room)
    }

    $last = $rows[-1]
    $prev = if ($rows.Count -ge 2) { $rows[-2] } else { $null }

    # 逐日用电：相邻两天总用电量相减，按间隔天数摊平
    $daily = @()
    for ($i = 1; $i -lt $rows.Count; $i++) {
        $gap = ([datetime]$rows[$i].Date - [datetime]$rows[$i - 1].Date).Days
        if ($gap -lt 1 -or $gap -gt 3) { continue }
        $d = [math]::Round(($rows[$i].Used - $rows[$i - 1].Used) / $gap, 2)
        $daily += [pscustomobject]@{ Date = $rows[$i].Date; Value = $d }
    }

    # 折线图：最近 5 天
    $series = @($daily | Select-Object -Last 5 |
        ForEach-Object { [pscustomobject]@{ Label = $_.Date.Substring(5); Value = [math]::Max($_.Value, 0) } })

    # 平均：近一个月里剔掉电表归零 / 跳变异常（>80 度/天）后的日均
    $valid = @($daily | Where-Object { $_.Value -gt 0 -and $_.Value -le 80 })
    if (-not $valid.Count) { $valid = @($daily | Where-Object { $_.Value -gt 0 }) }

    [pscustomobject]@{
        Last     = $last
        Prev     = $prev
        Series   = $series
        DayUse   = if ($daily.Count) { $daily[-1].Value } elseif ($prev) { [math]::Round($last.Used - $prev.Used, 2) } else { $null }
        Recharge = if ($prev) { [math]::Round($last.Bought - $prev.Bought, 2) } else { 0 }
        Avg      = if ($valid.Count) { [math]::Round((($valid | Measure-Object Value -Average).Average), 2) } else { 0 }
        AvgDays  = $valid.Count
        Days     = $rows.Count
        RoomId   = $roomId
    }
}

function Write-History($data) {
    try {
        if (-not (Test-Path $Script:DataDir)) { New-Item -ItemType Directory -Path $Script:DataDir -Force | Out-Null }
        $header = 'query_time,data_date,remain,used_total,bought_total,avg_per_day,days_left'
        if (Test-Path $Script:LogFile) {
            $first = Get-Content $Script:LogFile -First 1 -Encoding UTF8
            if ($first -notlike '*avg_per_day*') {
                # 老格式：归档后重新开表，避免列数不一致
                $old = Join-Path $Script:DataDir 'history-legacy.csv'
                if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
                Move-Item $Script:LogFile $old -Force
            }
        }
        if (-not (Test-Path $Script:LogFile)) {
            $header | Set-Content -Path $Script:LogFile -Encoding UTF8
        }
        $left = if ($data.Avg -gt 0) { [math]::Floor($data.Last.Remain / $data.Avg) } else { '' }
        ('{0},{1},{2},{3},{4},{5},{6}' -f (Get-Date).ToString('s'), $data.Last.Date, $data.Last.Remain, $data.Last.Used, $data.Last.Bought, $data.Avg, $left) |
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
        autostart = if ($cfg) { [bool]$cfg.autostart } else { $true }
        fastMode  = if ($cfg) { [bool]$cfg.fastMode } else { $true }
        scale     = if ($cfg -and $cfg.scale) { [double]$cfg.scale } else { 1.0 }
        hold      = if ($cfg -and $null -ne $cfg.holdSeconds) { [int]$cfg.holdSeconds } else { 20 }
        warnBelow = if ($cfg -and $null -ne $cfg.warnBelow) { [double]$cfg.warnBelow } else { 20 }
        warnMode  = 'preset'
    }
    # 值不在预设里就进"自定义"，否则用户看不到自己存的值
    if (@(20, 45, 60, 180, 0) -notcontains [int]$Script:st.hold) { $Script:st.hold = 'custom' }
    if (@(0, 10, 20, 30, 50) -notcontains [double]$Script:st.warnBelow) { $Script:st.warnMode = 'custom' }
    $Script:setupResult = $null
    $pal = Get-Palette $Script:st.theme

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="True" Topmost="True" ResizeMode="NoResize" FocusVisualStyle="{x:Null}"
        SizeToContent="Height" Width="560" WindowStartupLocation="CenterScreen"
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

      <Grid Margin="0,2,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="18"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
          <TextBlock x:Name="lblCampus" Text="校区" FontSize="10.5" Foreground="%%SUB%%" Margin="0,8,0,0"/>
          <WrapPanel x:Name="campusRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblBuilding" Text="楼栋" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="buildingRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblRoom" Text="房间号（三位，如 101）" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <TextBox x:Name="roomTb" Width="112" Height="28" Margin="0,4,0,0" HorizontalAlignment="Left" FontSize="12" Padding="8,4,8,4"
                   Background="%%INBG%%" Foreground="%%INFG%%" BorderBrush="%%INBR%%" CaretBrush="%%INFG%%" BorderThickness="1"/>

          <TextBlock x:Name="lblHotkey" Text="快捷键（点框按下组合键）" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <Grid Margin="0,4,0,0">
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

        <StackPanel Grid.Column="2">
          <TextBlock x:Name="lblTheme" Text="主题" FontSize="10.5" Foreground="%%SUB%%" Margin="0,8,0,0"/>
          <WrapPanel x:Name="themeRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblAuto" Text="开机自启（后台待命 + 热键）" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="autoRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblMem" Text="后台内存" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="memRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblScale" Text="卡片大小" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="scaleRow" Margin="0,4,0,0"/>

          <TextBlock x:Name="lblHold" Text="卡片停留（多久自动消失）" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="holdRow" Margin="0,4,0,0"/>
          <StackPanel x:Name="holdCustom" Orientation="Horizontal" Margin="0,1,0,0" Visibility="Collapsed">
            <TextBox x:Name="holdTb" Width="64" FontSize="11.5" Padding="6,4,6,5"
                     Background="%%INBG%%" Foreground="%%INFG%%" BorderBrush="%%INBR%%" BorderThickness="1"/>
            <TextBlock Text="秒（1 - 3600）" FontSize="10" Foreground="%%SUB%%" VerticalAlignment="Center" Margin="7,0,0,0"/>
          </StackPanel>

          <TextBlock x:Name="lblWarn" Text="低电量预警（低于设定值就提醒）" FontSize="10.5" Foreground="%%SUB%%" Margin="0,6,0,0"/>
          <WrapPanel x:Name="warnRow" Margin="0,4,0,0"/>
          <StackPanel x:Name="warnCustom" Orientation="Horizontal" Margin="0,1,0,0" Visibility="Collapsed">
            <TextBox x:Name="warnTb2" Width="64" FontSize="11.5" Padding="6,4,6,5"
                     Background="%%INBG%%" Foreground="%%INFG%%" BorderBrush="%%INBR%%" BorderThickness="1"/>
            <TextBlock Text="度（1 - 999）" FontSize="10" Foreground="%%SUB%%" VerticalAlignment="Center" Margin="7,0,0,0"/>
          </StackPanel>
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
        $bd.Padding      = New-Object System.Windows.Thickness(10,3,10,4)
        $bd.Margin       = New-Object System.Windows.Thickness(0,0,6,4)
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
            'autoRow'     = $(if ($Script:st.autostart) { '1' } else { '0' })
            'memRow'      = $(if ($Script:st.fastMode) { '1' } else { '0' })
            'scaleRow'    = ([double]$Script:st.scale).ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
            'holdRow'     = $(if ("$($Script:st.hold)" -eq 'custom') { 'custom' } else { [string][int]$Script:st.hold })
            'warnRow'     = $(if ("$($Script:st.warnMode)" -eq 'custom') { 'custom' } else { ([double]$Script:st.warnBelow).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture) })
        }
        foreach ($k in $rows.Keys) {
            $row = $Script:win.FindName($k)
            if (-not $row) { continue }
            foreach ($bd in $row.Children) {
                if ($bd -is [System.Windows.Controls.Border]) { Style-Pill $bd ([string]$bd.Tag -eq $rows[$k]) }
            }
        }
    }

    function Update-ModeHint {
        $pp = Get-Palette $Script:st.theme
        $on = [bool]$Script:st.autostart
        $tb = $Script:win.FindName('tipTb')
        if ($tb) {
            $tb.Text = $(if ($on) { '热键由常驻小进程接管（托盘图标右键可退出）；清空热键 = 不设热键。' } else { '已关闭自启：只有点桌面图标才查询，冷启动约 1 秒，热键不生效。' })
            $tb.Foreground = Brush ($(if ($on) { $pp.Sub } else { $pp.Err }))
        }
        foreach ($n in 'lblHotkey', 'hkTb', 'hkClear') {
            $el = $Script:win.FindName($n)
            if ($el) { $el.Opacity = $(if ($on) { 1 } else { 0.35 }) }
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
            foreach ($n in 'lblTheme','lblCampus','lblBuilding','lblRoom','lblHotkey','lblAuto','lblMem','lblScale') {
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
            Update-ModeHint
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

    # 开机自启开关
    foreach ($a in @(@('1', '开（后台待命）'), @('0', '关（只手动打开）'))) {
        $bd = New-Pill $a[1] $a[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $Script:st.autostart = ([string]$s.Tag -eq '1')
            Update-Pills
            Update-ModeHint
        })
        [void]$Script:win.FindName('autoRow').Children.Add($bd)
    }

    # 后台内存模式
    foreach ($m in @(@('1', '极速（165 MB）'), @('0', '省内存（85 MB）'))) {
        $bd = New-Pill $m[1] $m[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $Script:st.fastMode = ([string]$s.Tag -eq '1')
            Update-Pills
        })
        [void]$Script:win.FindName('memRow').Children.Add($bd)
    }

    # 卡片大小
    foreach ($s in @(@('0.85', '小'), @('1', '标准'), @('1.25', '大'))) {
        $bd = New-Pill $s[1] $s[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $Script:st.scale = [double]::Parse([string]$s.Tag, [System.Globalization.CultureInfo]::InvariantCulture)
            Update-Pills
        })
        [void]$Script:win.FindName('scaleRow').Children.Add($bd)
    }

    # 卡片停留时长（0 = 不自动关；custom = 用输入框的秒数）
    foreach ($hh in @(@('20', '20 秒'), @('45', '45 秒'), @('60', '1 分钟'), @('180', '3 分钟'), @('0', '不自动关'), @('custom', '自定义'))) {
        $bd = New-Pill $hh[1] $hh[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $v = [string]$s.Tag
            if ($v -eq 'custom') {
                $Script:st.hold = 'custom'
                $Script:win.FindName('holdCustom').Visibility = 'Visible'
                $tb = $Script:win.FindName('holdTb')
                if (-not $tb.Text) { $tb.Text = '30' }
                [void]$tb.Focus()
            } else {
                $Script:st.hold = [int]$v
                $Script:win.FindName('holdCustom').Visibility = 'Collapsed'
            }
            Update-Pills
        })
        [void]$Script:win.FindName('holdRow').Children.Add($bd)
    }

    # 低电量预警阈值（0 = 关；custom = 用输入框）
    foreach ($ww in @(@('0', '关'), @('10', '10 度'), @('20', '20 度'), @('30', '30 度'), @('50', '50 度'), @('custom', '自定义'))) {
        $bd = New-Pill $ww[1] $ww[0]
        $bd.Add_MouseLeftButtonDown({
            param($s, $e)
            $v = [string]$s.Tag
            if ($v -eq 'custom') {
                $Script:st.warnMode = 'custom'
                $Script:win.FindName('warnCustom').Visibility = 'Visible'
                $tb = $Script:win.FindName('warnTb2')
                if (-not $tb.Text) { $tb.Text = '15' }
                [void]$tb.Focus()
            } else {
                $Script:st.warnMode = 'preset'
                $Script:st.warnBelow = [double]::Parse($v, [System.Globalization.CultureInfo]::InvariantCulture)
                $Script:win.FindName('warnCustom').Visibility = 'Collapsed'
            }
            Update-Pills
        })
        [void]$Script:win.FindName('warnRow').Children.Add($bd)
    }
    # 打开时如果存的是自定义值，把输入框亮出来并填好
    if ("$($Script:st.hold)" -eq 'custom') {
        $Script:win.FindName('holdCustom').Visibility = 'Visible'
        $Script:win.FindName('holdTb').Text = [string][int]$(if ($cfg) { $cfg.holdSeconds } else { 30 })
    }
    if ("$($Script:st.warnMode)" -eq 'custom') {
        $Script:win.FindName('warnCustom').Visibility = 'Visible'
        $Script:win.FindName('warnTb2').Text = ([double]$Script:st.warnBelow).ToString('0.#', $Script:Inv)
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
        # 停留时长：预设直接用；自定义要校验 1-3600
        $holdVal = 0
        if ("$($Script:st.hold)" -eq 'custom') {
            $holdTxt = ([string]$Script:win.FindName('holdTb').Text).Trim()
            $tmp = 0
            if (-not [int]::TryParse($holdTxt, [ref]$tmp)) { $tmp = 0 }
            if ($tmp -lt 1 -or $tmp -gt 3600) {
                $err.Text = '自定义停留时间要填 1 - 3600 之间的秒数'
                $err.Visibility = 'Visible'
                return
            }
            $holdVal = $tmp
        } else {
            $holdVal = [int]$Script:st.hold
        }

        # 预警阈值：自定义要校验 1-999
        $warnVal = [double]$Script:st.warnBelow
        if ("$($Script:st.warnMode)" -eq 'custom') {
            $warnTxt2 = ([string]$Script:win.FindName('warnTb2').Text).Trim()
            $wtmp = 0
            if (-not [int]::TryParse($warnTxt2, [ref]$wtmp) -or $wtmp -lt 1 -or $wtmp -gt 999) {
                $err.Text = '自定义预警阈值要填 1 - 999 之间的度数'
                $err.Visibility = 'Visible'
                return
            }
            $warnVal = [double]$wtmp
        }

        $Script:setupResult = @{
            theme       = $Script:st.theme
            campus      = $Script:st.campus
            client      = $Script:st.client
            building    = $Script:st.building
            room        = $room
            roomId      = $roomId
            hotkey      = [string]$Script:st.hotkey
            autostart   = [bool]$Script:st.autostart
            fastMode    = [bool]$Script:st.fastMode
            scale       = [double]$Script:st.scale
            holdSeconds = $holdVal
            warnBelow   = $warnVal
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

    $warnText = ''
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
        $avgTxt = if ($data.Avg -gt 0) { [double]$data.Avg.ToString('0.##', $Script:Inv) } else { '--' }
        $sub = '数据 ' + $last.Date
        if ($data.Avg -gt 0) { $sub += ('  ·  约还可用 {0} 天' -f [math]::Floor($last.Remain / $data.Avg)) }
        if ($data.Recharge -gt 0.01) { $sub += ('  ·  刚充了 {0} 度' -f $data.Recharge.ToString('0.##', $Script:Inv)) }

        # 低电量预警：阈值按"够两晚空调"来定，默认 20 度（日均约 12 度 → 约 1.6 天）
        $wb = 0.0
        try { $wb = [double]$cfg.warnBelow } catch { }
        if ($wb -gt 0 -and $last.Remain -lt $wb) {
            $warnText = ('⚠ 电量偏低：{0} 度' -f $last.Remain.ToString('0.0', $Script:Inv))
            if ($data.Avg -gt 0) {
                $wDays = [math]::Round($last.Remain / $data.Avg, 1)
                $wTxt = $wDays.ToString('0.#', $Script:Inv)
                if ($wDays -lt 2)     { $warnText += ('，约 {0} 天，今晚的空调可能就撑不过去了' -f $wTxt) }
                elseif ($wDays -lt 4) { $warnText += ('，约 {0} 天，撑不过两晚空调' -f $wTxt) }
                else                  { $warnText += ('，约 {0} 天' -f $wTxt) }
            }
            $warnText += '。记得充值。'
        }

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
        <TextBox Text="%%REMAIN%%" IsReadOnly="True" IsTabStop="False" BorderThickness="0" Background="Transparent" Foreground="%%TITLE%%" FontSize="30" FontWeight="Light" Padding="0" CaretBrush="Transparent" SelectionBrush="%%ACCENT%%" VerticalAlignment="Center"/>
        <TextBlock Text=" 度" Foreground="%%SUB2%%" FontSize="13" VerticalAlignment="Bottom" Margin="1,0,0,7"/>
        <StackPanel Margin="22,2,0,0">
          <TextBlock Text="昨日用电" Foreground="%%SUB2%%" FontSize="10.5"/>
          <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
            <TextBox Text="%%DAY%%" IsReadOnly="True" IsTabStop="False" BorderThickness="0" Background="Transparent" Foreground="%%TITLE%%" FontSize="17" Padding="0" CaretBrush="Transparent" SelectionBrush="%%ACCENT%%"/>
            <TextBlock Text=" 度" Foreground="%%SUB2%%" FontSize="11" VerticalAlignment="Bottom" Margin="1,0,0,3"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Margin="20,2,0,0">
          <TextBlock Text="平均用电" Foreground="%%SUB2%%" FontSize="10.5"/>
          <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
            <TextBox Text="%%AVG%%" IsReadOnly="True" IsTabStop="False" BorderThickness="0" Background="Transparent" Foreground="%%TITLE%%" FontSize="17" Padding="0" CaretBrush="Transparent" SelectionBrush="%%ACCENT%%"/>
            <TextBlock Text=" 度" Foreground="%%SUB2%%" FontSize="11" VerticalAlignment="Bottom" Margin="1,0,0,3"/>
          </StackPanel>
        </StackPanel>
      </StackPanel>
      <TextBlock Text="近 5 天每日用电（度）" Foreground="%%SUB2%%" FontSize="9.5" Margin="2,10,0,0"/>
      <Canvas Width="344" Height="86" Margin="0,4,0,0">
%%CHART%%
      </Canvas>
'@
        $body = $body.Replace('%%REMAIN%%', $remainTxt).Replace('%%DAY%%', $dayTxt).Replace('%%AVG%%', $avgTxt).Replace('%%CHART%%', $chart)
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize" FocusVisualStyle="{x:Null}"
        SizeToContent="WidthAndHeight" FontFamily="Microsoft YaHei UI">
  <Border x:Name="cardRoot" CornerRadius="9" Background="%%CBG%%" BorderBrush="%%BORDER%%" BorderThickness="1" Padding="15,13,15,11">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="2" Direction="270" Opacity="%%SHADOW%%" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
%%WARN%%
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
          <Border x:Name="closeBtn" Width="22" Height="22" CornerRadius="5" Cursor="Hand" ToolTip="回车 / 点击关闭">
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
    $warnXaml = ''
    if ($warnText) {
        $we = $warnText -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
        $warnXaml = @"
      <Border CornerRadius="6" Background="%%WARNBG%%" BorderBrush="%%WARNBR%%" BorderThickness="1" Padding="9,6,9,7" Margin="0,0,0,10">
        <TextBlock Text="$we" Foreground="%%WARNFG%%" FontSize="11.5" TextWrapping="Wrap"/>
      </Border>
"@
        $warnXaml = $warnXaml.Replace('%%WARNBG%%', $p.WarnBg).Replace('%%WARNBR%%', $p.WarnBr).Replace('%%WARNFG%%', $p.Err)
    }
    $xaml = $xaml.Replace('%%WARN%%', $warnXaml)
    $xaml = $xaml.Replace('%%CBG%%', $p.CardBg).Replace('%%BORDER%%', $p.Border).Replace('%%SHADOW%%', $p.Shadow)
    $xaml = $xaml.Replace('%%ICONBG%%', $p.IconBg).Replace('%%ACCENT%%', $p.Accent).Replace('%%TITLE%%', $p.Title)
    $xaml = $xaml.Replace('%%SUB2%%', $p.Sub).Replace('%%CHIPBG%%', $p.ChipBg).Replace('%%CHIPFG%%', $p.ChipFg)
    $xaml = $xaml.Replace('%%ERR%%', $p.Err)

    # 拼一段纯文本，供右键「复制全部」和手动选中复制
    if ($errText) {
        $Script:cardPlain = $header + "`r`n" + $errText
    } else {
        $Script:cardPlain = (@(
            $header,
            ('剩余 ' + $remainTxt + ' 度'),
            ('昨日用电 ' + $dayTxt + ' 度'),
            ('平均用电 ' + $avgTxt + ' 度'),
            ($sub -replace '\s+·\s+', ' · ')
        ) -join "`r`n")
        if ($warnText) { $Script:cardPlain = $warnText + "`r`n" + $Script:cardPlain }
    }

    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    $Script:w = $w

    $cm = New-Object System.Windows.Controls.ContextMenu
    $miCopy = New-Object System.Windows.Controls.MenuItem
    $miCopy.Header = '复制全部'
    $miCopy.Add_Click({ try { SzuLog ('copy len=' + ([string]$Script:cardPlain).Length); [System.Windows.Clipboard]::SetText([string]$Script:cardPlain) } catch { SzuLog ('copy ERR: ' + $_.Exception.Message) }; try { $Script:w.Close() } catch { } })
    [void]$cm.Items.Add($miCopy)
    $w.ContextMenu = $cm

    # 卡片缩放：整体套 ScaleTransform，排版比例不变
    $scale = [double]$cfg.scale
    if (-not $scale -or $scale -le 0) { $scale = 1.0 }
    if ([math]::Abs($scale - 1.0) -gt 0.001) {
        $trans = New-Object System.Windows.Media.ScaleTransform($scale, $scale)
        $w.FindName('cardRoot').LayoutTransform = $trans
    }
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w.Opacity = 0

    $Script:isAgent = $IsAgent.IsPresent
    $Script:w.FindName('closeBtn').Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true
        $Script:w.Close()
    })
    $Script:w.FindName('gearBtn').Add_MouseLeftButtonDown({
        param($s, $e)
        $e.Handled = $true
        $Script:cardResult = 'settings'
        $Script:w.Close()
        if ($Script:isAgent) {
            # 常驻进程里没人消费 cardResult，就地开设置（不靠拉起新进程，规避“起不来就没反应”）
            try {
                $new = Show-Setup $Script:cfg
                if ($new) {
                    $Script:cfg = $new
                    Save-Config $new
                    Update-Autostart $new
                    SzuLog 'settings saved (in-process)'
                }
            } catch { SzuLog ('open setup ERR: ' + $_.Exception.Message) }
        }
    })

    $w.Add_Loaded({
        $wa2 = [System.Windows.SystemParameters]::WorkArea
        $Script:w.Left = $wa2.Right - $Script:w.ActualWidth - 16
        $Script:w.Top  = $wa2.Bottom - $Script:w.ActualHeight - 16
        if (-not $Script:suppressFade) {
            $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(120)))
            $Script:w.BeginAnimation([System.Windows.Window]::OpacityProperty, $fade)
            $Script:w.Activate()
        }
    })
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Enter' -or $e.Key -eq 'Escape' -or $e.Key -eq 'Space') { $s.Close() } })
    # 不再“点哪都关”：只认 ✕ / Enter / Esc，这样能选中数字复制

    # 计时器放脚本作用域：Show-Card 返回后局部变量会被回收，事件里再引用会炸掉常驻进程
    $Script:cardTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:cardTimer.Interval = [TimeSpan]::FromSeconds([int]$cfg.holdSeconds)
    $Script:cardTimer.Add_Tick({
        try {
            $Script:cardTimer.Stop()
            if ($Script:w -and $Script:w.IsVisible) {
                $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
                $fadeOut.Add_Completed({ try { $Script:w.Close() } catch { } })
                $Script:w.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeOut)
            }
        } catch { SzuLog ('timer ERR: ' + $_.Exception.Message) }
    })
    $Script:cardTimer.Start()
    # holdSeconds = 0 表示"不自动关"：不启动计时器，只能手动关
    if ([int]$cfg.holdSeconds -le 0) { $Script:cardTimer.Stop() }

    if ($NoBlock) {
        $w.Add_Closed({ SzuLog 'card closed'; $Script:card = $null; if ($Script:cardTimer) { $Script:cardTimer.Stop() } })
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

function Set-TrayText([string]$text) {
    # NotifyIcon.Text 硬上限 63 个字符（64 会抛"文本长度必须少于 64 个字符"）
    if (-not $Script:trayIcon) { return }
    if ($null -eq $text) { $text = '' }
    $text = ($text -replace "[\r\n]", ' ').Trim()
    if ($text.Length -gt 63) { $text = $text.Substring(0, 62) + '…' }
    try { $Script:trayIcon.Text = $text; SzuLog ('tray text(' + $text.Length + '): ' + $text) } catch { }
}

function Update-TrayText {
    $d = Read-Cache
    if (-not $d) { Set-TrayText '深大电量 · 点一下查看'; return }
    $name = ('{0} {1}' -f $Script:cfg.building, $Script:cfg.room).Trim()
    $parts = @($name, ('剩 {0} 度' -f $d.Last.Remain.ToString('0.0', $Script:Inv)))
    if ($d.Avg -gt 0) { $parts += ('约 {0} 天' -f [math]::Floor($d.Last.Remain / $d.Avg)) }
    if ($d.FetchedAt) {
        try { $parts += ('{0:HH:mm} 更新' -f [datetime]$d.FetchedAt) } catch { }
    }
    Set-TrayText ($parts -join ' · ')
}

function Show-Quick {
    try {
        # 用缓存秒开，缓存由 -Fetch 后台刷新
        SzuLog 'show-quick start'
        try { Hide-TrayMenu } catch { }
        $card = $Script:card
        if ($card) { try { $card.Close() } catch { SzuLog ('close old ERR: ' + $_.Exception.Message) } }
        $Script:card = $null
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
        SzuLog ('card shown: ' + [bool]$Script:card)
        # 只在缓存超过 6 小时时补一次；电控一天才更新一次，没必要频繁联网
        $ttl = 6 * 3600
        $fresh = $false
        if ($data -and $data.FetchedAt) {
            try { $fresh = (((Get-Date) - [datetime]$data.FetchedAt).TotalSeconds -lt $ttl) } catch { }
        }
        if (-not $fresh) { Start-Prefetch }
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

# ============================ 自绘托盘菜单 ============================
# 系统 ContextMenuStrip 太丑。自绘 WPF 的老问题是"托盘弹窗抢不到前台焦点 → Deactivated 不触发 →
# 菜单浮在桌面上关不掉"。这里换成不依赖焦点的做法：窗口不激活（WS_EX_NOACTIVATE），
# 用低级鼠标/键盘钩子判断"点在外面就关"，并且像原生菜单一样把那一击吞掉。

if (-not ('SzuMenuHook' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class SzuMenuHook
{
    delegate IntPtr LLProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left; public int top; public int right; public int bottom; }

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, LLProc cb, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

    static LLProc _mouseCb, _keyCb;
    static IntPtr _mouseHook = IntPtr.Zero, _keyHook = IntPtr.Zero;

    public static Func<int, int, int, bool> OnClick;
    public static Func<int, bool> OnKey;

    static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = (int)wParam;
            if (msg == 0x0201 || msg == 0x0204 || msg == 0x0207)
            {
                var st = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                var cb = OnClick;
                if (cb != null && cb(msg, st.pt.x, st.pt.y)) return (IntPtr)1;
            }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    static IntPtr KeyProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && (int)wParam == 0x0100)
        {
            var st = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            var cb = OnKey;
            if (cb != null && cb((int)st.vkCode)) return (IntPtr)1;
        }
        return CallNextHookEx(_keyHook, nCode, wParam, lParam);
    }

    public static bool Install()
    {
        _mouseCb = MouseProc;
        _keyCb = KeyProc;
        _mouseHook = SetWindowsHookEx(14, _mouseCb, IntPtr.Zero, 0);   // WH_MOUSE_LL
        _keyHook = SetWindowsHookEx(13, _keyCb, IntPtr.Zero, 0);       // WH_KEYBOARD_LL
        return _mouseHook != IntPtr.Zero && _keyHook != IntPtr.Zero;
    }

    public static void Uninstall()
    {
        if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
        if (_keyHook != IntPtr.Zero) { UnhookWindowsHookEx(_keyHook); _keyHook = IntPtr.Zero; }
    }

    public static void MakeNoActivate(IntPtr hWnd)
    {
        int ex = GetWindowLong(hWnd, -20);
        SetWindowLong(hWnd, -20, ex | 0x08000000);                     // WS_EX_NOACTIVATE
        SetWindowPos(hWnd, (IntPtr)(-1), 0, 0, 0, 0, 0x0010 | 0x0001 | 0x0002);  // TOPMOST | NOACTIVATE | NOSIZE | NOMOVE
        // 坑：SWP_NOMOVE 是 0x0002，SWP_NOZORDER 才是 0x0004。写成 0x0004 就没禁掉移动，窗口每次被挪到 (0,0)。
    }

    // 说明：溢出面板不去动它。真机看过别的软件（小米云服务），在面板里右键图标时面板是不收的，
    // 菜单直接压在图标旁边弹出来 —— 收面板反而跟系统不一致。

    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder sb, int nMax);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    // 悬停提示会糊在菜单上。Win11 托盘的提示不是老式 tooltips_class32，而是
    // Xaml_WindowedPopupClass（标题"主机弹出窗口"）——两个类都要收；鼠标再动一下它自己会重弹。
    public static int HideTooltips()
    {
        int n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            var sb = new System.Text.StringBuilder(256);
            GetClassName(h, sb, 256);
            string c = sb.ToString();
            if ((c == "tooltips_class32" || c == "Xaml_WindowedPopupClass") && IsWindowVisible(h)) { ShowWindow(h, 0); n++; }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    public static bool ContainsScreenPoint(IntPtr hWnd, int x, int y)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return false;
        return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    }
}
'@
}

function Get-MenuPalette {
    if ((Get-EffectiveTheme $Script:cfg.theme) -eq 'light') {
        return @{ Bg = '#F8FFFFFF'; Border = '#24000000'; Fg = '#E4000000'; Hover = '#0F000000'; Sep = '#14000000'; Shadow = 0.20 }
    }
    @{ Bg = '#F52B2B2B'; Border = '#26FFFFFF'; Fg = '#FFFFFFFF'; Hover = '#1CFFFFFF'; Sep = '#1FFFFFFF'; Shadow = 0.55 }
}

function Hide-TrayMenu {
    try { [SzuMenuHook]::Uninstall() } catch { }
    $Script:menuHookOn = $false
    try { if ($Script:menuTopTimer) { $Script:menuTopTimer.Stop() } } catch { }
    $w = $Script:menuWin
    if ($w) {
        try { if ($w.IsVisible) { $w.Hide() } } catch { }
        foreach ($n in @('rowOpen', 'rowSetup', 'rowFix', 'rowQuit')) {
            try { $w.FindName($n).Background = (Brush '#00000000') } catch { }
        }
    }
}

function Build-TrayMenu {
    if (-not ('System.Windows.Window' -as [type])) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    }
    $p = Get-MenuPalette
    $accent = (Get-Palette $Script:cfg.theme).Accent
    $Script:menuHover = $p.Hover
    # 记下这份配色是按哪套主题画的；主题一换就要重建窗口（见 Show-TrayMenu）
    $Script:menuPaletteKey = Get-EffectiveTheme $Script:cfg.theme

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" Focusable="False"
        SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Border x:Name="shell" Margin="12" CornerRadius="10" Background="%%MBG%%" BorderBrush="%%MBORDER%%" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Direction="270" Opacity="%%SHADOW%%" Color="#000000"/>
    </Border.Effect>
    <StackPanel Margin="5" Width="166">
      <Border x:Name="rowOpen" CornerRadius="7" Background="Transparent" Padding="9,8,9,8">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#x26A1;" FontSize="12" Width="21" Foreground="%%ACCENT%%" VerticalAlignment="Center"/>
          <TextBlock Text="查看电量" FontSize="13" Foreground="%%FG%%" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
      <Border x:Name="rowSetup" CornerRadius="7" Background="Transparent" Padding="9,8,9,8">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#x2699;" FontSize="12" Width="21" Foreground="%%ACCENT%%" VerticalAlignment="Center"/>
          <TextBlock Text="设置…" FontSize="13" Foreground="%%FG%%" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
      <Border Height="1" Background="%%SEP%%" Margin="9,5,9,5"/>
      <Border x:Name="rowFix" CornerRadius="7" Background="Transparent" Padding="9,8,9,8">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#x2692;" FontSize="12" Width="21" Foreground="%%ACCENT%%" VerticalAlignment="Center"/>
          <TextBlock Text="修复快捷方式" FontSize="13" Foreground="%%FG%%" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
      <Border x:Name="rowQuit" CornerRadius="7" Background="Transparent" Padding="9,8,9,8">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#x23FB;" FontSize="12" Width="21" Foreground="%%ACCENT%%" VerticalAlignment="Center"/>
          <TextBlock Text="退出常驻" FontSize="13" Foreground="%%FG%%" VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@
    $xaml = $xaml.Replace('%%MBG%%', $p.Bg).Replace('%%MBORDER%%', $p.Border)
    $xaml = $xaml.Replace('%%FG%%', $p.Fg).Replace('%%SEP%%', $p.Sep)
    $xaml = $xaml.Replace('%%SHADOW%%', $p.Shadow).Replace('%%ACCENT%%', $accent)

    $w = [Windows.Markup.XamlReader]::Parse($xaml)
    foreach ($n in @('rowOpen', 'rowSetup', 'rowFix', 'rowQuit')) {
        $row = $w.FindName($n)
        $row.Add_MouseEnter({ param($s, $e) try { $s.Background = (Brush $Script:menuHover) } catch { } })
        $row.Add_MouseLeave({ param($s, $e) try { $s.Background = (Brush '#00000000') } catch { } })
    }

    $w.FindName('rowOpen').Add_MouseLeftButtonUp({ Hide-TrayMenu; Show-Quick })
    $w.FindName('rowSetup').Add_MouseLeftButtonUp({
        Hide-TrayMenu
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $Script:Ps1 + '"'), '-Setup') -WindowStyle Hidden
    })
    $w.FindName('rowFix').Add_MouseLeftButtonUp({
        Hide-TrayMenu
        try { [void](New-DesktopShortcut); if ($Script:cfg) { Update-Autostart $Script:cfg } }
        catch { SzuLog ('repair ERR: ' + $_.Exception.Message) }
    })
    $w.FindName('rowQuit').Add_MouseLeftButtonUp({
        Hide-TrayMenu
        try { $Script:trayIcon.Visible = $false; $Script:trayIcon.Dispose() } catch { }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    })
    return $w
}

function Set-TrayMenuPosition($w) {
    # WorkArea 在窗口还没建好时可能返回空矩形（踩过：菜单跑到左上角）
    $wa = [System.Windows.SystemParameters]::WorkArea
    $scale = 1.0
    try { $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($w).DpiScaleX } catch { }
    if ($scale -le 0) { $scale = 1.0 }
    if (-not $wa -or $wa.Width -le 0 -or $wa.Height -le 0) {
        $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $wa = New-Object System.Windows.Rect(($scr.X / $scale), ($scr.Y / $scale), ($scr.Width / $scale), ($scr.Height / $scale))
    }

    # 锚在鼠标点（也就是被右键的那个图标）上：面板右缘贴光标右侧、底边压光标上方，跟原生菜单一个方向
    $pad = 12.0   # 窗口给阴影留的外边距，不算进"面板"尺寸
    $pos = [System.Windows.Forms.Cursor]::Position
    $cx = $pos.X / $scale
    $cy = $pos.Y / $scale

    $left = $cx + 10 - ($w.ActualWidth - $pad)
    $top = $cy - 10 - ($w.ActualHeight - $pad)

    $minL = $wa.Left + 4
    $maxL = $wa.Right - $w.ActualWidth - 4
    $minT = $wa.Top + 4
    $maxT = $wa.Bottom - $w.ActualHeight - 4
    if ($left -gt $maxL) { $left = $maxL }
    if ($left -lt $minL) { $left = $minL }
    if ($top -gt $maxT) { $top = $maxT }
    if ($top -lt $minT) { $top = $minT }

    $w.Left = [math]::Round($left)
    $w.Top = [math]::Round($top)
    SzuLog ('menu at ' + $w.Left + ',' + $w.Top + ' cursor=' + $cx + ',' + $cy + ' scale=' + $scale)
}

function Show-TrayMenu {
    try {
        # 主题（深/浅/跟随系统）一换，旧窗口的配色就是死的 —— 直接丢掉重建
        $want = Get-EffectiveTheme $Script:cfg.theme
        if ($Script:menuWin -and $Script:menuPaletteKey -ne $want) {
            try { Hide-TrayMenu } catch { }
            try { $Script:menuWin.Close() } catch { }
            $Script:menuWin = $null
        }
        if (-not $Script:menuWin) { $Script:menuWin = Build-TrayMenu }
        $w = $Script:menuWin
        if (-not $w.IsVisible) {
            # 不动溢出面板：真机看过别的软件（小米云服务），右键图标时面板是不收的，菜单直接压在图标旁边
            $w.Left = -6000
            $w.Top = -6000
            $w.Show()
            # 布局跑完再定位，否则 ActualWidth 还是 0
            $w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action] { Set-TrayMenuPosition $Script:menuWin }) | Out-Null
        }

        $h = (New-Object System.Windows.Interop.WindowInteropHelper($w)).Handle
        $Script:menuHwnd = $h
        [SzuMenuHook]::MakeNoActivate($h)

        if (-not $Script:menuHookOn) {
            [SzuMenuHook]::OnClick = {
                param($msg, $x, $y)
                $m = $Script:menuWin
                if (-not $m -or -not $m.IsVisible) { return $false }
                if ([SzuMenuHook]::ContainsScreenPoint($Script:menuHwnd, $x, $y)) { return $false }
                $m.Dispatcher.BeginInvoke([action] { Hide-TrayMenu }) | Out-Null
                return $true
            }
            [SzuMenuHook]::OnKey = {
                param($vk)
                $m = $Script:menuWin
                if ($vk -eq 27 -and $m -and $m.IsVisible) {
                    $m.Dispatcher.BeginInvoke([action] { Hide-TrayMenu }) | Out-Null
                    return $true
                }
                return $false
            }
            $Script:menuHookOn = [SzuMenuHook]::Install()
            SzuLog ('menu hooks installed: ' + $Script:menuHookOn)
        }

        # 悬停提示（tooltip）是后出现的 topmost 窗口，会压在菜单上；常驻抬一下顶，把菜单重新提到最前
        if (-not $Script:menuTopTimer) {
            $Script:menuTopTimer = New-Object System.Windows.Threading.DispatcherTimer
            $Script:menuTopTimer.Interval = [TimeSpan]::FromMilliseconds(250)
            $Script:menuTopTimer.Add_Tick({
                try {
                    $m = $Script:menuWin
                    if ($m -and $m.IsVisible -and $Script:menuHwnd -ne [IntPtr]::Zero) {
                        [void][SzuMenuHook]::HideTooltips()
                        [SzuMenuHook]::MakeNoActivate($Script:menuHwnd)
                    } else {
                        $Script:menuTopTimer.Stop()
                    }
                } catch { try { $Script:menuTopTimer.Stop() } catch { } }
            })
        }
        $Script:menuTopTimer.Start()

        SzuLog 'show tray menu'
    } catch {
        SzuLog ('Show-TrayMenu ERR: ' + $_.Exception.Message)
    }
}

function Run-Agent {
    # 只有托盘/热键必需的东西：WPF 留给卡片按需加载（它占 80 MB）
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, WindowsBase

    $created = $false
    try { $Script:mutex = New-Object System.Threading.Mutex($true, $Script:MutexName, [ref]$created) } catch { return }
    if (-not $created) { return }

    $cfg = Read-Config
    if (-not $cfg) { return }
    # 关了自启 / 没设热键 → 不该常驻
    if (-not $cfg.autostart -or -not $cfg.hotkey) { SzuLog 'agent: autostart off -> not running'; return }
    $Script:cfg = $cfg
    $Script:card = $null
    $Script:prefetching = $false

    # ---- 托盘 ----
    $ni = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path $Script:Icon) { $ni.Icon = New-Object System.Drawing.Icon($Script:Icon) }
    else { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    $ni.Text = '深大电量'
    $ni.Visible = $true

    # 右键 → 自绘菜单（不再挂 ContextMenuStrip；见文件上方「自绘托盘菜单」）
    $ni.Add_MouseUp({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-TrayMenu }
    })
    $ni.Add_MouseDoubleClick({ Show-Quick })
    $Script:trayIcon = $ni
    Update-TrayText

    # ---- 全局热键 ----
    if (-not ('SzHotkey' -as [type])) {
        Add-Type -TypeDefinition $Script:HotkeyCs -ReferencedAssemblies 'System.Windows.Forms','System.Drawing'
    }
    $hip = New-Object SzHotkey
    $hip.Add_Pressed({ SzuLog 'hotkey fired'; Show-Quick })

    function Apply-Hotkey($c) {
        $spec = Get-HotkeySpec $c.hotkey
        $hip.Unregister()
        if ($spec) {
            $ok = $hip.Register($spec.Mods, $spec.Vk)
            SzuLog ("register hotkey {0} -> {1}" -f $c.hotkey, $ok)
        }
    }
    Apply-Hotkey $cfg

    # 不做定时联网：电控系统一天只更新一次，定时拉纯浪费。
    # 改为“打开卡片时看缓存年龄，超过 6 小时才在后台补一次”（见 Show-Quick）

    # 时间戳必须放 script 作用域：写在 Run-Agent 局部时，计时器回调里的赋值只活一次，
    # 于是"配置文件变了吗"永远为真 → 每 2 秒重载一次配置、重注册一次热键（踩过）
    $Script:cfgStamp = (Get-Item $Script:CfgFile).LastWriteTime
    $Script:cacheStamp = if (Test-Path $Script:CacheFile) { (Get-Item $Script:CacheFile).LastWriteTime } else { $null }
    $tWatch = New-Object System.Windows.Threading.DispatcherTimer
    $tWatch.Interval = [TimeSpan]::FromSeconds(2)
    $tWatch.Add_Tick({
        $f = Get-Item $Script:CfgFile -ErrorAction SilentlyContinue
        if ($f -and $f.LastWriteTime -ne $Script:cfgStamp) {
            $Script:cfgStamp = $f.LastWriteTime
            $c = Read-Config
            if ($c) {
                $Script:cfg = $c
                # 用户在设置里关掉自启（或清空热键）→ 常驻自己退场，不靠外部进程来杀
                if (-not $c.autostart -or -not $c.hotkey) {
                    SzuLog 'config: autostart off / no hotkey -> shutdown'
                    try { $ni.Visible = $false; $ni.Dispose() } catch { }
                    $hip.Unregister()
                    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                    return
                }
                Apply-Hotkey $c
                SzuLog 'config reloaded'
            }
        }
        # 预取进程写完缓存 → 顺手更新托盘提示
        $cf = Get-Item $Script:CacheFile -ErrorAction SilentlyContinue
        if ($cf -and $cf.LastWriteTime -ne $Script:cacheStamp) {
            $Script:cacheStamp = $cf.LastWriteTime
            Update-TrayText
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

    # 极速模式：预加载 WPF 并预热一张透明卡片（首次按热键不用等）
    # 省内存模式：不碰 WPF，常驻只保留热键和托盘；第一次按热键时再加载
    if ($Script:cfg.fastMode) {
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $cd = Read-Cache
            if ($cd) {
                $ww = Show-Card $cd $Script:cfg $null -NoBlock -Warm
                Start-Sleep -Milliseconds 250
                $ww.Close()
                $Script:card = $null
            }
            SzuLog 'fast mode: WPF preloaded'
        } catch { SzuLog ('warm ERR: ' + $_.Exception.Message) }
    } else {
        SzuLog 'low-mem mode: WPF on demand'
    }

    # 低电量预警：常驻启动后（开机自启最常见）如果剩余已低于阈值，主动弹一次
    try {
        $wb0 = [double]$Script:cfg.warnBelow
        if ($wb0 -gt 0) {
            $c0 = Read-Cache
            if ($c0 -and [double]$c0.Last.Remain -lt $wb0) {
                SzuLog ('low power at start: ' + $c0.Last.Remain)
                $disp0 = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
                [void]$disp0.BeginInvoke([action]{ Show-Quick })
            } else { SzuLog 'power OK at start' }
        }
    } catch { SzuLog ('startup warn ERR: ' + $_.Exception.Message) }

    [System.Windows.Threading.Dispatcher]::Run()
}

# ============================ 入口 ============================

$Script:Ps1 = $MyInvocation.MyCommand.Path

if ($Repair) {
    $c = Read-Config
    Repair-Shortcuts $c
    exit 0
}

if ($Console) {
    $cfg = Read-Config
    if (-not $cfg) { Write-Output '还没有配置：先跑一次不带 -Console 的图形界面完成设置。'; exit 1 }
    $d = Get-PowerData $cfg
    Write-Output ('校区：{0}  {1}  {2}' -f $cfg.campus, $cfg.building, $cfg.room)
    Write-Output ('剩余电量：{0} 度' -f $d.Last.Remain.ToString('0.00', $Script:Inv))
    if ($null -ne $d.DayUse) { Write-Output ('昨日用电：{0} 度' -f $d.DayUse.ToString('0.##', $Script:Inv)) }
    Write-Output ('平均用电：{0} 度（近 {1} 天样本）' -f $d.Avg.ToString('0.##', $Script:Inv), $d.AvgDays)
    if ($d.Avg -gt 0) { Write-Output ('约还可用：{0} 天' -f [math]::Floor($d.Last.Remain / $d.Avg)) }
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

if ($Demo) {
    # 演示数据：给 README 出图用，不含任何真实房间和读数
    $fake = [pscustomobject]@{
        Last  = [pscustomobject]@{ Remain = 88.60; Used = 1024.50; Bought = 1113.10; Date = '2026-10-23' }
        Prev  = $null
        Series = @(
            [pscustomobject]@{ Label = '10-19'; Value = 9.4 },
            [pscustomobject]@{ Label = '10-20'; Value = 6.8 },
            [pscustomobject]@{ Label = '10-21'; Value = 8.2 },
            [pscustomobject]@{ Label = '10-22'; Value = 5.9 },
            [pscustomobject]@{ Label = '10-23'; Value = 7.2 }
        )
        DayUse = 7.20; Recharge = 0; Avg = 7.50; AvgDays = 31; Days = 32; RoomId = '0'
    }
    $demoCfg = @{ theme = 'dark'; campus = '南校区'; building = '冬筑3-6楼'; room = '101'; hotkey = ''; holdSeconds = 8 }
    [void](Show-Card $fake $demoCfg $null)
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






































