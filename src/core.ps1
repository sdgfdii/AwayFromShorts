# ============================================================
#  AwayFromShorts - core.ps1 (共享核心函数)
#  https://github.com/sdgfdii/AwayFromShorts
#  兼容 Windows PowerShell 5.1 (无需任何第三方依赖)
# ============================================================

$script:AFS_NAME        = 'AwayFromShorts'
$script:AFS_VERSION     = '1.0.0'
$script:AFS_MARK_START  = "# >>> $($script:AFS_NAME) >>> (managed by AwayFromShorts - do not edit)"
$script:AFS_MARK_END    = "# <<< $($script:AFS_NAME) <<<"
# 这些进程永远不杀,防止把系统/本工具自己弄死
$script:AFS_PROTECTED   = @('powershell','pwsh','conhost','wininit','winlogon','csrss','services','lsass','smss','system','svchost','explorer')
$script:AFS_LOCK_PATH   = Join-Path $env:TEMP "$($script:AFS_NAME).lock"
$script:AfsConfigPath   = $null   # 由 enforcer / webui 覆盖

function Set-AfsConfigPath { param([string]$Path) $script:AfsConfigPath = $Path }

function Get-AfsConfigPath {
    if ($script:AfsConfigPath) { return $script:AfsConfigPath }
    (Join-Path $PSScriptRoot 'config.json')
}

function Get-AfsDefaultHostsPath {
    if ($env:WINDIR) { Join-Path $env:WINDIR 'System32\drivers\etc\hosts' }
    else { 'C:\Windows\System32\drivers\etc\hosts' }
}

function Get-AfsIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 配置读写 ----------

function Get-AfsDefaultConfig {
    @{
        version = 1
        enabled = $true
        schedule = @{
            days    = @(1,2,3,4,5)   # 1=周一 ... 7=周日
            windows = @(
                @{ start = '19:00'; end = '22:00' }
            )
        }
        blockWebsites  = $true
        blockedSites   = @('youtube.com','www.youtube.com','m.youtube.com','youtu.be','youtube-nocookie.com','tiktok.com','www.tiktok.com','vm.tiktok.com','douyin.com','www.douyin.com','v.douyin.com')
        blockedProcesses = @('chrome','msedge')
        whitelist = @{ sites = @(); processes = @() }
        override = @{ mode = 'none'; until = $null }
        web = @{ port = 8737 }
    }
}

# 递归把 ConvertFrom-Json 的 PSCustomObject 转成纯 hashtable / 数组
function ConvertTo-AfsHashtable {
    param($InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-AfsHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IList]) {
        $arr = @()
        foreach ($item in $InputObject) { $arr += ConvertTo-AfsHashtable $item }
        return $arr
    }
    return $InputObject
}

function Read-AfsJson {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "配置文件不存在: $Path" }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $obj  = ConvertFrom-Json $text -ErrorAction Stop
    ConvertTo-AfsHashtable $obj
}

function Write-AfsJson {
    param([string]$Path, $Object)
    $json = ConvertTo-Json $Object -Depth 12
    $utf8 = New-Object System.Text.UTF8Encoding($false)   # 无 BOM, 兼容 web
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

function Get-AfsConfig {
    $path = Get-AfsConfigPath
    if (Test-Path $path) {
        $raw  = Read-AfsJson -Path $path
        return Merge-AfsDeep -Base (Get-AfsDefaultConfig) -Overlay $raw
    }
    Get-AfsDefaultConfig
}

function Merge-AfsDeep {
    param($Base, $Overlay)
    if ($Base -is [hashtable] -and $Overlay -is [hashtable]) {
        $out = @{}
        foreach ($k in $Base.Keys) {
            $out[$k] = if ($Overlay.ContainsKey($k)) { Merge-AfsDeep -Base $Base[$k] -Overlay $Overlay[$k] } else { $Base[$k] }
        }
        foreach ($k in $Overlay.Keys) {
            if (-not $out.ContainsKey($k)) { $out[$k] = $Overlay[$k] }
        }
        return $out
    }
    if ($null -ne $Overlay) { return $Overlay }
    $Base
}

# 校验 + 规范化 + 落盘
function Set-AfsConfigSafe {
    param($InputConfig)
    $cfg = Merge-AfsDeep -Base (Get-AfsDefaultConfig) -Overlay $InputConfig
    $cfg.enabled = [bool]$cfg.enabled

    $cfg.schedule.days = @($cfg.schedule.days | ForEach-Object { try { [int]$_ } catch { 0 } } |
        Where-Object { $_ -ge 1 -and $_ -le 7 } | Sort-Object -Unique)

    $cfg.schedule.windows = @($cfg.schedule.windows | ForEach-Object {
        $s = [string]$_.start; $e = [string]$_.end
        if ($s -match '^\d{1,2}:\d{2}$' -and $e -match '^\d{1,2}:\d{2}$') {
            $sh = [int]($s -split ':')[0]; $sm = [int]($s -split ':')[1]
            $eh = [int]($e -split ':')[0]; $em = [int]($e -split ':')[1]
            if ($sh -le 23 -and $sm -le 59 -and $eh -le 23 -and $em -le 59) {
                @{ start = $s; end = $e }
            }
        }
    })

    $cfg.blockWebsites = [bool]$cfg.blockWebsites
    $cfg.blockedSites = @($cfg.blockedSites | ForEach-Object { ([string]$_).Trim().ToLower() } |
        Where-Object { $_ -match '^[a-z0-9.\-]+$' } | Sort-Object -Unique)
    $cfg.blockedProcesses = @($cfg.blockedProcesses | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)

    $cfg.whitelist.sites = @($cfg.whitelist.sites | ForEach-Object { ([string]$_).Trim().ToLower() } |
        Where-Object { $_ -match '^[a-z0-9.\-]+$' } | Sort-Object -Unique)
    $cfg.whitelist.processes = @($cfg.whitelist.processes | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)

    if ($cfg.override.mode -notin @('none','block','off')) { $cfg.override.mode = 'none' }
    if (-not $cfg.override.until) { $cfg.override.until = $null }

    try { $cfg.web.port = [int]$cfg.web.port } catch { $cfg.web.port = 8737 }
    if ($cfg.web.port -lt 1 -or $cfg.web.port -gt 65535) { $cfg.web.port = 8737 }

    Write-AfsJson -Path (Get-AfsConfigPath) -Object $cfg
    $cfg
}

# ---------- 计划判定 ----------

function ConvertTo-AfsMinutes { param([string]$HHmm)
    $parts = $HHmm -split ':'
    [int]$parts[0] * 60 + [int]$parts[1]
}

# 支持跨午夜: start > end 表示跨夜 (23:00 -> 01:00)
function Test-AfsInWindow {
    param([string]$Start, [string]$End, [int]$NowMin)
    $s = ConvertTo-AfsMinutes $Start
    $e = ConvertTo-AfsMinutes $End
    if ($s -eq $e) { return $false }
    if ($e -gt $s) { return ($NowMin -ge $s) -and ($NowMin -lt $e) }
    return ($NowMin -ge $s) -or ($NowMin -lt $e)
}

function Get-AfsActiveState {
    param($Config, [datetime]$Now = (Get-Date))
    if (-not $Config.enabled) { return @{ active = $false; reason = 'disabled' } }

    $ov = $Config.override
    if ($ov.mode -ne 'none' -and $ov.until) {
        $until = [datetime]::MinValue   # 必须类型化, 否则 [ref] 无法匹配 TryParse 重载
        if ([datetime]::TryParse([string]$ov.until, [ref]$until)) {
            if ((Get-Date) -lt $until) {
                if ($ov.mode -eq 'block') { return @{ active = $true;  reason = 'override-block' } }
                if ($ov.mode -eq 'off')   { return @{ active = $false; reason = 'override-off' } }
            }
        }
    }

    $dayNum = [int]$Now.DayOfWeek      # 0=周日
    if ($dayNum -eq 0) { $dayNum = 7 } # 统一成 1=周一 .. 7=周日
    if (@($Config.schedule.days) -notcontains $dayNum) { return @{ active = $false; reason = 'day' } }

    $nowMin = $Now.Hour * 60 + $Now.Minute
    foreach ($w in @($Config.schedule.windows)) {
        if (Test-AfsInWindow -Start $w.start -End $w.end -NowMin $nowMin) {
            return @{ active = $true; reason = 'schedule' }
        }
    }
    @{ active = $false; reason = 'time' }
}

# 下一个屏蔽开始时间 (当前不在屏蔽中时调用); 当前屏蔽中返回 $null
function Get-AfsNextActiveTime {
    param($Config, [datetime]$Now = (Get-Date))
    for ($d = 0; $d -le 8; $d++) {
        $day = $Now.AddDays($d)
        $dayNum = [int]$day.DayOfWeek
        if ($dayNum -eq 0) { $dayNum = 7 }
        if (@($Config.schedule.days) -notcontains $dayNum) { continue }
        foreach ($w in @($Config.schedule.windows)) {
            $sMin = ConvertTo-AfsMinutes $w.start
            $eMin = ConvertTo-AfsMinutes $w.end
            if ($sMin -eq $eMin) { continue }
            $cand = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour ([int]($sMin / 60)) -Minute ($sMin % 60) -Second 0
            if ($cand -gt $Now) { return $cand.ToString('yyyy-MM-dd HH:mm') }
        }
    }
    $null
}

# ---------- hosts 操作 ----------

function Get-AfsHostsText {
    param([string]$Path)
    if (Test-Path $Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } else { '' }
}

function Remove-AfsHostsBlockFromText {
    param([string]$Text)
    $lines  = $Text -split "`r?`n"
    $out    = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($ln in $lines) {
        if ($ln.Trim() -eq $script:AFS_MARK_START) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($ln.Trim() -eq $script:AFS_MARK_END) { $inBlock = $false }
            continue
        }
        $out.Add($ln)
    }
    ($out -join "`r`n").TrimEnd("`r`n")
}

function Get-AfsHostsState {
    param([string]$Path)
    try {
        $text = Get-AfsHostsText -Path $Path
        if ($text -match [regex]::Escape($script:AFS_MARK_START)) { return 'blocked' }
        return 'clean'
    } catch { return 'error' }
}

function Set-AfsHostsBlock {
    param([string[]]$Domains, [string]$Path)
    $text  = Get-AfsHostsText -Path $Path
    $clean = Remove-AfsHostsBlockFromText -Text $text
    $domains = @($Domains | Where-Object { $_ } | Sort-Object -Unique)
    if ($domains.Count -gt 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add($script:AFS_MARK_START)
        foreach ($d in $domains) {
            $lines.Add("0.0.0.0 $d")
            $lines.Add(":: $d")
        }
        $lines.Add($script:AFS_MARK_END)
        $newText = ($clean.TrimEnd("`r`n") + "`r`n" + ($lines -join "`r`n") + "`r`n")
    } else {
        $newText = $clean
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $newText, $utf8)
}

function Remove-AfsHostsBlock {
    param([string]$Path)
    $text  = Get-AfsHostsText -Path $Path
    $clean = Remove-AfsHostsBlockFromText -Text $text
    $utf8  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $clean + "`r`n", $utf8)
}

# ---------- 进程 ----------

function Get-AfsProcessKillList {
    param($Config)
    $wl = @($Config.whitelist.processes | Where-Object { $_ } |
        ForEach-Object { $_.Trim().ToLower() -replace '\.exe$','' })
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Config.blockedProcesses)) {
        $name = ($p.Trim() -replace '\.exe$','').ToLower()
        if (-not $name) { continue }
        if ($script:AFS_PROTECTED -contains $name) { continue }
        $skip = $false
        foreach ($w in $wl) { if ($name -like $w) { $skip = $true; break } }
        if (-not $skip) { $list.Add($name) }
    }
    @($list)
}

# ---------- 执行 ----------

function Invoke-AfsLocked {
    param([scriptblock]$Action)
    $lockPath = $script:AFS_LOCK_PATH
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try { return & $Action } finally { $fs.Close() }
        } catch { Start-Sleep -Milliseconds 200 }
    }
    # 锁只是防御性的: 真拿不到就警告并继续, 不阻塞功能
    Write-Warning "无法获取锁文件 $lockPath (继续执行, 可能有并发写入)"
    & $Action
}

function Set-AfsLog {
    param([string]$Path, $Log)
    Write-AfsJson -Path $Path -Object $Log
}

# 核心: 根据配置执行一次屏蔽/解除
function Invoke-AfsEnforce {
    param(
        $Config,
        [string]$HostsPath,
        [switch]$Simulate,
        [string]$LogPath
    )
    $state  = Get-AfsActiveState -Config $Config
    $active = $state.active
    $log = @{
        time   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        active = $active
        reason = $state.reason
        hosts  = 'clean'
        killed = @()
    }
    try {
        if ($active) {
            if ($Config.blockWebsites) {
                $sites   = @($Config.blockedSites | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
                $wlSites = @($Config.whitelist.sites | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
                $toBlock = @($sites | Where-Object { $wlSites -notcontains $_ })
                if ($Simulate) {
                    $log.hosts = "simulate-block($($toBlock.Count) domains)"
                } else {
                    Set-AfsHostsBlock -Domains $toBlock -Path $HostsPath
                    $log.hosts = "blocked($($toBlock.Count) domains)"
                }
            }
            if (-not $Simulate) {
                $killList = Get-AfsProcessKillList -Config $Config
                $killed = New-Object System.Collections.Generic.List[string]
                foreach ($n in $killList) {
                    foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                        try {
                            Stop-Process -Id $pr.Id -Force -ErrorAction Stop
                            $killed.Add("$n($($pr.Id))")
                        } catch { }
                    }
                }
                $log.killed = @($killed | Select-Object -Unique)
            }
        } else {
            if ($Simulate) {
                $log.hosts = 'simulate-clean'
            } else {
                Remove-AfsHostsBlock -Path $HostsPath
                $log.hosts = 'clean'
            }
        }
        # 过期 override 自动清理
        if ($Config.override.mode -ne 'none' -and $Config.override.until) {
            $until = [datetime]::MinValue   # 必须类型化, 否则 [ref] 无法匹配 TryParse 重载
            if ([datetime]::TryParse([string]$Config.override.until, [ref]$until)) {
                if ((Get-Date) -ge $until) {
                    $Config.override.mode  = 'none'
                    $Config.override.until = $null
                    if (-not $Simulate) { Set-AfsConfigSafe -InputConfig $Config }
                }
            }
        }
    } catch {
        $log.error = $_.Exception.Message
    }
    if ($LogPath) { Set-AfsLog -Path $LogPath -Log $log }
    $log
}

# ---------- 计划任务信息 ----------

function Get-AfsTaskInfo {
    $ErrorActionPreference = 'Continue'   # 任务不存在时 schtasks 会写 stderr, 不能被 Stop 变成终止错误
    $out = schtasks /Query /TN "AwayFromShorts" 2>&1
    $text = ($out | Out-String)
    if ($text -match 'ERROR|错误') { return @{ exists = $false } }
    $status = 'unknown'
    foreach ($line in $out) {
        if ($line -match '^\s*(正在运行|Running)' -or $line -match '正在运行') { $status = 'running'; break }
        if ($line -match '^\s*(就绪|Ready)') { $status = 'ready' }
    }
    @{ exists = $true; status = $status }
}
