@echo off
rem 深大水量电量查询 —— 卸载
rem 双击本文件：列出所有残留 → 确认 → 删干净
rem 只看不删：卸载.bat /check
chcp 65001 >nul
cd /d "%~dp0"
set "PS1=%~dp0卸载.ps1"

if not exist "%PS1%" (
  echo.
  echo   找不到 卸载.ps1 —— 它应该和本文件在同一个文件夹里。
  echo   手动清理：删掉桌面上的「深大电量」快捷方式、
  echo   启动目录里的「深大电量热键」、以及 %%LOCALAPPDATA%%\szu-power 文件夹。
  echo.
  pause
  exit /b 1
)

if /i "%~1"=="/check" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Check
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
)
