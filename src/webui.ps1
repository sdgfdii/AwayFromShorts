# ============================================================
#  AwayFromShorts - webui.ps1 (可视化配置面板)
#  启动本地 Web 服务: http://127.0.0.1:8737
#  用法: powershell -ExecutionPolicy Bypass -File webui.ps1
#  (由 start-web.bat / install.bat 调用, 无需管理员权限)
# ============================================================
param([int]$Port = 0)

$ErrorActionPreference = 'Stop'
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
        if ($method -eq 'POST' -and $path -eq '/api/config') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $newCfg = Set-AfsConfigSafe -InputConfig (ConvertTo-AfsHashtable $o)
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
                if ($mode -eq 'none') {
                    $c.override.mode = 'none'; $c.override.until = $null
                } else {
                    $c.override.mode = $mode
                    $c.override.until = (Get-Date).AddMinutes($minutes).ToString('o')
                }
                Set-AfsConfigSafe -InputConfig $c | Out-Null   # 返回值必须吞掉, 否则会泄漏到 stdout
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; until = $c.override.until; note = '已设置, 1 分钟内生效' }
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

$listener = $null
$bound = $false
for ($try = 0; $try -lt 10 -and -not $bound; $try++) {
    $p = $Port + $try
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
        $listener.Start()
        $bound = $true
        $Port = $p
    } catch { $listener = $null }
}
if (-not $bound) { throw "无法绑定端口 $Port ~ $($Port + 9)" }

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
