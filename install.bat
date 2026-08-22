@echo off
chcp 65001 >nul
setlocal EnableExtensions

REM ============ AwayFromShorts 一键安装 ============

REM 检查管理员权限,没有则提权
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo 需要管理员权限,正在请求提升...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SRC=%~dp0"
set "APP=%LOCALAPPDATA%\AwayFromShorts"

echo.
echo ===== AwayFromShorts 安装 =====

echo [1/5] 复制文件到 %APP%
if not exist "%APP%" mkdir "%APP%"
if not exist "%APP%\src" mkdir "%APP%\src"
copy /y "%SRC%src\core.ps1"          "%APP%\src\" >nul
copy /y "%SRC%src\awayfromshorts.ps1" "%APP%\src\" >nul
copy /y "%SRC%src\webui.ps1"          "%APP%\src\" >nul
copy /y "%SRC%src\uninstall.ps1"      "%APP%\src\" >nul
if not exist "%APP%\web" mkdir "%APP%\web"
copy /y "%SRC%src\web\index.html"     "%APP%\web\" >nul
if not exist "%APP%\src\config.json" copy /y "%SRC%src\config.example.json" "%APP%\src\config.json" >nul
copy /y "%SRC%uninstall.bat" "%APP%\" >nul
copy /y "%SRC%start-web.bat" "%APP%\" >nul

echo [2/5] 备份 hosts 文件
if not exist "%APP%\hosts.backup" copy /y "%WINDIR%\System32\drivers\etc\hosts" "%APP%\hosts.backup" >nul

echo [3/5] 注册计划任务(每分钟检查,最高权限)
schtasks /Create /F /TN "AwayFromShorts" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%APP%\src\awayfromshorts.ps1\"" /SC MINUTE /MO 1 /RL HIGHEST >nul
if %errorlevel% neq 0 (
  echo [错误] 计划任务注册失败
  pause
  exit /b 1
)

echo [4/5] 立即执行一次屏蔽检查
powershell -NoProfile -ExecutionPolicy Bypass -File "%APP%\src\awayfromshorts.ps1"

echo [5/5] 启动可视化配置面板
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP%\src\webui.ps1"
timeout /t 1 /nobreak >nul
start "" "http://127.0.0.1:8737"

echo.
echo 安装完成!配置面板已打开: http://127.0.0.1:8737
echo 之后想再次打开面板: 运行 %APP%\start-web.bat
echo 卸载: 运行 %APP%\uninstall.bat
echo.
pause
