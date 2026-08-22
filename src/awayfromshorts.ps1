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
