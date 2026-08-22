@echo off
chcp 65001 >nul
setlocal

REM ============ AwayFromShorts 一键卸载 ============

echo.
echo 正在卸载 AwayFromShorts ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\uninstall.ps1"

echo.
pause
