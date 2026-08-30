# ============================================================
#  build-release.ps1 — 打包懒人包 ZIP (install.bat + src + 文档)
#  用法: powershell -File build-release.ps1 [-Version 1.1.3]
# ============================================================
param([string]$Version = '1.1.3')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot          # 项目根
$dist = Join-Path $root 'dist'
$stage = Join-Path $env:TEMP 'afs-release-stage'

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

# 只打包必要文件, 保持 zip 干净
Copy-Item (Join-Path $root 'install.bat')      $stage
Copy-Item (Join-Path $root 'uninstall.bat')    $stage
Copy-Item (Join-Path $root 'start-web.bat')    $stage
Copy-Item (Join-Path $root 'startup-webui.vbs') $stage
Copy-Item (Join-Path $root 'README.md')        $stage
Copy-Item (Join-Path $root 'LICENSE')          $stage
Copy-Item (Join-Path $root 'src')              $stage -Recurse

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$out = Join-Path $dist "AwayFromShorts-v$Version-win64.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out -Force
Remove-Item $stage -Recurse -Force

Write-Host "懒人包已生成: $out" -ForegroundColor Green
