# ============================================================
#  AwayFromShorts - sync.ps1
#  把开发目录源码同步到已安装目录, 并重启面板服务
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1
#  (或直接双击 sync.bat)
# ============================================================

$ErrorActionPreference = 'Continue'

# ---------------- 管理员权限(自我提权) ----------------
# 停掉面板进程 / 触发计划任务可能需要管理员权限, 非管理员时自动弹 UAC。
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '"'
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null; exit } catch { }
    # UAC 被取消则继续以当前权限运行
}

$dev = $PSScriptRoot                       # 项目根目录(开发目录)
$app = Join-Path $env:LOCALAPPDATA 'AwayFromShorts'

if (-not (Test-Path (Join-Path $app 'src\webui.ps1'))) {
    Write-Host "[错误] 未检测到安装目录: $app" -ForegroundColor Red
    Write-Host "       请先运行 install.bat 完成安装。" -ForegroundColor Red
    exit 1
}

# ---------------- 需要同步的源码文件(白名单) ----------------
# 只同步程序本体文件, 不碰运行时数据(config.json / stats.json / token 等)。
$files = @(
    'awayfromshorts.ps1',
    'core.ps1',
    'webui.ps1',
    'close-browser-windows.ps1',
    'register-task.ps1',
    'register-webui-task.ps1',
    'uninstall.ps1',
    'close-browser.vbs',
    'config.example.json',
    'web\index.html'
)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$synced = 0

foreach ($f in $files) {
    $src = Join-Path $dev ('src\' + $f)
    $dst = Join-Path $app ('src\' + $f)
    if (-not (Test-Path $src)) {
        Write-Host "[跳过] 开发目录缺少: $f" -ForegroundColor Yellow
        continue
    }
    if (Test-Path $dst) {
        Copy-Item $dst "$dst.bak-$stamp" -Force -ErrorAction SilentlyContinue
    }
    Copy-Item $src $dst -Force
    Write-Host "[同步] $f"
    $synced++
}

# ---------------- 重启面板服务 ----------------
Write-Host ""
Write-Host "正在重启面板服务..."
$conn = Get-NetTCPConnection -LocalPort 8737 -State Listen -ErrorAction SilentlyContinue
if ($conn) {
    Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# 优先用计划任务(管理员权限, 不弹 UAC); 没有则直接启动 webui.ps1
schtasks /Query /TN 'AwayFromShorts-WebUI' 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    schtasks /Run /TN 'AwayFromShorts-WebUI' 2>$null | Out-Null
    Write-Host "[启动] 已通过计划任务 AwayFromShorts-WebUI 拉起面板"
} else {
    Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$app\src\webui.ps1`"" -WindowStyle Hidden
    Write-Host "[启动] 已直接启动 webui.ps1"
}

Write-Host ""
Write-Host "[完成] 已同步 $synced 个文件并重启面板。打开 http://127.0.0.1:8737 查看。" -ForegroundColor Green
