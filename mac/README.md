# 深大电量 · Mac 版

Windows 版是 PowerShell + WPF，macOS 上没有这两样东西，所以这版是**重新写的一个原生菜单栏程序**（Swift / AppKit + SwiftUI），数据接口和口径跟 Windows 版完全一致。

## 构建

需要 macOS 11+ 和 Xcode Command Line Tools（`xcode-select --install`，不用装完整 Xcode）。

```bash
cd mac
./build.sh
```

产物是同目录的 `深大电量.app`。双击运行，菜单栏会出现一个 ⚡。

```bash
open 深大电量.app          # 启动
```

## 怎么验证它真的能用

这台开发机是 Windows，所以分两层验：

1. **能不能编译、解析逻辑对不对** —— 交给 GitHub Actions 的 macOS runner：
   `./build.sh` 里内建了 `--selftest`，用一段固定的 HTML 片段检查表格解析、GBK 编码、预警判定。
   看 Actions 页面里 `macOS build` 那次运行的日志，出现 `ALL PASS` 就是通过。
2. **连不连得上电控** —— 只有真机 + 校园网能验。手机上开热点或用校园网，点开卡片看有没有数字。

手动跑自检：

```bash
./深大电量.app/Contents/MacOS/SzuPower --selftest
```

## 和 Windows 版的差异

| 项 | Windows 版 | Mac 版 |
|---|---|---|
| 形态 | 右下角浮出卡片 + 托盘 | 菜单栏图标 + 弹出面板 |
| 全局热键 | RegisterHotKey | Carbon `RegisterEventHotKey`（同样支持 Ctrl/Alt/Shift/Command 组合） |
| 开机自启 | 启动目录快捷方式 | `~/Library/LaunchAgents` 的 plist |
| 主题 | 深/浅/跟随系统 | 同（跟随系统用 `NSApp.effectiveAppearance`） |
| 卡片大小三档 | 有 | 暂无（固定宽度 340） |
| 低电量预警 | 有，只粘一次 | 同，记账在 `warnAckDate` / `warnAckRemain` |
| 停留时间 | 20s/45s/60s/180s/不关/自定义 | 20/45/60/180/不关（可步进微调） |
| 历史流水 | `history.csv` | 暂无 |

## 配置文件

跟 Windows 版分开存，互不干扰：

```
~/Library/Application Support/szu-power/config.json
```

首次启动如果没有配置，会弹出设置窗口。也可以手动写：

```json
{
  "theme": "dark",
  "campus": "南校区",
  "client": "192.168.84.110",
  "building": "冬筑3-6楼",
  "room": "520",
  "hotkey": "CTRL + ALT + E",
  "autostart": true,
  "holdSeconds": 20,
  "warnBelow": 20
}
```

## 已知限制

- **必须连校园网**：`192.168.84.3` 是校内地址，外网访问不到（跟 Windows 版一样）。
- **首次打开会被 Gatekeeper 拦**：没有签名和公证，右键 →「打开」，或 `xattr -dr com.apple.quarantine 深大电量.app`。
- 服务端一次最多回 20 条记录，所以仍然分两段抓（近 20 天 + 再往前 15 天）。
- 没有历史流水文件，只有最近一次缓存；Windows 版有的 `history.csv` 这版还没做。


