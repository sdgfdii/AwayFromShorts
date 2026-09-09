# ============================================================
#  AwayFromShorts - awayfromshorts.ps1 (屏蔽引擎)
#  由 Windows 计划任务 "AwayFromShorts" 每分钟调用一次(最高权限)
#  也可以手动运行: powershell -File awayfromshorts.ps1
# ============================================================
param(
    [string]$ConfigPath,   # 自定义配置文件路径(测试用)
    [string]$HostsPath,    # 自定义 hosts 路径(测试用)
    [switch]$Simulate      # 干跑: 不写 hosts、不杀进程
)

. "$PSScriptRoot\core.ps1"

if ($ConfigPath) { Set-AfsConfigPath -Path $ConfigPath }
if (-not $HostsPath) { $HostsPath = Get-AfsDefaultHostsPath }

try {
    $cfg     = Get-AfsConfig
    $appDir  = Split-Path (Get-AfsConfigPath)
    $logPath = Join-Path $appDir 'last-run.json'

    $result = Invoke-AfsLocked -Action {
        Invoke-AfsEnforce -Config $cfg -HostsPath $HostsPath -LogPath $logPath -Simulate:$Simulate
    }

    Write-Output ("AFS: active={0} reason={1} hosts={2} killed={3}" -f $result.active, $result.reason, $result.hosts, $result.killed.Count)
    if ($result.error) { Write-Output ("AFS ERROR: {0}" -f $result.error) }
} catch {
    Write-Output ("AFS FATAL: {0}" -f $_.Exception.Message)
    exit 1
}
# ---- 看门狗: 探测面板健康(防单线程僵死导致"保存失败"), 无响应则自动重启 (90s 冷却防抖动) ----
if (-not $Simulate) {
    try {
        $probeOk = $false
        try {
            $probe = Invoke-WebRequest 'http://127.0.0.1:8737/api/status' -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
            $probeOk = ($probe.StatusCode -eq 200)
        } catch { $probeOk = $false }
        if (-not $probeOk) {
            $cool = Join-Path $appDir '.webui-restart.timestamp'
            $nowEpoch = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $allow = $true
            if (Test-Path $cool) {
                $last = 0
                [void][int]::TryParse(([System.IO.File]::ReadAllText($cool).Trim()), [ref]$last)
                if (($nowEpoch - $last) -lt 90) { $allow = $false }
            }
            if ($allow) {
                [System.IO.File]::WriteAllText($cool, $nowEpoch.ToString(), (New-Object System.Text.UTF8Encoding($false)))
                schtasks /Run /TN AwayFromShorts-WebUI 2>&1 | Out-Null
                Write-Output 'AFS-WATCHDOG: webui unresponsive -> restarted AwayFromShorts-WebUI'
            }
        }
    } catch { }
}