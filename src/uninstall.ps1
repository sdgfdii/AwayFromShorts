# ============================================================
#  AwayFromShorts - uninstall.ps1 (一键卸载, 需要管理员权限)
#  1. 删除计划任务  2. 恢复 hosts  3. 关闭配置面板  4. 删除程序目录
# ============================================================
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

Write-Host ''
Write-Host '===== AwayFromShorts 卸载 =====' -ForegroundColor Cyan

if (-not (Get-AfsIsAdmin)) {
    Write-Host '需要管理员权限, 正在请求...' -ForegroundColor Yellow
    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -Verb RunAs
    exit 0
}

$appRoot = Split-Path $PSScriptRoot   # src 的上一级 = 程序目录

# 1. 删除计划任务
Write-Host '[1/6] 删除计划任务...'
schtasks /Delete /TN "AwayFromShorts" /F 2>&1 | Out-Null
schtasks /Delete /TN "AwayFromShorts-BrowserClose" /F 2>&1 | Out-Null

# 2. 恢复 hosts(移除本程序的标记块)
Write-Host '[2/6] 恢复 hosts 文件...'
try {
    Remove-AfsHostsBlock -Path (Get-AfsDefaultHostsPath)
    Write-Host '      hosts 已还原(仅移除了 AwayFromShorts 写入的行)'
} catch {
    Write-Host ("      hosts 还原失败: " + $_.Exception.Message) -ForegroundColor Yellow
}

# 3. 清除浏览器 URL 拦截策略 (URLBlocklist / URLAllowlist)
Write-Host '[3/6] 清除浏览器拦截策略...'
foreach ($root in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome')) {
    Remove-Item (Join-Path $root 'URLBlocklist') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $root 'URLAllowlist') -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. 关闭配置面板进程
Write-Host '[4/6] 关闭配置面板...'
try {
    $me = $PID
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*webui.ps1*' -and $_.ProcessId -ne $me } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

# 5. 备份 hosts 备份文件删除(保留用户自己的 hosts 修改)
Write-Host '[5/6] 清理备份文件...'
if (Test-Path (Join-Path $appRoot 'hosts.backup')) { Remove-Item (Join-Path $appRoot 'hosts.backup') -Force -ErrorAction SilentlyContinue }

# 4.5 删除开机自启项(启动文件夹里的隐藏启动脚本)
$startupVbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'AwayFromShorts-WebUI.vbs'
if (Test-Path $startupVbs) { Remove-Item $startupVbs -Force -ErrorAction SilentlyContinue }

# 6. 删除程序目录(延迟到本进程退出后, 用临时 bat 清理)
Write-Host '[6/6] 删除程序文件...'
$cleanup = Join-Path $env:TEMP "afs-cleanup-$PID.bat"
@"
@echo off
timeout /t 3 /nobreak >nul
rmdir /s /q "$appRoot" 2>nul
del "%~f0" 2>nul
"@ | Set-Content -Path $cleanup -Encoding ASCII
Start-Process -FilePath $cleanup -WindowStyle Hidden

Write-Host ''
Write-Host '卸载完成! 屏蔽已全部解除。' -ForegroundColor Green
Write-Host '再见, 愿你有更多时间去做真正重要的事。'
Write-Host ''
Start-Sleep -Seconds 2
