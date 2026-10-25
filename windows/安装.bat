@echo off
rem 深大宿舍电量查询 —— 安装/打开设置
rem 双击本文件：创建桌面快捷方式并打开设置向导
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "szu-power.ps1" -Install
