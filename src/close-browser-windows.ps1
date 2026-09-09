# close-browser-windows.ps1
# 由 AwayFromShorts-BrowserClose 计划任务在"用户交互会话"中调用
# (S4U 计划任务不能操作桌面窗口, 必须经由 /IT 交互任务执行)。
#
# 读取 browser-close.json 载荷:
#   patterns   - 窗口标题匹配(支持 * 通配符), 匹配的窗口被优雅关闭(工作区屏蔽)
#   targets    - 生效浏览器: edge -> msedge, chrome -> chrome
#   restartAll - 关闭所有浏览器窗口后重新打开(URLBlocklist 策略变更后重启使策略生效)
# 注意: 只按 patterns 关闭(用户配置的工作区窗口), 不做"标题含站点名"兜底, 避免误关工作窗口。
param()
$ErrorActionPreference = 'Continue'

$dir  = Split-Path $MyInvocation.MyCommand.Path
$payloadPath = Join-Path $dir 'browser-close.json'
$logPath     = Join-Path $dir 'browser-close.log'
$log = @{
    time     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    seen     = @()
    matched  = @()
    closed   = @()
    reopened = $false
    error    = ''
}
try {
    if (-not (Test-Path $payloadPath)) { return }   # 无任务载荷, 直接退出
    $p = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
    $patterns   = @($p.patterns)
    $targets    = @($p.targets)
    $restartAll = [bool]$p.restartAll
    $names = @($targets | ForEach-Object { if ($_ -eq 'edge') { 'msedge' } else { 'chrome' } } | Select-Object -Unique)
    if ($names.Count -eq 0) { $names = @('msedge', 'chrome') }

    # 关闭前正在运行的浏览器(有窗口) —— restartAll 重开时只重开这些,
    # 绝不启动用户本来没开的浏览器(如 chrome 只装了没用, 不该被自动拉起)
    $hadWindow = @()
    foreach ($n in $names) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }).Count -gt 0) {
            $hadWindow += $n
        }
    }

    # 关闭匹配窗口 (restartAll 时关闭所有带窗口进程)
    foreach ($n in $names) {
        foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle })) {
            $title = [string]$pr.MainWindowTitle
            $log.seen += "$n($($pr.Id)) [$title]"
            $match = $restartAll
            if (-not $match) {
                foreach ($pat in $patterns) { if ($title -like $pat) { $match = $true; break } }
            }
            if ($match) {
                $log.matched += "$n($($pr.Id)) [$title]"
                # 直接强制结束匹配窗口的进程(无需确认): 页面 onbeforeunload 弹"确认离开?"
                # 会卡住优雅关闭; 浏览器每个窗口是独立 browser 进程, 杀它只关该窗口及其标签,
                # 其他窗口(学习/工作)不受影响。
                try {
                    Stop-Process -Id $pr.Id -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 400
                    if (-not (Get-Process -Id $pr.Id -ErrorAction SilentlyContinue)) {
                        $log.closed += "$n($($pr.Id)) [$title] (强制)"
                    }
                } catch { }
            }
        }
    }

    # restartAll: 全部关闭后重新打开浏览器 (仅当已无窗口进程时)
    # 注意: 无参 Start-Process msedge 在已有后台实例时不会弹新窗口, 必须 --new-window
    if ($restartAll) {
        Start-Sleep -Seconds 2
        foreach ($n in $hadWindow) {
            $any = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle })
            if (-not $any) {
                try { Start-Process -FilePath $n -ArgumentList '--new-window'; $log.reopened = $true } catch { }
            }
        }
    }
} catch {
    $log.error = $_.Exception.Message
}
try {
    [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $log), (New-Object System.Text.UTF8Encoding($false)))
} catch { }
