# ============================================================
#  AwayFromShorts - webui.ps1 (可视化配置面板)
#  启动本地 Web 服务: http://127.0.0.1:8737
#  用法: powershell -ExecutionPolicy Bypass -File webui.ps1
#  (由 start-web.bat / install.bat 调用, 无需管理员权限)
# ============================================================
param([int]$Port = 0)

$ErrorActionPreference = 'Stop'

# ---------------- 管理员权限(自我提权) ----------------
# 面板需要管理员权限才能直接写 hosts / 管理浏览器策略 / 操作网卡等。
# 非管理员启动时自动弹 UAC 提权重启; 用户取消则继续以当前权限运行(不退出)。
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '"'
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit
    } catch { }
    # UAC 被取消或失败 -> 继续以当前权限运行
}

. "$PSScriptRoot\core.ps1"

$cfg = Get-AfsConfig
if ($Port -eq 0) { $Port = $cfg.web.port }
if ($Port -lt 1 -or $Port -gt 65535) { $Port = 8737 }

$indexPath = Join-Path $PSScriptRoot 'web\index.html'
if (-not (Test-Path $indexPath)) { throw "缺少前端页面: $indexPath" }
$indexBytes = [System.IO.File]::ReadAllBytes($indexPath)

# ---------------- 基础 HTTP ---------------

function Send-AfsResponse {
    param($Stream, [int]$Status, [string]$Type, $Body)
    $bytes = if ($Body -is [byte[]]) { $Body } else { [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
    $head = "HTTP/1.1 $Status`r`nContent-Type: $Type`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
    $Stream.Flush()
}

function Send-AfsJson {
    param($Stream, [int]$Status, $Obj)
    $json = ConvertTo-Json $Obj -Depth 12 -Compress
    Send-AfsResponse -Stream $Stream -Status $Status -Type 'application/json; charset=utf-8' -Body $json
}

# ---------------- 状态 ----------------

function Get-AfsStatusObj {
    $cfg = Get-AfsConfig
    $state = Get-AfsActiveState -Config $cfg
    $lastRun = $null
    $lastPath = Join-Path (Split-Path (Get-AfsConfigPath)) 'last-run.json'
    if (Test-Path $lastPath) {
        try {
            $lastRun = ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($lastPath, [System.Text.Encoding]::UTF8)))
        } catch { }
    }
    @{
        ok          = $true
        version     = $script:AFS_VERSION
        isAdmin     = Get-AfsIsAdmin
        active      = $state.active
        activeReason = $state.reason
        enabled     = $cfg.enabled
        hosts       = Get-AfsHostsState -Path (Get-AfsDefaultHostsPath)
        task        = Get-AfsTaskInfo
        nextActive  = Get-AfsNextActiveTime -Config $cfg
        lastRun     = $lastRun
        config      = $cfg
    }
}

# ---------------- 路由 ----------------
# 注意: Windows PowerShell 5.1 不能在 .NET Thread 上执行 scriptblock(会直接崩溃进程),
#       所以这里顺序处理每个连接(本地单用户面板, 响应毫秒级, 足够用)。

$handler = {
    param($client)
    $stream = $null
    $ErrorActionPreference = 'Continue'   # 路由里用显式 throw, 不依赖全局 Stop
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 8000
        $buf  = [byte[]]::new(16384)
        $sb   = [System.Text.StringBuilder]::new()
        $all  = ''
        $head = $null
        $body = ''
        $contentLength = 0
        $offset = 0

        # 读请求头
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $n))
            $all = $sb.ToString()
            $idx = $all.IndexOf("`r`n`r`n")
            if ($idx -ge 0) {
                $head = $all.Substring(0, $idx)
                $offset = $idx + 4
                foreach ($line in ($head -split "`r`n")) {
                    if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                }
                break
            }
        }
        if ($null -eq $head) { throw 'bad request' }

        # 读 body
        $have = $all.Length - $offset
        if ($have -lt $contentLength) {
            $need = $contentLength - $have
            $bodyBuf = [byte[]]::new($need)
            $read = 0
            while ($read -lt $need) {
                $n = $stream.Read($bodyBuf, $read, $need - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $body = [System.Text.Encoding]::UTF8.GetString($bodyBuf, 0, $read)
        } elseif ($have -gt 0 -and $contentLength -gt 0) {
            $body = $all.Substring($offset, [Math]::Min($contentLength, $have))
        }

        $parts = $head -split '\s+'
        $method = if ($parts.Count -gt 0) { $parts[0].ToUpper() } else { '' }
        $path   = if ($parts.Count -gt 1) { $parts[1] } else { '/' }
        if ($path -match '\?') { $path = $path.Substring(0, $path.IndexOf('?')) }

        $appDir = Split-Path (Get-AfsConfigPath)
        $logPath = Join-Path $appDir 'last-run.json'

        # ---------- 路由表 ----------
        if ($method -eq 'GET' -and $path -eq '/') {
            Send-AfsResponse -Stream $stream -Status 200 -Type 'text/html; charset=utf-8' -Body $indexBytes
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/config') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; config = (Get-AfsConfig) }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/status') {
            Send-AfsJson -Stream $stream -Status 200 -Obj (Get-AfsStatusObj)
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/browser/windows') {
            $w = @(Get-Process msedge,chrome -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle } |
                ForEach-Object { [string]$_.MainWindowTitle } | Select-Object -Unique)
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; windows = $w }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/config') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $inCfg = ConvertTo-AfsHashtable $o
                $forceNow = Test-AfsForceActive -Config (Get-AfsConfig)
                if ($forceNow.active -and -not [bool]$inCfg.enabled) {
                    throw "强制模式生效中 (可先关闭强制模式, 再关闭屏蔽)"
                }
                $newCfg = Set-AfsConfigSafe -InputConfig $inCfg
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    note = '已保存, 屏蔽引擎将在 1 分钟内应用'
                    config = $newCfg
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/force') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $enable = [bool]$o.enabled
                $c = Get-AfsConfig
                if ($enable) {
                    # 生效到当天 24:00 (23:59:59)
                    $until = (Get-Date).Date.AddDays(1).AddSeconds(-1)
                    Save-AfsForceState -Until $until.ToString('o')
                    $c.force.enabled = $true
                    $c.force.until  = $until.ToString('o')
                    Set-AfsConfigSafe -InputConfig $c | Out-Null
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{
                        ok = $true
                        until = $until.ToString('o')
                        note = "强制模式已开启: 屏蔽时段内 ($($until.ToString('yyyy-MM-dd HH:mm')) 前) 无法关闭/解除屏蔽, 时段外不强制"
                    }
                } else {
                    # 允许随时关闭 (即使生效中): 清 config + 独立状态文件, 计划任务不再兜底补开
                    $c.force.enabled = $false
                    $c.force.until  = $null
                    Set-AfsConfigSafe -InputConfig $c | Out-Null
                    Remove-AfsForceState
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '强制模式已关闭' }
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/apply') {
            try {
                $cfgNow = Get-AfsConfig
                if (Get-AfsIsAdmin) {
                    $res = Invoke-AfsLocked -Action {
                        Invoke-AfsEnforce -Config $cfgNow -HostsPath (Get-AfsDefaultHostsPath) -LogPath $logPath
                    }
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; applied = $true; result = $res }
                } else {
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; applied = $false; note = '面板非管理员权限, 已交由计划任务执行(1 分钟内)' }
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/override') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $mode = [string]$o.mode
                $minutes = try { [int]$o.minutes } catch { 30 }
                if ($mode -notin @('none','block','off')) { throw 'mode 必须为 none/block/off' }
                $c = Get-AfsConfig
                $forceNow = Test-AfsForceActive -Config $c
                if ($forceNow.active -and $mode -in @('off','none')) {
                    throw "强制模式生效中 (可先关闭强制模式, 再解除屏蔽)"
                }
                if ($mode -eq 'none') {
                    $c.override.mode = 'none'; $c.override.until = $null
                } else {
                    $c.override.mode = $mode
                    $c.override.until = (Get-Date).AddMinutes($minutes).ToString('o')
                }
                Set-AfsConfigSafe -InputConfig $c | Out-Null   # 返回值必须吞掉, 否则会泄漏到 stdout
                # 立即生效: 管理员面板直接同步执行 enforcer, 不等计划任务 (任务可能失败/错过触发, 避免"点了没用")
                $applied = $false
                if (Get-AfsIsAdmin) {
                    try {
                        Invoke-AfsLocked -Action {
                            Invoke-AfsEnforce -Config (Get-AfsConfig) -HostsPath (Get-AfsDefaultHostsPath) -LogPath $logPath
                        } | Out-Null
                        $applied = $true
                    } catch { $applied = $false }
                }
                if ($applied) { $note = '已设置并立即生效' } else { $note = '已设置, 1 分钟内生效(自动)' }
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; until = $c.override.until; applied = $applied; note = $note }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/uninstall') {
            try {
                $uninstallPs1 = Join-Path $PSScriptRoot 'uninstall.ps1'
                if (-not (Test-Path $uninstallPs1)) { throw "找不到 $uninstallPs1" }
                $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallPs1`""
                Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -Verb RunAs
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '卸载程序已启动, 请在弹窗中确认' }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        # ---------- 账号 / 云同步 (GitHub Gist) ----------
        if ($method -eq 'GET' -and $path -eq '/api/account') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; account = (Get-AfsAccountInfo) }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/login') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $token = [string]$o.token
                if (-not $token) { throw '请输入 GitHub Personal Access Token' }
                $u = Get-AfsGitHubUser -Token $token   # 验证失败会抛 401
                Save-AfsGitHubToken -Token $token
                $state = Get-AfsSyncState
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    account = @{
                        loggedIn = $true; login = $u.login; name = $u.name; email = $u.email
                        gistId = $state.gistId; lastSync = $state.lastSync; autoPush = [bool]$state.autoPush
                    }
                    note = "登录成功: $($u.login)"
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 401 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/logout') {
            Clear-AfsGitHubToken
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '已退出登录, 本机 Token 已删除' }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/push') {
            try {
                $token = Get-AfsGitHubToken
                if (-not $token) { throw '未登录, 请先输入 GitHub Token' }
                $state = Push-AfsSyncConfig -Token $token
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    note = "已推送到云端 Gist ($($state.lastSync))"
                    account = (Get-AfsAccountInfo)
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/pull') {
            try {
                $token = Get-AfsGitHubToken
                if (-not $token) { throw '未登录, 请先输入 GitHub Token' }
                $r = Pull-AfsSyncConfig -Token $token
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    note = "已从云端拉取(本地已备份: $($r.backup))"
                    config = $r.config
                    account = (Get-AfsAccountInfo)
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/autopush') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $state = Get-AfsSyncState
                $state.autoPush = [bool]$o.autoPush
                Save-AfsSyncState $state
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; autoPush = [bool]$state.autoPush }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/stop') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true }
            $script:AFS_STOP = $true
            return
        }
        Send-AfsResponse -Stream $stream -Status 404 -Type 'text/plain; charset=utf-8' -Body '404 not found'
    } catch {
        try { Send-AfsResponse -Stream $stream -Status 500 -Type 'text/plain; charset=utf-8' -Body ("server error: " + $_.Exception.Message) } catch { }
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

# ---------------- 主循环 ----------------

# 幂等启动: 端口被占用说明面板已在运行(如开机自启重复触发),直接退出,不绑定其它端口
$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Write-Output "AwayFromShorts 配置面板已在运行(端口 $Port 被占用),无需重复启动"
    exit 0
}

Write-Output "AwayFromShorts 配置面板已启动: http://127.0.0.1:$Port/  (Ctrl+C 停止)"

while (-not $script:AFS_STOP) {
    try {
        $client = $listener.AcceptTcpClient()
        & $handler $client
    } catch {
        if ($script:AFS_STOP) { break }
        Start-Sleep -Milliseconds 200
    }
}
$listener.Stop()
Write-Output "配置面板已停止"
