# ============================================================
#  AwayFromShorts - core.ps1 (共享核心函数)
#  https://github.com/sdgfdii/AwayFromShorts
#  兼容 Windows PowerShell 5.1 (无需任何第三方依赖)
# ============================================================

$script:AFS_NAME        = 'AwayFromShorts'
$script:AFS_VERSION     = '1.3.6'
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
        blockedProcesses = @('chrome','msedge','VALORANT-Win64-Shipping','VALORANT','无畏契约登录器','RiotClientServices','UnrealCEFSubProcess','ACE-Tray','ACE-Helper','ACE-Service64','AclosGameProxy')
        whitelist = @{ sites = @(); processes = @() }
        override = @{ mode = 'none'; until = $null }
        force = @{ enabled = $false; until = $null; weekdays = @() }   # 强制模式: 所选星期内强制, 强制中不可关闭(防破戒)
        web = @{ port = 8737 }

        browser = @{
            enabled  = $true    # 屏蔽时优雅关闭标题匹配的浏览器窗口(工作区), 其他窗口不受影响
            windows  = @()      # 窗口标题列表(支持 * 通配符), 例如 '娱乐'
            urlBlock = $false   # 附加: 浏览器 URLBlocklist 策略拦截 blockedSites 域名(导航层无法绕过, 需重启浏览器生效)
            targets  = @('edge','chrome')   # 生效浏览器
        }
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
        return ,$arr   # 一元逗号: 防止单元素数组被 PS 自动展开成标量
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
    if ($null -ne $Overlay) { return ,$Overlay }   # 一元逗号: 数组(尤其单元素)原样返回, 不被展开成标量
    $Base
}

# 列表规范化: 数组原样, 哈希表取 Keys, 标量包成数组 (防止对象被 ToString 成 "System.Collections.Hashtable")
function Normalize-AfsList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value.Keys) }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value) }
    return @($Value)
}

# 校验 + 规范化 + 落盘
function Set-AfsConfigSafe {
    param($InputConfig)
    $cfg = Merge-AfsDeep -Base (Get-AfsDefaultConfig) -Overlay $InputConfig
$null = $cfg.Remove('clash')   # Clash 接管功能已移除 (v1.2.7): 清理旧配置残留
    $cfg.enabled = [bool]$cfg.enabled

    $cfg.schedule.days = @(Normalize-AfsList $cfg.schedule.days | ForEach-Object { try { [int]$_ } catch { 0 } } |
        Where-Object { $_ -ge 1 -and $_ -le 7 } | Sort-Object -Unique)

    $cfg.schedule.windows = @(Normalize-AfsList $cfg.schedule.windows | ForEach-Object {
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
    $cfg.blockedSites = @(Normalize-AfsList $cfg.blockedSites | ForEach-Object { ([string]$_).Trim().ToLower() } |
        Where-Object { $_ -match '^[a-z0-9.\-]+$' } | Sort-Object -Unique)
    $cfg.blockedProcesses = @(Normalize-AfsList $cfg.blockedProcesses | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)

    $cfg.whitelist.sites = @(Normalize-AfsList $cfg.whitelist.sites | ForEach-Object { ([string]$_).Trim().ToLower() } |
        Where-Object { $_ -match '^[a-z0-9.\-]+$' } | Sort-Object -Unique)
    $cfg.whitelist.processes = @(Normalize-AfsList $cfg.whitelist.processes | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)

    if ($cfg.override.mode -notin @('none','block','off')) { $cfg.override.mode = 'none' }
    if (-not $cfg.override.until) { $cfg.override.until = $null }

    # 强制模式: 生效时规范化 until; 未生效时保留用户 enabled 设置 (窗口外开启的强制等下次屏蔽时段自动生效)
    $forceNow = Test-AfsForceActive -Config $cfg
    if ($forceNow.active) {
        $cfg.force.enabled = $true
        $cfg.force.until  = if ($forceNow.until) { $forceNow.until.ToString('o') } else { $null }   # 长期模式(星期循环) until 为空
    } else {
        $cfg.force.until = $null
    }

    try { $cfg.web.port = [int]$cfg.web.port } catch { $cfg.web.port = 8737 }
    if ($cfg.web.port -lt 1 -or $cfg.web.port -gt 65535) { $cfg.web.port = 8737 }

    $cfg.browser.enabled  = [bool]$cfg.browser.enabled
    $cfg.browser.urlBlock = [bool]$cfg.browser.urlBlock
    $cfg.browser.windows = @(Normalize-AfsList $cfg.browser.windows | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)
    $cfg.browser.targets = @(Normalize-AfsList $cfg.browser.targets | ForEach-Object { ([string]$_).Trim().ToLower() } |
        Where-Object { $_ -in @('edge','chrome') } | Sort-Object -Unique)
    if ($cfg.browser.targets.Count -eq 0) { $cfg.browser.targets = @('edge','chrome') }

    Write-AfsJson -Path (Get-AfsConfigPath) -Object $cfg
    $cfg
}

# ---------- 强制模式 ----------
# 强制模式 = config.force 与独立状态文件 force-state.json 双保险:
# 计划任务(enforcer)每分钟兜底: 任一来源生效则强制屏蔽, 并把另一来源修复一致;
# 直接手改 config.json 删掉 force 也破不了戒(1 分钟内被 enforcer 恢复)。

function Get-AfsForceStatePath {
    (Join-Path (Split-Path (Get-AfsConfigPath)) 'force-state.json')
}

function Read-AfsForceState {
    $p = Get-AfsForceStatePath
    if (-not (Test-Path $p)) { return $null }
    try {
        ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)))
    } catch { $null }
}

function Save-AfsForceState {
    param([string]$Until)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsForceStatePath), (ConvertTo-Json @{ until = $Until }), $utf8)
}

function Remove-AfsForceState {
    $p = Get-AfsForceStatePath
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# 返回 @{ active=$bool; until=$datetime|null } — 仅在屏蔽计划窗口内生效 (时段外不强制)
function Test-AfsForceActive {
    param($Config, [datetime]$Now = (Get-Date))
    if (-not $Config.force.enabled) { return @{ active = $false; until = $null } }
    # 可选"强制星期"过滤: force.weekdays 非空时仅所选星期强制 (星期语义 1=周一..7=周日, 与屏蔽计划一致)
    $fWds = @($Config.force.weekdays | Where-Object { $null -ne $_ })
    if ($fWds.Count -gt 0) {
        $dayNum = [int]$Now.DayOfWeek
        if ($dayNum -eq 0) { $dayNum = 7 }
        if ($fWds -notcontains $dayNum) { return @{ active = $false; until = $null } }
    }
    # 强制模式只在用户设置的屏蔽时段内生效: 时段外不强制, 可正常关闭/解除
    if (-not (Test-AfsInScheduleWindow -Config $Config -Now $Now)) {
        return @{ active = $false; until = $null }
    }
    # 窗口内: 取 config 与独立状态文件两来源较晚的 until (仅用于显示剩余时间/防手改; 不因 until 过期失效)
    $until = $null
    if ($Config.force.until) {
        $t = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Config.force.until, [ref]$t)) { if ($null -eq $until -or $t -gt $until) { $until = $t } }
    }
    $st = Read-AfsForceState
    if ($st -and $st.until) {
        $t = [datetime]::MinValue
        if ([datetime]::TryParse([string]$st.until, [ref]$t)) { if ($null -eq $until -or $t -gt $until) { $until = $t } }
    }
    if ($null -eq $until) {
        # 长期模式(星期循环, 无到期日): config 与状态文件都无 until 时按"持续生效"处理
        return @{ active = $true; until = $null }
    }
    if ($until -lt $Now) { return @{ active = $false; until = $null } }                         # 仅兼容旧式单次强制(带 until)跨天过期: 由引擎自动清理
    @{ active = $true; until = $until }
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

# 当前时间是否落在屏蔽计划窗口内 (schedule.days + windows, 支持跨午夜)
function Test-AfsInScheduleWindow {
    param($Config, [datetime]$Now = (Get-Date))
    $dayNum = [int]$Now.DayOfWeek      # 0=周日
    if ($dayNum -eq 0) { $dayNum = 7 } # 统一成 1=周一 .. 7=周日
    if (@($Config.schedule.days) -notcontains $dayNum) { return $false }
    $nowMin = $Now.Hour * 60 + $Now.Minute
    foreach ($w in @($Config.schedule.windows)) {
        if (Test-AfsInWindow -Start $w.start -End $w.end -NowMin $nowMin) { return $true }
    }
    $false
}

function Get-AfsActiveState {
    param($Config, [datetime]$Now = (Get-Date))
    # 强制模式最高优先级: 生效期间无论如何都屏蔽 (压过 enabled/override/schedule)
    $force = Test-AfsForceActive -Config $Config
    if ($force.active) { return @{ active = $true; reason = 'force' } }

    if (-not $Config.enabled) { return @{ active = $false; reason = 'disabled' } }

    $ov = $Config.override
    if ($ov.mode -ne 'none' -and $ov.until) {
        $until = [datetime]::MinValue   # 必须类型化, 否则 [ref] 无法匹配 TryParse 重载
        if ([datetime]::TryParse([string]$ov.until, [ref]$until)) {
            if ($Now -lt $until) {
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
    # 当前正在屏蔽中 -> 没有"下一次"
    if ((Get-AfsActiveState -Config $Config -Now $Now).active) { return $null }
    # 候选时刻 = override-off 到期时刻 + 未来各计划窗口的开始时刻
    # (临时解除 30 分钟但到期时仍在屏蔽窗口内 -> 到期即恢复屏蔽, 不能只找下一个窗口)
    $cands = New-Object System.Collections.Generic.List[datetime]
    $ov = $Config.override
    if ($ov.mode -eq 'off' -and $ov.until) {
        $u = [datetime]::MinValue
        if ([datetime]::TryParse([string]$ov.until, [ref]$u) -and $u -gt $Now) { $cands.Add($u) }
    }
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
            if ($cand -gt $Now) { $cands.Add($cand) }
        }
    }
    # 按时间排序, 逐个检查该时刻是否真的进入屏蔽 (override 可能已过期/仍在生效)
    foreach ($c in ($cands | Sort-Object)) {
        $s = Get-AfsActiveState -Config $Config -Now $c
        if ($s.active) { return $c.ToString('yyyy-MM-dd HH:mm') }
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

# ---------- 临时解除(破戒)统计 ----------
# 统计"取消屏蔽/临时解除"的次数与时长: 每次用户点「临时解除」(override.mode=off)
# 且当前确实处于解除状态(reason=override-off)时开始计时, 屏蔽恢复/被清除/被强制压过时结算。
# 数据存独立 stats.json (不写入 config, 不参与云同步); 引擎每分钟运行自然驱动状态机。

$script:AFS_STATS_FILE = 'stats.json'
$script:AFS_STATS_MAX  = 1000   # 保留事件上限, 超出裁剪最旧

function Get-AfsStatsPath { (Join-Path (Split-Path (Get-AfsConfigPath)) $script:AFS_STATS_FILE) }

function Read-AfsStats {
    $p = Get-AfsStatsPath
    if (Test-Path $p) {
        try { return ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8))) } catch { }
    }
    @{ open = $null; events = @() }
}

function Save-AfsStats {
    param($Stats)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsStatsPath), (ConvertTo-Json $Stats -Depth 6), $utf8)
}

function Format-AfsMinTime { param([datetime]$T) $T.ToString('yyyy-MM-dd HH:mm') }

# 每次屏蔽引擎运行时调用(锁内, 非 Simulate):
#   进入 override-off -> 开启/延长当前解除会话;
#   退出 override-off(恢复屏蔽/强制压过/手动清除/总开关关闭) -> 结算一次事件
function Update-AfsUnlockStats {
    param($Config, [string]$Reason, [datetime]$Now = (Get-Date))
    $stats = Read-AfsStats
    $changed = $false
    if ($Reason -eq 'override-off') {
        $untilStr = $null
        if ($Config.override -and $Config.override.until) {
            $u = [datetime]::MinValue
            if ([datetime]::TryParse([string]$Config.override.until, [ref]$u)) { $untilStr = $u.ToString('o') }
        }
        if ($null -eq $stats.open) {
            $stats.open = @{ start = Format-AfsMinTime $Now; until = $untilStr }
            $changed = $true
        } elseif ($untilStr -and $stats.open.until -ne $untilStr) {
            $stats.open.until = $untilStr   # 再次点解除 = 延长本次, 不重复计次
            $changed = $true
        }
    } elseif ($null -ne $stats.open) {
        $start = [datetime]::MinValue
        [void][datetime]::TryParse([string]$stats.open.start, [ref]$start)
        # cap session end at override expiry (until): when the engine was down
        # (shutdown/sleep) it must not count downtime as unblock time
        $end = $Now
        if ($stats.open.until) {
            $u = [datetime]::MinValue
            if ([datetime]::TryParse([string]$stats.open.until, [ref]$u) -and $u -lt $end -and $u -gt $start) { $end = $u }
        }
        $mins = [Math]::Max(1, [int][Math]::Round(($end - $start).TotalMinutes))
        $stats.events = @($stats.events + @{
            start = $stats.open.start
            end   = Format-AfsMinTime $end
            min   = $mins
        })
        $stats.open = $null
        $changed = $true
    }
    if ($changed) {
        if (@($stats.events).Count -gt $script:AFS_STATS_MAX) {
            $stats.events = @($stats.events | Select-Object -Last $script:AFS_STATS_MAX)
        }
        Save-AfsStats $stats
    }
}

function Clear-AfsStats {
    $p = Get-AfsStatsPath
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# ---------- 活动时间统计 (ActivityWatch 式) ----------
# 记录"前台使用时间": 由面板(交互会话)每 60 秒采样一次前台窗口,
# 进程/站点按天聚合到 activity.json; 超过 3 分钟无键鼠输入视为离开, 不计时。
# 引擎(S4U 会话)无法访问桌面, 不参与采样。进程分钟数=前台活跃分钟(已剔除离开时间)。

$script:AFS_ACTIVITY_FILE = 'activity.json'
$script:AFS_ACTIVITY_KEEP  = 60

function Get-AfsActivityPath { (Join-Path (Split-Path (Get-AfsConfigPath)) $script:AFS_ACTIVITY_FILE) }

function Read-AfsActivity {
    $p = Get-AfsActivityPath
    if (Test-Path $p) {
        try { return ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8))) } catch { }
    }
    @{ version = 1; days = @{} }
}

function Save-AfsActivity {
    param($Activity)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsActivityPath), (ConvertTo-Json $Activity -Depth 12), $utf8)
}

# Win32: 前台窗口 / 全局输入空闲检测 (需交互会话)
$csNative = @(
    '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'
    '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);'
    '[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);'
    'public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }'
)
try { Add-Type -Namespace AfsWin32 -Name Native -MemberDefinition ($csNative -join "`n") -ErrorAction Stop } catch { }

function Get-AfsIdleSeconds {
    try {
        $i = New-Object AfsWin32.Native+LASTINPUTINFO
        $i.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][AfsWin32.Native+LASTINPUTINFO])
        if ([AfsWin32.Native]::GetLastInputInfo([ref]$i)) {
            $now = [uint32][Environment]::TickCount
            $diff = [int]($now - $i.dwTime)
            if ($diff -lt 0) { $diff = 0 }
            return [int]($diff / 1000)
        }
    } catch { }
    return 0
}

$script:AFS_SITE_WORDS = @('bilibili','youtube','douyin','tiktok','instagram','kuaishou','weibo','zhihu','reddit','pinterest','snapchat','huya','twitch','xiaohongshu','tieba','xiaoheihe','b23','acfun')

function Invoke-AfsActivitySample {
    $a = Read-AfsActivity
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $a.days.ContainsKey($today)) { $a.days[$today] = @{ apps = @{}; sites = @{} } }
    if ((Get-AfsIdleSeconds) -gt 180) { Save-AfsActivity $a; return }
    $hwnd = [AfsWin32.Native]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { Save-AfsActivity $a; return }
    $wp = [uint32]0
    [void][AfsWin32.Native]::GetWindowThreadProcessId($hwnd, [ref]$wp)
    $proc = Get-Process -Id $wp -ErrorAction SilentlyContinue
    if (-not $proc) { Save-AfsActivity $a; return }
    $app = $proc.ProcessName
    if (-not $app) { Save-AfsActivity $a; return }
    $title = ''
    try { $title = [string]$proc.MainWindowTitle } catch { }
    $d = $a.days[$today]
    if (-not $d.apps.ContainsKey($app)) { $d.apps[$app] = 0 }
    $d.apps[$app] = [int]$d.apps[$app] + 1
    if ($app -in @('msedge','chrome','firefox','opera','brave','vivaldi') -and $title) {
        $tl = $title.ToLower()
        foreach ($w in $script:AFS_SITE_WORDS) {
            if ($tl -like "*$w*") {
                if (-not $d.sites.ContainsKey($w)) { $d.sites[$w] = 0 }
                $d.sites[$w] = [int]$d.sites[$w] + 1
                break
            }
        }
    }
    $keys = @($a.days.Keys | Sort-Object -Descending)
    if ($keys.Count -gt $script:AFS_ACTIVITY_KEEP) {
        foreach ($k in $keys | Select-Object -Skip $script:AFS_ACTIVITY_KEEP) { $a.days.Remove($k) }
    }
    Save-AfsActivity $a
}
# ---------- 浏览器窗口(工作区)屏蔽 ----------
# 屏蔽时优雅关闭标题匹配的浏览器窗口(例如 Edge 的"娱乐"工作区), 其他窗口/工作区不受影响。
# 关闭动作必须跑在用户交互会话里(S4U 计划任务无法操作桌面窗口),
# 所以由 AwayFromShorts-BrowserClose 交互计划任务执行 close-browser-windows.ps1。
# 附加 urlBlock: 用 Edge/Chrome 的 URLBlocklist 注册表策略在导航层拦截 blockedSites 域名,
# 与代理/DNS 无关无法绕过; 策略变更需重启浏览器生效。

$script:AFS_BROWSER_TASK  = 'AwayFromShorts-BrowserClose'
$script:AFS_BROWSER_CLOSE = 'browser-close.json'
$script:AFS_BROWSER_STATE = 'browser-state.json'

function Get-AfsBrowserClosePath  { (Join-Path (Split-Path (Get-AfsConfigPath)) $script:AFS_BROWSER_CLOSE) }
function Get-AfsBrowserStatePath { (Join-Path (Split-Path (Get-AfsConfigPath)) $script:AFS_BROWSER_STATE) }

function Read-AfsBrowserState {
    $p = Get-AfsBrowserStatePath
    if (Test-Path $p) {
        try { return ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8))) } catch { }
    }
    @{ applied = $false }
}

function Save-AfsBrowserState {
    param([bool]$Applied)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsBrowserStatePath), (ConvertTo-Json @{ applied = $Applied }), $utf8)
}

# 域名列表 -> URLBlocklist 通配符模式 (覆盖 http/https/ws 及子域)
function ConvertTo-AfsUrlPatterns {
    param($Domains)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($Domains)) {
        $d = ([string]$d).Trim().ToLower()
        if (-not $d -or $d -notmatch '^[a-z0-9.\-]+$') { continue }
        $out.Add("*://$d/*")
        $out.Add("*://*.$d/*")
    }
    @($out | Select-Object -Unique)
}

function Get-AfsBrowserPolicyPaths {
    param($Targets)
    $map = @{ edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome' }
    @($Targets | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } } | Select-Object -Unique)
}

# 写入 URL 拦截策略, 返回拦截域名数
function Set-AfsBrowserPolicy {
    param($Config)
    $sites   = @($Config.blockedSites | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $wlSites = @($Config.whitelist.sites | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $toBlock = @($sites | Where-Object { $wlSites -notcontains $_ })
    $blockPatterns = ConvertTo-AfsUrlPatterns -Domains $toBlock
    $allowPatterns = ConvertTo-AfsUrlPatterns -Domains $wlSites
    foreach ($root in Get-AfsBrowserPolicyPaths -Targets $Config.browser.targets) {
        New-Item -Path $root -Force | Out-Null
        Remove-Item (Join-Path $root 'URLBlocklist') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $root 'URLAllowlist') -Recurse -Force -ErrorAction SilentlyContinue
        if ($blockPatterns.Count) {
            $bk = Join-Path $root 'URLBlocklist'
            New-Item -Path $bk -Force | Out-Null
            for ($i = 0; $i -lt $blockPatterns.Count; $i++) {
                New-ItemProperty -Path $bk -Name ([string]($i + 1)) -Value $blockPatterns[$i] -PropertyType String -Force | Out-Null
            }
        }
        if ($allowPatterns.Count) {
            $ak = Join-Path $root 'URLAllowlist'
            New-Item -Path $ak -Force | Out-Null
            for ($i = 0; $i -lt $allowPatterns.Count; $i++) {
                New-ItemProperty -Path $ak -Name ([string]($i + 1)) -Value $allowPatterns[$i] -PropertyType String -Force | Out-Null
            }
        }
    }
    $toBlock.Count
}

function Remove-AfsBrowserPolicy {
    param($Config)
    foreach ($root in Get-AfsBrowserPolicyPaths -Targets $Config.browser.targets) {
        Remove-Item (Join-Path $root 'URLBlocklist') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $root 'URLAllowlist') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 触发浏览器交互任务: 写载荷(browser-close.json) + 幂等创建任务 + /Run
# RestartAll: 关闭所有浏览器窗口后重新打开 (URLBlocklist 变更后重启使策略生效)
function Invoke-AfsBrowserWindowClose {
    param($Config, [switch]$RestartAll)
    # 只按用户配置的窗口标题(工作区名, 如"娱乐")关闭窗口 —— 刻意不做"标题含屏蔽站点名"兜底:
    # 那会把普通工作窗口(如在工作区看 B 站教程/知乎)一并误关; 导航层拦截由 urlBlock 负责。
    $payload = @{
        patterns   = @($Config.browser.windows | Where-Object { $_ })
        targets    = @($Config.browser.targets)
        restartAll = [bool]$RestartAll
    }
    Write-AfsJson -Path (Get-AfsBrowserClosePath) -Object $payload
    # 用 wscript.exe + VBS 隐藏启动 (GUI 子系统, 无控制台窗口) —— 直接跑 powershell 即使 -WindowStyle Hidden
    # 控制台分配瞬间仍会闪黑窗, 这是"每分钟闪弹窗"的根因
    $vbsPath = Join-Path (Split-Path (Get-AfsConfigPath)) 'close-browser.vbs'
    # 用 XML 创建任务: 必须关闭电池限制 (DisallowStartIfOnBatteries/StopIfGoingOnBatteries=false),
    # 否则笔记本用电池时任务不启动, 窗口屏蔽会静默失效 (schtasks /SC ONCE 默认电池限制为 true)
    # InteractiveToken: 交互会话才能关闭桌面窗口; 不存密码
    $xml = '<?xml version="1.0" encoding="UTF-16"?>' + "`r`n" +
           '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + "`r`n" +
           '  <RegistrationInfo>' + "`r`n" +
           '    <Date>' + (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') + '</Date>' + "`r`n" +
           '    <Author>AwayFromShorts</Author>' + "`r`n" +
           '    <URI>\' + $script:AFS_BROWSER_TASK + '</URI>' + "`r`n" +
           '  </RegistrationInfo>' + "`r`n" +
           '  <Principals>' + "`r`n" +
           '    <Principal id="Author">' + "`r`n" +
           '      <LogonType>InteractiveToken</LogonType>' + "`r`n" +
           '    </Principal>' + "`r`n" +
           '  </Principals>' + "`r`n" +
           '  <Settings>' + "`r`n" +
           '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' + "`r`n" +
           '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' + "`r`n" +
           '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' + "`r`n" +
           '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' + "`r`n" +
           '    <IdleSettings>' + "`r`n" +
           '      <StopOnIdleEnd>false</StopOnIdleEnd>' + "`r`n" +
           '    </IdleSettings>' + "`r`n" +
           '  </Settings>' + "`r`n" +
           '  <Triggers>' + "`r`n" +
           '    <TimeTrigger>' + "`r`n" +
           '      <StartBoundary>' + (Get-Date -Format 'yyyy-MM-dd') + 'T00:00:00</StartBoundary>' + "`r`n" +
           '      <Repetition>' + "`r`n" +
           '        <Interval>PT1M</Interval>' + "`r`n" +
           '        <StopAtDurationEnd>false</StopAtDurationEnd>' + "`r`n" +
           '      </Repetition>' + "`r`n" +
           '    </TimeTrigger>' + "`r`n" +
           '  </Triggers>' + "`r`n" +
           '  <Actions Context="Author">' + "`r`n" +
           '    <Exec>' + "`r`n" +
           '      <Command>"wscript.exe"</Command>' + "`r`n" +
           '      <Arguments>"' + $vbsPath + '"</Arguments>' + "`r`n" +
           '    </Exec>' + "`r`n" +
           '  </Actions>' + "`r`n" +
           '</Task>'
    $xmlPath = Join-Path $env:TEMP 'afs-browserclose-task.xml'
    # schtasks /XML 要求 UTF-16 编码
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & schtasks /Create /F /TN $script:AFS_BROWSER_TASK /XML $xmlPath *> $null
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    & schtasks /Run /TN $script:AFS_BROWSER_TASK *> $null
    $ErrorActionPreference = $prev
}

function Remove-AfsBrowserClose {
    $p = Get-AfsBrowserClosePath
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
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
    # ---- 强制模式: 开启后当天内不可关闭, 到期自动解除 (不自动续期到下一天) ----
    $forceActive = Test-AfsForceActive -Config $Config
    if ($forceActive.active) {
        # 生效中: 补齐独立状态文件 (防手改 json / 删文件破戒)
        if (-not (Test-Path (Get-AfsForceStatePath))) {
            Save-AfsForceState -Until $forceActive.until.ToString('o')
        }
    } elseif ($Config.force.enabled) {
        # 未生效: 仅旧式单次强制(until 非空且已跨天过期)自动关闭;
        # 长期模式(until 为空 = 星期循环)不自动解除, 保留到用户手动关闭(非强制时段可关)
        $expired = $false
        if ($Config.force.until) {
            $fU = [datetime]::MinValue
            $expired = -not [datetime]::TryParse([string]$Config.force.until, [ref]$fU) -or $fU -lt (Get-Date)
        }
        if ($expired) {
            $Config.force.enabled = $false
            $Config.force.until  = $null
            if (-not $Simulate) { Set-AfsConfigSafe -InputConfig $Config | Out-Null }
            Remove-AfsForceState
        }
        # 长期或窗口外未过期: 保留配置, 进入所选星期的屏蔽窗口时自动生效
    }
    $log = @{
        time   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        active = $active
        reason = $state.reason
        hosts  = 'clean'
        killed = @()
        browser = 'off'
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
                if ($Config.browser.enabled) {
                    # 浏览器窗口(工作区)屏蔽生效: 浏览器不按进程强杀, 交给窗口关闭机制
                    $browserNames = @($Config.browser.targets | ForEach-Object { if ($_ -eq 'edge') { 'msedge' } else { 'chrome' } })
                    $killList = @($killList | Where-Object { $browserNames -notcontains $_ })
                }
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

            # 浏览器窗口(工作区)屏蔽: 每分钟触发关闭匹配窗口 (用户重开也会再关)
            if (-not $Simulate -and ($Config.browser.enabled -or $Config.browser.urlBlock)) {
                Invoke-AfsBrowserWindowClose -Config $Config
                $log.browser = "window-block($(@($Config.browser.windows | Where-Object { $_ }).Count) patterns)"
            } elseif (-not $Simulate) {
                Remove-AfsBrowserClose
            }
            # 附加 URL 拦截 (URLBlocklist): 状态机, 仅在 开启/关闭 转变时写策略 + 重启浏览器
            $bState = Read-AfsBrowserState
            if ($Config.browser.urlBlock -and -not $bState.applied) {
                if ($Simulate) { $log.browser = 'simulate-urlblock' }
                else {
                    $n = Set-AfsBrowserPolicy -Config $Config
                    Save-AfsBrowserState -Applied $true
                    $log.browser = "url-block($n domains)"
                    Invoke-AfsBrowserWindowClose -Config $Config -RestartAll   # 重启浏览器使策略生效
                }
            } elseif (-not $Config.browser.urlBlock -and $bState.applied) {
                if ($Simulate) { $log.browser = 'simulate-urlclean' }
                else {
                    Remove-AfsBrowserPolicy -Config $Config
                    Save-AfsBrowserState -Applied $false
                    $log.browser = 'url-clean'
                    Invoke-AfsBrowserWindowClose -Config $Config -RestartAll
                }
            }
        } else {
            if ($Simulate) {
                $log.hosts = 'simulate-clean'
            } else {
                Remove-AfsHostsBlock -Path $HostsPath
                $log.hosts = 'clean'
            }

            # 解除: 移除 URL 拦截策略并重启浏览器恢复; 停止窗口关闭
            $bState = Read-AfsBrowserState
            if ($bState.applied) {
                if ($Simulate) { $log.browser = 'simulate-urlclean' }
                else {
                    Remove-AfsBrowserPolicy -Config $Config
                    Save-AfsBrowserState -Applied $false
                    $log.browser = 'url-clean'
                    Invoke-AfsBrowserWindowClose -Config $Config -RestartAll
                }
            }
            if (-not $Simulate) { Remove-AfsBrowserClose }
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
    # 解除统计状态机 (非干跑): 观察 override-off 进入/退出
    if (-not $Simulate) { Update-AfsUnlockStats -Config $Config -Reason $state.reason }
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

# ---------- 云同步 (GitHub Gist) ----------
# 登录 = 保存 GitHub Personal Access Token (DPAPI 加密, 仅当前 Windows 用户可解)
# 配置通过私有 Gist 同步, 支持多设备共用一份配置
# 安全: Token 只发给 api.github.com, 绝不写入配置文件/日志/Gist

$script:AFS_API_BASE  = 'https://api.github.com'
$script:AFS_GIST_DESC = 'AwayFromShorts 配置同步'
$script:AFS_GIST_FILE = 'config.json'

function Get-AfsSyncDir { (Split-Path (Get-AfsConfigPath)) }
function Get-AfsTokenPath { Join-Path (Get-AfsSyncDir) 'github-token.enc' }
function Get-AfsSyncStatePath { Join-Path (Get-AfsSyncDir) 'sync-state.json' }

# 保存 Token: ConvertFrom-SecureString 默认用 DPAPI(当前用户+机器), 密文落盘
function Save-AfsGitHubToken {
    param([string]$Token)
    if (-not $Token) { throw 'Token 不能为空' }
    $sec = ConvertTo-SecureString $Token -AsPlainText -Force
    $enc = ConvertFrom-SecureString $sec
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsTokenPath), $enc, $utf8)
}

function Get-AfsGitHubToken {
    $p = Get-AfsTokenPath
    if (-not (Test-Path $p)) { return $null }
    try {
        $enc = [System.IO.File]::ReadAllText($p)
        $sec = ConvertTo-SecureString $enc
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return $null }
}

function Clear-AfsGitHubToken {
    $p = Get-AfsTokenPath
    if (Test-Path $p) { Remove-Item $p -Force }
    $s = Get-AfsSyncStatePath
    if (Test-Path $s) { Remove-Item $s -Force }
}

function Get-AfsSyncState {
    $p = Get-AfsSyncStatePath
    if (Test-Path $p) {
        try { return ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8))) } catch { }
    }
    @{ gistId = $null; lastSync = $null; autoPush = $false }
}

function Save-AfsSyncState {
    param($State)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Get-AfsSyncStatePath), (ConvertTo-Json $State -Depth 6), $utf8)
}

# GitHub API 封装: 强制 TLS1.2, 统一错误处理 (401/403/404 转成中文信息)
function Invoke-AfsGitHubApi {
    param([string]$Method, [string]$Path, $Body, [string]$Token, [int]$TimeoutSec = 20)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }
    $headers = @{
        'Authorization' = 'token ' + $Token
        'Accept'        = 'application/vnd.github+json'
        'User-Agent'    = 'AwayFromShorts/' + $script:AFS_VERSION
    }
    $params = @{ Method = $Method; Uri = $script:AFS_API_BASE + $Path; Headers = $headers; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $params.Body = $Body; $params.ContentType = 'application/json; charset=utf-8' }
    try {
        $resp = Invoke-RestMethod @params
        ConvertTo-AfsHashtable $resp
    } catch {
        $msg = $_.Exception.Message
        $code = $null
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            try {
                $rs = $_.Exception.Response
                $code = [int]$rs.StatusCode
                $reader = New-Object System.IO.StreamReader($rs.GetResponseStream())
                $raw = $reader.ReadToEnd()
                $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed -and $parsed.message) { $msg = $parsed.message }
            } catch { }
        }
        if ($code -eq 401) { throw "GitHub 认证失败(401): Token 无效或已过期" }
        if ($code -eq 403) { throw "GitHub 拒绝访问(403): $msg" }
        if ($code -eq 404) { throw "GitHub 资源不存在(404): $msg" }
        throw "GitHub API 请求失败: $msg"
    }
}

# 验证 Token 并返回用户信息 (login/name/email)
function Get-AfsGitHubUser {
    param([string]$Token)
    Invoke-AfsGitHubApi -Method 'GET' -Path '/user' -Token $Token
}

function Test-AfsGitHubToken {
    param([string]$Token)
    try { $u = Get-AfsGitHubUser -Token $Token; return $true } catch { return $false }
}

# 同步内容 = 完整配置去掉临时 override(跨设备不该带"临时屏蔽"状态)
function ConvertTo-AfsSyncPayload {
    $cfg = Get-AfsConfig
    $clean = @{}
    foreach ($k in $cfg.Keys) { if ($k -ne 'override') { $clean[$k] = $cfg[$k] } }
    ConvertTo-Json $clean -Depth 12
}

# 在账号的 Gist 列表里找同步 Gist (按 description 匹配), 找不到返回 $null
function Find-AfsSyncGist {
    param([string]$Token)
    $gists = Invoke-AfsGitHubApi -Method 'GET' -Path '/gists?per_page=100' -Token $Token
    foreach ($g in @($gists)) {
        if ($g.description -eq $script:AFS_GIST_DESC) { return $g.id }
    }
    return $null
}

# 推送本机配置到私有 Gist (没有则创建, 有则更新)
function Push-AfsSyncConfig {
    param([string]$Token)
    $state = Get-AfsSyncState
    $gistId = $state.gistId
    if (-not $gistId) { $gistId = Find-AfsSyncGist -Token $Token }
    $content = ConvertTo-AfsSyncPayload
    if ($gistId) {
        $body = @{ files = @{ $script:AFS_GIST_FILE = @{ content = $content } } } | ConvertTo-Json -Depth 8
        Invoke-AfsGitHubApi -Method 'PATCH' -Path ('/gists/' + $gistId) -Token $Token -Body $body
    } else {
        $body = @{
            description = $script:AFS_GIST_DESC
            public      = $false
            files       = @{ $script:AFS_GIST_FILE = @{ content = $content } }
        } | ConvertTo-Json -Depth 8
        $new = Invoke-AfsGitHubApi -Method 'POST' -Path '/gists' -Token $Token -Body $body
        $gistId = $new.id
    }
    $state.gistId = $gistId
    $state.lastSync = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-AfsSyncState $state
    $state
}

# 从云端 Gist 拉取配置覆盖本机 (覆盖前自动备份)
function Pull-AfsSyncConfig {
    param([string]$Token)
    $state = Get-AfsSyncState
    $gistId = $state.gistId
    if (-not $gistId) { $gistId = Find-AfsSyncGist -Token $Token }
    if (-not $gistId) { throw '云端没有找到同步配置(请先在其他设备上推送一次)' }
    $gist = Invoke-AfsGitHubApi -Method 'GET' -Path ('/gists/' + $gistId) -Token $Token
    $file = $gist.files[$script:AFS_GIST_FILE]
    if (-not $file -or -not $file.content) { throw '云端 Gist 中没有 config.json' }
    $cfgPath = Get-AfsConfigPath
    $bak = $null
    if (Test-Path $cfgPath) {
        $bak = $cfgPath + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item $cfgPath $bak -Force
    }
    $parsed = ConvertTo-AfsHashtable (ConvertFrom-Json $file.content -ErrorAction Stop)
    $newCfg = Set-AfsConfigSafe -InputConfig $parsed
    $state.gistId = $gistId
    $state.lastSync = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-AfsSyncState $state
    @{ config = $newCfg; backup = $bak }
}

# 给面板用的账号信息 (无 Token / Token 失效都返回可序列化的结构)
function Get-AfsAccountInfo {
    $token = Get-AfsGitHubToken
    if (-not $token) { return @{ loggedIn = $false } }
    try {
        $u = Get-AfsGitHubUser -Token $token
        $state = Get-AfsSyncState
        @{
            loggedIn = $true
            login    = $u.login
            name     = if ($u.name) { $u.name } else { $null }
            email    = if ($u.email) { $u.email } else { $null }
            gistId   = $state.gistId
            lastSync = $state.lastSync
            autoPush = [bool]$state.autoPush
        }
    } catch {
        @{ loggedIn = $false; error = $_.Exception.Message }
    }
}
