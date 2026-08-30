# ============================================================
#  AwayFromShorts - core.ps1 (共享核心函数)
#  https://github.com/sdgfdii/AwayFromShorts
#  兼容 Windows PowerShell 5.1 (无需任何第三方依赖)
# ============================================================

$script:AFS_NAME        = 'AwayFromShorts'
$script:AFS_VERSION     = '1.2.5'
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
        force = @{ enabled = $false; until = $null }   # 强制模式: 一旦开启, 当天 24:00 前无法关闭/解除屏蔽
        web = @{ port = 8737 }
        clash = @{
            enabled      = $true   # 屏蔽时接管 Clash: 关系统代理 + 禁 TUN
            systemProxy  = $true   # 关/恢复 Windows 系统代理
            tun          = $true   # 禁/启 TUN 虚拟网卡
            tunAdapter   = 'Meta'  # TUN 网卡名 (Clash Verge Rev 默认 'Meta', 找不到则自动探测)
        }
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
        $cfg.force.until  = $forceNow.until.ToString('o')
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
    if ($null -eq $until) { $until = $Now.Date.AddDays(1).AddSeconds(-1) }   # 默认当天结束, 避免 null.ToString 崩溃
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
    if ((Get-AfsActiveState -Config $Config -Now $Now).active) { return $null }
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

# ---------- Clash 代理/TUN 控制 ----------
# 屏蔽时: 关系统代理 + 禁 TUN 网卡, 防止流量走 Clash 绕过 hosts 屏蔽
# 解除时: 按屏蔽前记录的原状态恢复

$script:AFS_CLASH_STATE = 'clash-state.json'

function Get-AfsClashStatePath {
    (Join-Path (Split-Path (Get-AfsConfigPath)) $script:AFS_CLASH_STATE)
}

function Read-AfsClashState {
    $p = Get-AfsClashStatePath
    if (Test-Path $p) {
        try { Read-AfsJson -Path $p } catch { $null }
    } else { $null }
}

function Save-AfsClashState {
    param($State)
    Write-AfsJson -Path (Get-AfsClashStatePath) -Object $State
}

function Remove-AfsClashState {
    $p = Get-AfsClashStatePath
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# 读 Windows 系统代理当前状态 (注册表 WinINET)
function Get-AfsSystemProxyState {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $v = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    @{
        enabled = ([int]$v.ProxyEnable -eq 1)
        server  = [string]$v.ProxyServer
    }
}

function Set-AfsSystemProxyEnabled {
    param([bool]$Enabled, [string]$Server)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        Set-ItemProperty -Path $key -Name ProxyEnable -Value ([int]$Enabled) -ErrorAction Stop
        if ($Enabled -and $Server) { Set-ItemProperty -Path $key -Name ProxyServer -Value $Server -ErrorAction Stop }
    } catch {
        Write-Warning "设置系统代理失败: $($_.Exception.Message)"
    }
}

# 探测 TUN 网卡: 优先用配置名, 找不到就按特征匹配
function Find-AfsTunAdapter {
    param([string]$Preferred)
    if ($Preferred) {
        $a = Get-NetAdapter -Name $Preferred -IncludeHidden -ErrorAction SilentlyContinue
        if ($a) { return $a }
    }
    Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -match 'meta|clash|mihomo|verge') -or ($_.InterfaceDescription -match 'wintun|tunnel') } |
        Select-Object -First 1
}

# 屏蔽时: 记录原状态 + 关闭系统代理和 TUN (幂等: 已关则跳过)
function Invoke-AfsClashOff {
    param($Config, [switch]$Simulate)
    if (-not $Config.clash.enabled) { return }
    $state = Read-AfsClashState
    if (-not $state) {
        $sp = Get-AfsSystemProxyState
        $ad = Find-AfsTunAdapter -Preferred $Config.clash.tunAdapter
        $state = @{
            proxyEnabled = $sp.enabled
            proxyServer  = $sp.server
            tunWasUp     = [bool]($ad -and $ad.Status -eq 'Up')
            tunAdapter   = if ($ad) { $ad.Name } else { $null }
        }
        if (-not $Simulate) { Save-AfsClashState -State $state }
    }
    if ($Simulate) { Write-Output '[simulate] clash-off: 关系统代理 + 禁 TUN'; return }
    if ($Config.clash.systemProxy) { Set-AfsSystemProxyEnabled -Enabled $false }
    if ($Config.clash.tun -and $state.tunAdapter) {
        try {
            $a = Get-NetAdapter -Name $state.tunAdapter -IncludeHidden -ErrorAction SilentlyContinue
            if ($a -and $a.Status -eq 'Up') { Disable-NetAdapter -Name $state.tunAdapter -Confirm:$false -ErrorAction Stop }
        } catch { Write-Warning "禁用 TUN 网卡 $($state.tunAdapter) 失败: $($_.Exception.Message)" }
    }
}

# 解除时: 按记录恢复系统代理和 TUN, 然后清理状态文件
function Invoke-AfsClashRestore {
    param($Config, [switch]$Simulate)
    if (-not $Config.clash.enabled) { return }
    $state = Read-AfsClashState
    if (-not $state) { return }
    if ($Simulate) { Write-Output '[simulate] clash-restore: 恢复系统代理 + 启 TUN'; return }
    if ($Config.clash.systemProxy) {
        Set-AfsSystemProxyEnabled -Enabled ([bool]$state.proxyEnabled) -Server ([string]$state.proxyServer)
    }
    if ($Config.clash.tun -and $state.tunAdapter) {
        try {
            $a = Get-NetAdapter -Name $state.tunAdapter -IncludeHidden -ErrorAction SilentlyContinue
            if ($a -and $a.Status -ne 'Up') { Enable-NetAdapter -Name $state.tunAdapter -Confirm:$false -ErrorAction Stop }
        } catch { Write-Warning "启用 TUN 网卡 $($state.tunAdapter) 失败: $($_.Exception.Message)" }
    }
    Remove-AfsClashState
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
    # 站点关键词: 从 blockedSites 提取主域 (bilibili.com -> bilibili), 用于按"窗口标题含娱乐站点名"兜底匹配
    # (Edge 工作区窗口标题会随活动标签页变化, 只匹配工作区名不可靠)
    $kws = @()
    foreach ($s in @($Config.blockedSites)) {
        $d = ($s -replace '^\*\.', '' -replace '^(www|m|live|mobile|amp)\.', '').ToLower()
        $k = ($d -split '\.')[0]
        # 只保留足够长的关键词(>=4 字符), 避免 t/v/old/b23 这类短词误伤普通窗口标题
        if ($k -and $k.Length -ge 4) { $kws += $k }
    }
    $payload = @{
        patterns     = @($Config.browser.windows | Where-Object { $_ })
        siteKeywords = @($kws | Select-Object -Unique)
        targets      = @($Config.browser.targets)
        restartAll   = [bool]$RestartAll
    }
    Write-AfsJson -Path (Get-AfsBrowserClosePath) -Object $payload
    # 用 wscript.exe + VBS 隐藏启动 (GUI 子系统, 无控制台窗口) —— 直接跑 powershell 即使 -WindowStyle Hidden
    # 控制台分配瞬间仍会闪黑窗, 这是"每分钟闪弹窗"的根因
    $vbsPath = Join-Path (Split-Path (Get-AfsConfigPath)) 'close-browser.vbs'
    $tr = '"wscript.exe" "' + $vbsPath + '"'
    $tr = $tr -replace '"', '\"'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & schtasks /Create /F /TN $script:AFS_BROWSER_TASK /SC ONCE /ST 00:00 /IT /TR $tr *> $null
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
    # ---- 强制模式兜底: 仅在屏蔽计划窗口内生效 ----
    if (Test-AfsInScheduleWindow -Config $Config) {
        # 窗口内: 强制必须生效, 修复 config + 独立状态文件 (防手改 json / 面板关闭破戒)
        $forceNow = Test-AfsForceActive -Config $Config
        if (-not $forceNow.active) { $forceNow = @{ active = $true; until = (Get-Date).Date.AddDays(1).AddSeconds(-1) } }
        $needFix = -not ($Config.force.enabled -and $Config.force.until)
        if ($needFix) {
            $Config.force.enabled = $true
            $Config.force.until  = $forceNow.until.ToString('o')
        }
        if (-not (Test-Path (Get-AfsForceStatePath))) {
            Save-AfsForceState -Until $forceNow.until.ToString('o')
        }
        if ($needFix -and -not $Simulate) { Set-AfsConfigSafe -InputConfig $Config | Out-Null }
    } else {
        # 窗口外: 强制不生效, 保留用户配置 (enabled 留到下个屏蔽时段自动生效), 只清过期状态文件
        Remove-AfsForceState
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
            # 屏蔽时段: 关 Clash 系统代理 + TUN (防绕过 hosts)
            if ($Simulate) { Invoke-AfsClashOff -Config $Config -Simulate } else { Invoke-AfsClashOff -Config $Config }
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
            # 解除屏蔽: 恢复 Clash 原状态
            if ($Simulate) { Invoke-AfsClashRestore -Config $Config -Simulate } else { Invoke-AfsClashRestore -Config $Config }
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
