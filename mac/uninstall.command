#!/bin/bash
# 深大电量 · Mac 版卸载
#
# 说明：这个程序不写系统级配置、不装守护进程。
# 它在 macOS 上只留四类东西：
#   1. 登录项（~/Library/LaunchAgents/com.hongsawd.szupower.plist）
#   2. 配置与缓存（~/Library/Application Support/szu-power）
#   3. 偏好设置域（com.hongsawd.szupower，NSUserDefaults）
#   4. app 本体（深大电量.app）
#
# 用法：
#   ./uninstall.command            交互式卸载
#   ./uninstall.command --check    只看会删什么，不动手

set -uo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

APP_NAME="深大电量"
BUNDLE_ID="com.hongsawd.szupower"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
DATA="$HOME/Library/Application Support/szu-power"
PREF="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CACHE="$HOME/Library/Caches/$BUNDLE_ID"
HERE="$(cd "$(dirname "$0")" && pwd)"

CANDIDATES=(
  "$HERE/$APP_NAME.app"
  "/Applications/$APP_NAME.app"
  "$HOME/Applications/$APP_NAME.app"
)

bold=$(tput bold 2>/dev/null || true)
dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true)
grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true)
rst=$(tput sgr0 2>/dev/null || true)

echo
echo "  ${bold}深大电量 · Mac 版卸载${rst}"
echo "  ────────────────────────────────────────"
echo "  ${dim}不写系统级配置、不装守护进程。只留下面这几样文件。${rst}"
echo

FOUND_KIND=()
FOUND_PATH=()

add() { FOUND_KIND+=("$1"); FOUND_PATH+=("$2"); }

# 进程
PIDS="$(pgrep -f "SzuPower" 2>/dev/null | tr '\n' ' ' || true)"
[ -n "${PIDS// /}" ] && add "运行中的进程" "PID ${PIDS}"

# 登录项
[ -f "$PLIST" ] && add "登录项 plist" "$PLIST"

# 数据 / 缓存 / 偏好
[ -d "$DATA" ]  && add "配置与缓存" "$DATA"
[ -f "$PREF" ]  && add "偏好设置" "$PREF"
[ -d "$CACHE" ] && add "缓存目录" "$CACHE"

# app 本体
APP_PATH=""
for p in "${CANDIDATES[@]}"; do
  if [ -d "$p" ]; then add "程序本体" "$p"; APP_PATH="$p"; break; fi
done

if [ ${#FOUND_PATH[@]} -eq 0 ]; then
  echo "  ${grn}没找到任何残留，已经是干净的了。${rst}"
  echo
  [ $CHECK -eq 0 ] && read -r -p "  按回车退出" _
  exit 0
fi

echo "  ${ylw}找到 ${#FOUND_PATH[@]} 处痕迹：${rst}"
echo
i=1
for idx in "${!FOUND_PATH[@]}"; do
  printf "   %d. %-14s %s\n" "$i" "${FOUND_KIND[$idx]}" "${FOUND_PATH[$idx]}"
  i=$((i + 1))
done
echo

if [ $CHECK -eq 1 ]; then
  echo "  ${grn}以上是 --check 模式：什么都没删。${rst}"
  echo "  ${dim}真卸载就双击 uninstall.command。${rst}"
  exit 0
fi

read -r -p "  确认全部删除？(y = 删除，其他 = 取消) " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "  已取消。"; exit 0 ;;
esac

# 配置要不要留
KEEP_CFG=0
if [ -d "$DATA" ]; then
  read -r -p "  配置文件（校区/楼栋/房间号/热键）也一起删？(y = 删，其他 = 保留) " a2
  case "$a2" in
    y|Y|yes|YES) ;;
    *) KEEP_CFG=1 ;;
  esac
fi

echo
# 1. 停进程
if [ -n "${PIDS// /}" ]; then
  pkill -f "SzuPower" 2>/dev/null
  echo "  ${grn}[停掉]${rst} 进程 ${PIDS}"
fi

# 2. 卸登录项
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null
  rm -f "$PLIST" && echo "  ${grn}[删掉]${rst} $PLIST"
fi
# 万一还有残留的 job
launchctl remove "$BUNDLE_ID" 2>/dev/null || true

# 3. 偏好设置
if [ -f "$PREF" ]; then
  defaults delete "$BUNDLE_ID" 2>/dev/null
  rm -f "$PREF" && echo "  ${grn}[删掉]${rst} $PREF"
fi

# 4. 缓存
if [ -d "$CACHE" ]; then
  rm -rf "$CACHE" && echo "  ${grn}[删掉]${rst} $CACHE"
fi

# 5. 数据
if [ -d "$DATA" ]; then
  if [ $KEEP_CFG -eq 1 ]; then
    rm -f "$DATA/cache.json" "$DATA/history.csv" 2>/dev/null
    echo "  ${dim}已保留 config.json，只清了缓存${rst}"
  else
    rm -rf "$DATA" && echo "  ${grn}[删掉]${rst} $DATA"
  fi
fi

echo
echo "  ${grn}卸载完成。${rst}"

# 6. app 本体
if [ -n "$APP_PATH" ]; then
  echo
  read -r -p "  程序本体也一起删？$APP_PATH (y = 删) " a3
  case "$a3" in
    y|Y|yes|YES)
      if rm -rf "$APP_PATH" 2>/dev/null; then
        echo "  ${grn}[删掉]${rst} $APP_PATH"
      else
        echo "  ${red}[失败]${rst} 权限不够，试着：sudo rm -rf \"$APP_PATH\""
      fi
      ;;
    *) echo "  ${dim}保留：$APP_PATH${rst}" ;;
  esac
fi

echo
read -r -p "  按回车退出" _
