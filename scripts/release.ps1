# ============================================================
#  release.ps1 — 打 tag 并发布 GitHub Release(附懒人包 zip)
#
#  用法: 先完成 gh auth login, 然后:
#    powershell -File scripts\release.ps1 -Version 1.0.0
# ============================================================
param([string]$Version = '1.0.0')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

# 1. 打包懒人包
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-release.ps1') -Version $Version
$zip = Join-Path $root "dist\AwayFromShorts-v$Version-win64.zip"
if (-not (Test-Path $zip)) { throw "懒人包不存在: $zip" }

# 2. 打 tag 并推送
git -C $root add -A
git -C $root commit -m "release v$Version" --allow-empty
git -C $root push origin main
git -C $root tag "v$Version"
git -C $root push origin "v$Version"

# 3. 创建 Release
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh release create "v$Version" $zip --repo sdgfdii/AwayFromShorts --title "v$Version" --notes "懒人包一键安装:
- 下载 ZIP 解压后右键 install.bat 以管理员身份运行
- 或 PowerShell 执行: irm https://raw.githubusercontent.com/sdgfdii/AwayFromShorts/main/install.ps1 | iex"
    Write-Host "Release v$Version 已发布" -ForegroundColor Green
} else {
    Write-Host "未安装 gh。请在浏览器打开 https://github.com/sdgfdii/AwayFromShorts/releases/new 手动上传: $zip" -ForegroundColor Yellow
}
