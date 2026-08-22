# ============================================================
#  AwayFromShorts - install.ps1 (懒人包一键安装引导)
#
#  用法(在 PowerShell 里执行这一行即可):
#    irm https://raw.githubusercontent.com/sdgfdii/AwayFromShorts/main/install.ps1 | iex
#
#  流程: 下载 GitHub 上的懒人包 ZIP -> 解压 -> 弹 UAC 运行 install.bat
# ============================================================
$ErrorActionPreference = 'Stop'
$repo  = 'sdgfdii/AwayFromShorts'
$dest  = Join-Path $env:TEMP 'AwayFromShorts-install'

Write-Host ''
Write-Host '===== AwayFromShorts 一键安装 =====' -ForegroundColor Cyan
Write-Host "仓库: https://github.com/$repo"
Write-Host ''

# 1. 找最新 Release 的懒人包 zip; 没有 Release 则回退到仓库 main 分支 zip
$zip = $null
try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'AwayFromShorts-installer' }
    if ($rel.assets) {
        $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($asset) {
            $zip = Join-Path $dest 'lazy.zip'
            Write-Host "下载 Release 懒人包: $($asset.name) ..."
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        }
    }
} catch {
    Write-Host '没有找到 Release,使用仓库 main 分支打包...' -ForegroundColor Yellow
}

if (-not $zip -or -not (Test-Path $zip)) {
    $zip = Join-Path $dest 'main.zip'
    Write-Host '下载仓库 main 分支...'
    Invoke-WebRequest -Uri "https://codeload.github.com/$repo/zip/refs/heads/main" -OutFile $zip -UseBasicParsing
}

# 2. 解压
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Expand-Archive -Path $zip -DestinationPath $dest -Force
$inner = Get-ChildItem $dest -Directory | Select-Object -First 1
$installBat = Join-Path $inner.FullName 'install.bat'
if (-not (Test-Path $installBat)) { throw "懒人包格式不对,缺少 install.bat" }

# 3. 提权运行 install.bat
Write-Host ''
Write-Host '即将弹出管理员权限确认,请点击"是"' -ForegroundColor Yellow
Start-Sleep -Seconds 1
Start-Process -FilePath $installBat -Verb RunAs -WorkingDirectory $inner.FullName

Write-Host ''
Write-Host '安装程序已启动。安装完成后会自动打开配置面板:'
Write-Host '    http://127.0.0.1:8737' -ForegroundColor Green
Write-Host ''
Write-Host '如果弹出 UAC 后没有反应,请手动到临时目录运行:'
Write-Host "    $installBat"
Write-Host ''
