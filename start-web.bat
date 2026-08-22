@echo off
chcp 65001 >nul
setlocal

REM 启动 AwayFromShorts 可视化配置面板
set "APP=%LOCALAPPDATA%\AwayFromShorts"
if not exist "%APP%\src\webui.ps1" (
  echo 未检测到安装,请先运行 install.bat
  pause
  exit /b 1
)

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP%\src\webui.ps1"
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:8737"
