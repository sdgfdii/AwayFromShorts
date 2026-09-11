# close-browser-windows.ps1
# 由 AwayFromShorts-BrowserClose 计划任务在"用户交互会话"中调用
# (S4U 计划任务不能操作桌面窗口, 必须经由 /IT 交互任务执行)。
#
# 读取 browser-close.json 载荷:
#   patterns   - 窗口标题匹配(支持 * 通配符), 匹配的窗口被强制关闭(工作区屏蔽)
#   targets    - 生效浏览器: edge -> msedge, chrome -> chrome
#   restartAll - 关闭所有浏览器窗口后重新打开(URLBlocklist 策略变更后重启使策略生效)
# 注意: 只按 patterns 关闭(用户配置的工作区窗口), 不做"标题含站点名"兜底, 避免误关工作窗口。
# 强制结束进程(不等待优雅关闭): 页面 onbeforeunload 弹"确认离开?"会卡住 CloseMainWindow;
# 浏览器每个窗口是独立 browser 进程, 杀它只关该窗口及其标签, 其他窗口(学习/工作)不受影响。
# 持续监测: 一次运行扫描约 60 秒(每 5 秒一轮), 窗口被关后 10 秒内重开也会在下一轮再次被关。
param()
$ErrorActionPreference = 'Continue'

$dir  = Split-Path $MyInvocation.MyCommand.Path
$payloadPath = Join-Path $dir 'browser-close.json'
$logPath     = Join-Path $dir 'browser-close.log'

# Win32 顶层窗口枚举 (不依赖 Get-Process.MainWindowTitle —— 它对 Chromium 多进程窗口经常返回空)
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AfsWin {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int nMax);
    [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
'@

# 枚举当前交互会话所有可见顶层窗口, 返回 (PID, Title) 列表
function Get-AfsVisibleWindows {
    $list = New-Object System.Collections.ArrayList
    $cb = [AfsWin+EnumProc]{
        param($h, $l)
        try {
            if ([AfsWin]::IsWindowVisible($h)) {
                $len = [AfsWin]::GetWindowTextLengthW($h)
                if ($len -gt 0) {
                    $sb = New-Object System.Text.StringBuilder ($len + 1)
                    [void][AfsWin]::GetWindowTextW($h, $sb, $sb.Capacity)
                    $pid = 0
                    [void][AfsWin]::GetWindowThreadProcessId($h, [ref]$pid)
                    [void]$list.Add(@{ Pid = [int]$pid; Title = $sb.ToString() })
                }
            }
        } catch { }
        return $true
    }
    [void][AfsWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $list
}

function Invoke-AfsCloseRound {
    $log = @{
        time     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        seen     = @()
        matched  = @()
        closed   = @()
        reopened = $false
        error    = ''
    }
    try {
        if (-not (Test-Path $payloadPath)) { return }
        $p = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
        $patterns   = @($p.patterns)
        $targets    = @($p.targets)
        $restartAll = [bool]$p.restartAll
        $names = @($targets | ForEach-Object { if ($_ -eq 'edge') { 'msedge' } else { 'chrome' } } | Select-Object -Unique)
        if ($names.Count -eq 0) { $names = @('msedge', 'chrome') }

        # PID -> 进程名 映射 (一次查询, 供窗口反查)
        $pidName = @{}
        foreach ($n in $names) {
            foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                $pidName[[int]$pr.Id] = $n
            }
        }

        $hadWindow = @()
        foreach ($n in $names) {
            if ($pidName.ContainsValue($n)) { $hadWindow += $n }
        }

        foreach ($w in @(Get-AfsVisibleWindows)) {
            $wn = $null
            if ($pidName.ContainsKey($w.Pid)) { $wn = $pidName[$w.Pid] }
            if (-not $wn) { continue }
            $title = [string]$w.Title
            $log.seen += "$wn($($w.Pid)) [$title]"
            $match = $restartAll
            if (-not $match) {
                foreach ($pat in $patterns) { if ($title -like $pat) { $match = $true; break } }
            }
            if ($match) {
                $log.matched += "$wn($($w.Pid)) [$title]"
                try {
                    Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 400
                    if (-not (Get-Process -Id $w.Pid -ErrorAction SilentlyContinue)) {
                        $log.closed += "$wn($($w.Pid)) [$title] (强制)"
                    }
                } catch { }
            }
        }

        if ($restartAll) {
            Start-Sleep -Seconds 2
            foreach ($n in $hadWindow) {
                $any = @(Get-AfsVisibleWindows | Where-Object { $pidName.ContainsKey($_.Pid) })
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
    return @($log.closed).Count
}

# 屏蔽期间常驻监测, 固定短轮询:
#   每 3 秒扫描一轮, 保证匹配窗口在 10 秒内被关闭(含进程调度延迟)。
#   之前自适应 5s/8s 低频时, 最坏要等 8 秒+调度延迟才响应, 可能超过 10 秒上限。
# 任务 MultipleInstancesPolicy=IgnoreNew: 引擎每分钟触发, 常驻实例不被重复拉起。
# 引擎解除屏蔽时 payload.patterns 变空 -> 本轮后自动退出, 不空转。
$heartbeatPath = Join-Path $dir 'browser-close.heartbeat'
$emptyRounds = 0
while ($true) {
    # 全局兜底: 单轮任何未捕获异常都不中断常驻循环, 避免"进程静默死亡导致屏蔽失效"
    try {
        $null = Invoke-AfsCloseRound
    } catch {
        try {
            $hb = @{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); error = $_.Exception.Message }
            [System.IO.File]::WriteAllText($heartbeatPath, (ConvertTo-Json $hb), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    $stillActive = $false
    if (Test-Path $payloadPath) {
        try {
            $pp = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
            if (@($pp.patterns).Count -gt 0 -or [bool]$pp.restartAll) { $stillActive = $true }
        } catch { }
    }
    if (-not $stillActive) { break }
    # 心跳: 每次正常循环刷新时间戳, 便于诊断"进程是否存活"
    if ($emptyRounds % 10 -eq 0) {
        try {
            $hb = @{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); alive = $true }
            [System.IO.File]::WriteAllText($heartbeatPath, (ConvertTo-Json $hb), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    $emptyRounds++
    Start-Sleep -Seconds 3
}
