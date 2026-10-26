# 深大电量 · 卸载
# 说明：这个程序不写注册表、不装服务、不建计划任务。
# 它只留下四类东西：快捷方式、启动项、配置目录、临时日志。
# 本脚本把任何版本留下的这些都清干净（含早期叫「深大电量查询」的老版本）。
#
# 用法：
#   卸载.bat            交互式卸载
#   卸载.bat /check     只看会删什么，不动手

param([switch]$Check)

$ErrorActionPreference = 'SilentlyContinue'
$script:found = @()

function Add-Found([string]$kind, [string]$path, [scriptblock]$remover) {
    $script:found += [pscustomobject]@{ Kind = $kind; Path = $path; Remove = $remover }
}

function Write-Head {
    Write-Host ''
    Write-Host '  深大电量 · 卸载' -ForegroundColor White
    Write-Host '  ────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  这个程序不写注册表、不装服务、不建计划任务。' -ForegroundColor DarkGray
    Write-Host '  它只留下下面这些文件，卸载就是删它们。' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------- 1. 常驻进程 ----------
function Get-AgentPids {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*-Agent*' -and $_.CommandLine -like '*szu-power*' } |
        Select-Object -ExpandProperty ProcessId
}

# ---------- 2. 快捷方式 ----------
function Get-SzuShortcuts {
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    )
    $ws = New-Object -ComObject WScript.Shell
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($f in Get-ChildItem $d -Filter '*.lnk') {
            $t = ''
            try { $t = $ws.CreateShortcut($f.FullName).TargetPath } catch { }
            # 名字像、或者指向 szu-power 的，都算
            if ($f.Name -match '深大|电量' -or $t -match 'szu-power|深大电量') {
                # 别误删别的项目（比如 szu-uooc.lnk 是另一件事）
                if ($t -match 'szu-uooc|uooc') { continue }
                $f.FullName
            }
        }
    }
}

# ---------- 3. 注册表 Run（老版本可能有）----------
function Get-RunValues {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path $key)) { return @() }
    $p = Get-ItemProperty $key
    $hit = @()
    foreach ($n in $p.PSObject.Properties.Name) {
        if ($n -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
        if ($n -match '深大|电量|szu-power') { $hit += $n }
    }
    $hit
}

# ---------- 4. 计划任务（老版本可能有）----------
function Get-SzuTasks {
    try {
        Get-ScheduledTask | Where-Object { $_.TaskName -match '深大|电量|szu-power' } |
            Select-Object -ExpandProperty TaskName
    } catch { @() }
}

# ---------- 收集 ----------
Write-Head

$pids = @(Get-AgentPids)
if ($pids.Count -gt 0) {
    Add-Found '常驻进程' ("PID " + ($pids -join ', ')) {
        foreach ($p in $pids) { Stop-Process -Id $p -Force }
    }
}

foreach ($s in @(Get-SzuShortcuts)) {
    $path = $s
    Add-Found '快捷方式' $path { Remove-Item -LiteralPath $path -Force }
}

foreach ($v in @(Get-RunValues)) {
    $name = $v
    Add-Found '注册表自启' ('HKCU\...\Run\' + $name) {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -Force
    }
}

foreach ($t in @(Get-SzuTasks)) {
    $tn = $t
    Add-Found '计划任务' $tn { Unregister-ScheduledTask -TaskName $tn -Confirm:$false }
}

$dataDir = Join-Path $env:LOCALAPPDATA 'szu-power'
if (Test-Path $dataDir) {
    Add-Found '配置与缓存' $dataDir { Remove-Item -LiteralPath $dataDir -Recurse -Force }
}

foreach ($f in @('szu-log.txt', 'szu-crash.txt', 'szu-setup-diag.txt')) {
    $p = Join-Path $env:TEMP $f
    if (Test-Path $p) { Add-Found '临时文件' $p { Remove-Item -LiteralPath $p -Force } }
}

# ---------- 展示 ----------
if ($script:found.Count -eq 0) {
    Write-Host '  没找到任何残留，已经是干净的了。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  如果程序文件夹还在，直接删掉就行。' -ForegroundColor DarkGray
    if ($Check) { exit 0 }
    Read-Host '  按回车退出'
    exit 0
}

Write-Host ('  找到 {0} 处痕迹：' -f $script:found.Count) -ForegroundColor Yellow
Write-Host ''
$i = 1
foreach ($it in $script:found) {
    Write-Host ('   {0}. {1}' -f $i, $it.Kind) -ForegroundColor Gray -NoNewline
    Write-Host ('   ' + $it.Path) -ForegroundColor White
    $i++
}
Write-Host ''

if ($Check) {
    Write-Host '  以上是 /check 模式：什么都没删。' -ForegroundColor Green
    Write-Host '  真卸载就双击 卸载.bat。' -ForegroundColor DarkGray
    exit 0
}

$ans = Read-Host '  确认全部删除？(y = 删除，其他 = 取消)'
if ($ans -notmatch '^(y|Y|yes)$') {
    Write-Host '  已取消。' -ForegroundColor DarkGray
    Read-Host '  按回车退出'
    exit 0
}

# 配置要不要留？单独问一句
$keepCfg = $false
if (Test-Path $dataDir) {
    $a2 = Read-Host '  配置文件（校区/楼栋/房间号/热键）也一起删？(y = 删掉，其他 = 保留配置只删缓存)'
    if ($a2 -notmatch '^(y|Y|yes)$') {
        $keepCfg = $true
        # 只删缓存与流水，保留 config.json
        Remove-Item (Join-Path $dataDir 'cache.json') -Force
        Remove-Item (Join-Path $dataDir 'history.csv') -Force
        Remove-Item (Join-Path $dataDir 'history-legacy.csv') -Force
        Remove-Item (Join-Path $dataDir 'show.flag') -Force
        Write-Host '  已保留 config.json，只清了缓存。' -ForegroundColor DarkGray
    }
}

# ---------- 执行 ----------
Write-Host ''
foreach ($it in $script:found) {
    if ($keepCfg -and $it.Kind -eq '配置与缓存') { continue }
    try {
        & $it.Remove
        Write-Host ('  [删掉] {0}' -f $it.Path) -ForegroundColor Green
    } catch {
        Write-Host ('  [失败] {0}  {1}' -f $it.Path, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '  卸载完成。' -ForegroundColor Green
Write-Host ''
Write-Host '  最后一步：程序文件夹本身要不要一起删？' -ForegroundColor DarkGray
Write-Host ('    ' + (Split-Path -Parent $PSCommandPath)) -ForegroundColor DarkGray
$a3 = Read-Host '  删除整个程序目录？(y = 删，其他 = 自己手动删)'
if ($a3 -match '^(y|Y|yes)$') {
    $dir = Split-Path -Parent $PSCommandPath
    # 自己删自己会失败，交给一个延迟启动的 cmd 来干
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'timeout /t 2 >nul & rd /s /q "' + $dir + '"' -WindowStyle Hidden
    Write-Host '  已安排删除，窗口关掉后就没了。' -ForegroundColor Green
    Start-Sleep -Milliseconds 300
    exit 0
}

Write-Host ''
Read-Host '  按回车退出'
