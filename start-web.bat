@echo off
chcp 65001 >nul
setlocal

REM 启动 AwayFromShorts 可视化配置面板(幂等: webui.ps1 检测到端口已被占用会自动退出)
set "APP=%LOCALAPPDATA%\AwayFromShorts"
if not exist "%APP%\src\webui.ps1" (
  echo 未检测到安装,请先运行 install.bat
  pause
  exit /b 1
)

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP%\src\webui.ps1"

REM 等面板就绪(最多约 15 秒)再打开浏览器,避免"无法访问此页面"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ok=$false; 1..60 | ForEach-Object { if ($ok) { return }; try { $c=New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1',8737); $c.Close(); $ok=$true } catch { Start-Sleep -Milliseconds 250 } }; if ($ok) { Start-Process 'http://127.0.0.1:8737' } else { Write-Host '面板启动超时,请稍后手动打开 http://127.0.0.1:8737' }"