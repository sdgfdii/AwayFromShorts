# ============================================================
#  AwayFromShorts - Force-mode lock guard offline regression test
#  Usage: powershell -ExecutionPolicy Bypass -File tools/verify-lock.ps1
#
#  覆盖 core.ps1 的 Get-AfsConfigLockDiff / Test-AfsConfigLockViolation 与排队落地逻辑。
#  强制模式生效时段内, 名单类改动只允许"收紧", 不允许"放宽":
#    hard  (拒绝) = 屏蔽星期 / 屏蔽时段 -> 它们定义了"何时算非屏蔽时段", 参与排队会让排队机制自己失效
#    widen (拒绝) = 删屏蔽项 / 关屏蔽开关 / 往白名单加项 -> 都是直接放行
#    queue (排队) = 加屏蔽项 / 开屏蔽开关 / 从白名单删项 -> 方向是更严, 生效时段内先入队
#    none  (放行) = 没改 / 只改大小写或顺序或重复项 / 只改无关字段
#  Exit code: 0 = all pass, 1 = failures
# ============================================================
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\core.ps1')

$script:bad = 0

function New-BaseCfg {
    @{
        blockedSites     = @('douyin.com', 'youtube.com')
        blockedProcesses = @('chrome', 'msedge')
        blockWebsites    = $true
        schedule         = @{ days = @(1, 2, 3); windows = @(@{ start = '07:15'; end = '09:15' }) }
        browser          = @{ enabled = $true; urlBlock = $false; windows = @('Game') }
        whitelist        = @{ sites = @(); processes = @() }
    }
}

function Check {
    param([string]$Name, [bool]$ExpectBlocked, [switch]$ForceActive, $Cur, $New)
    $v = Test-AfsConfigLockViolation -Current $Cur -Incoming $New -ForceActive:$ForceActive
    $blocked = -not [string]::IsNullOrEmpty([string]$v)
    $ok = ($blocked -eq $ExpectBlocked)
    if (-not $ok) { $script:bad++ }
    $tag = if ($blocked) { 'blocked' } else { 'allowed' }
    $fa  = if ($ForceActive) { '[在时段]' } else { '[任意]  ' }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + $fa + ' ' + $tag.PadRight(7) + ' ' + $Name)
}

function CheckDiff {
    param([string]$Name, [string[]]$Expect, $Cur, $New)
    $d = Get-AfsConfigLockDiff -Current $Cur -Incoming $New
    $got = @()
    if (@($d.hardKeys).Count  -gt 0) { $got += 'hard' }
    if (@($d.widenKeys).Count -gt 0) { $got += 'widen' }
    if (@($d.queueKeys).Count -gt 0) { $got += 'queue' }
    if ($got.Count -eq 0) { $got = @('none') }
    $ok = (($got -join '+') -eq (@($Expect) -join '+'))
    if (-not $ok) { $script:bad++ }
    $note = if ($ok) { '' } else { "  (expect $($Expect -join '+'), got $($got -join '+'))" }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + 'class'.PadRight(7) + ' ' + $Name.PadRight(42) + ' -> ' + $got[0] + $note)
}

function CheckBool {
    param([string]$Name, [bool]$Expect, $Actual)
    $ok = ([bool]$Actual -eq $Expect)
    if (-not $ok) { $script:bad++ }
    $note = if ($ok) { '' } else { "  (expect $Expect, got $Actual)" }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + 'state'.PadRight(7) + ' ' + $Name + $note)
}

# ---------------------------------------------------------------
# A. 硬拒项 (屏蔽星期 / 屏蔽时段): 任何时候(force.enabled 即锁)都拒绝
#    放宽类只在"生效时段内"拒绝, 所以本段不传 -ForceActive, 只看硬拒
# ---------------------------------------------------------------
Write-Host '--- A. hard guard (schedule / dropped fields) ---'

Check 'identical config' $false (New-BaseCfg) (New-BaseCfg)

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites     = @('YouTube.com', 'DOUYIN.COM')          # case differs
$n.blockedProcesses = @('msedge', 'chrome', 'MSEDGE')         # order + duplicate
Check 'case / order / duplicate only' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.web      = @{ port = 9000 }
$n.override = @{ mode = 'none'; until = $null }
$n.enabled  = $false
Check 'unrelated fields (web/override/enabled)' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.schedule.windows = @(@{ start = '07:15'; end = '09:15' })   # rebuilt, same content
Check 'schedule.windows rebuilt identical' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites = @('douyin.com', 'youtube.com', '')           # blank entry ignored
Check 'blank entry ignored' $false $c $n

$c = New-BaseCfg
Check 'null incoming (defensive)' $false $c $null
Check 'null current (defensive)' $false $null $c

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2, 3, 4)
Check 'schedule.days: add day' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.windows = @(@{ start = '08:00'; end = '10:00' })
Check 'schedule.windows: change time' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.Remove('whitelist')
Check 'whitelist dropped while empty' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = 'true'
Check 'blockWebsites: truthy string equals bool' $false $c $n

# ---------------------------------------------------------------
# B. 三态分类: hard(星期/时段) / widen(放宽) / queue(收紧)
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- B. classification: hard / widen / queue ---'

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites += 'tiktok.com'
CheckDiff 'blockedSites: add domain  (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites = @('douyin.com')
CheckDiff 'blockedSites: remove domain (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses += 'steam'
CheckDiff 'blockedProcesses: add process (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses = @('chrome')
CheckDiff 'blockedProcesses: remove process (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.windows += 'Entertainment'
CheckDiff 'browser.windows: add workspace (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.windows = @()
CheckDiff 'browser.windows: remove workspace (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = $false
CheckDiff 'blockWebsites: turn ON -> OFF (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.blockWebsites = $false; $n.blockWebsites = $true
CheckDiff 'blockWebsites: turn OFF -> ON (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.urlBlock = $true
CheckDiff 'browser.urlBlock: OFF -> ON (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.browser.urlBlock = $true; $n.browser.urlBlock = $false
CheckDiff 'browser.urlBlock: ON -> OFF (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.enabled = $false
CheckDiff 'browser.enabled: ON -> OFF (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.sites += 'mail.example.com'
CheckDiff 'whitelist.sites: add domain (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.whitelist.sites = @('mail.example.com'); $n.whitelist.sites = @()
CheckDiff 'whitelist.sites: remove domain (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.processes += 'teams'
CheckDiff 'whitelist.processes: add process (widen)' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.whitelist.processes = @('teams'); $n.whitelist.processes = @()
CheckDiff 'whitelist.processes: remove process (tighten)' @('queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2, 3, 4)
CheckDiff 'schedule.days -> hard' @('hard') $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.windows = @(@{ start = '08:00'; end = '10:00' })
CheckDiff 'schedule.windows -> hard' @('hard') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites += 'tiktok.com'
$n.schedule.days = @(1, 2, 3, 4, 5)
CheckDiff 'add domain + change days -> hard+queue' @('hard','queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites = @('douyin.com')
$n.blockedProcesses += 'steam'
CheckDiff 'remove domain + add process -> widen+queue' @('widen','queue') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
CheckDiff 'identical -> none' @('none') $c $n

# 整块字段丢失(等价于把该名单全删 / 把开关全关) -> 放宽
$c = New-BaseCfg; $n = New-BaseCfg; $n.Remove('browser')
CheckDiff 'browser field dropped -> widen' @('widen') $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.whitelist.sites = @('mail.example.com')
$n.Remove('whitelist')
CheckDiff 'whitelist field dropped -> queue' @('queue') $c $n

# ---------------------------------------------------------------
# C. 放宽类只在"生效时段内"被拒; 收紧类在生效时段内也不算违规(它会去排队)
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- C. widen rejected only while force is active ---'

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites = @('douyin.com')
Check 'remove domain'               $false                     $c $n
Check 'remove domain'               $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites += 'tiktok.com'
Check 'add domain (goes to queue)'  $false                     $c $n
Check 'add domain (goes to queue)'  $false -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = $false
Check 'turn master switch off'      $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.sites += 'mail.example.com'
Check 'add to whitelist'            $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.whitelist.sites = @('mail.example.com'); $n.whitelist.sites = @()
Check 'remove from whitelist'       $false -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg
Check 'untouched config'            $false -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2)
Check 'schedule still hard'         $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.Remove('browser')
Check 'browser field dropped'       $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.windows = @()
Check 'clear workspace list'        $true  -ForceActive        $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses = @()
Check 'clear process list'          $true  -ForceActive        $c $n

# ---------------------------------------------------------------
# D. 排队补丁: 只装"收紧"方向的字段
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- D. pending patch carries tighten-only changes ---'

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites += 'tiktok.com'
$n.blockedProcesses += 'steam'
$n.browser.windows += 'Fun'
$np = New-AfsPendingPatch -Current $c -Incoming $n
$pk = (@($np.patch.Keys) | Sort-Object) -join ','
$okPatch = (($pk -eq 'blockedProcesses,blockedSites,browser') -and ($np.total -ge 3))
if (-not $okPatch) { $script:bad++ }
Write-Host (($(if ($okPatch) { 'OK  ' } else { 'FAIL' })) + ' ' + 'patch'.PadRight(7) + " tighten patch keys=[$pk] total=$($np.total)")

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2)
$np2 = New-AfsPendingPatch -Current $c -Incoming $n
$okHard = (@($np2.patch.Keys).Count -eq 0) -and ([int]$np2.total -eq 0)
if (-not $okHard) { $script:bad++ }
Write-Host (($(if ($okHard) { 'OK  ' } else { 'FAIL' })) + ' ' + 'patch'.PadRight(7) + " schedule change never queued (total=$($np2.total))")

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites = @('douyin.com')
$np3 = New-AfsPendingPatch -Current $c -Incoming $n
$okRem = (@($np3.patch.Keys).Count -eq 0) -and ([int]$np3.total -eq 0)
if (-not $okRem) { $script:bad++ }
Write-Host (($(if ($okRem) { 'OK  ' } else { 'FAIL' })) + ' ' + 'patch'.PadRight(7) + " remove-domain never queued (total=$($np3.total))")

$c = New-BaseCfg; $n = New-BaseCfg
$c.blockWebsites = $false; $n.blockWebsites = $true
$c.whitelist.sites = @('mail.example.com'); $n.whitelist.sites = @()
$np4 = New-AfsPendingPatch -Current $c -Incoming $n
$okMix = ((@($np4.patch.Keys) | Sort-Object) -join ',') -eq 'blockWebsites,whitelist'
if (-not $okMix) { $script:bad++ }
Write-Host (($(if ($okMix) { 'OK  ' } else { 'FAIL' })) + ' ' + 'patch'.PadRight(7) + " switch-on + whitelist-shrink queued (total=$($np4.total))")

$c = New-BaseCfg; $n = New-BaseCfg
$c.blockWebsites = $false; $n.blockWebsites = $true
$np5 = New-AfsPendingPatch -Current $c -Incoming $n
$okSw = ([bool]$np5.patch.blockWebsites -eq $true)
if (-not $okSw) { $script:bad++ }
Write-Host (($(if ($okSw) { 'OK  ' } else { 'FAIL' })) + ' ' + 'patch'.PadRight(7) + " switch patch value = true")

# ---------------------------------------------------------------
# E. 落地时机 + "只收紧"合并 (用临时目录做, 不碰真实 config.json)
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- E. queue apply timing + tighten-only merge ---'

$qdir = Join-Path $env:TEMP ('afs-verify-queue-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $qdir | Out-Null
Set-AfsConfigPath -Path (Join-Path $qdir 'config.json')

$bc = Get-AfsDefaultConfig
$bc.force.enabled    = $true
$bc.schedule.days    = @(1, 2, 3, 4, 5, 6, 7)
$bc.schedule.windows = @(@{ start = '00:00'; end = '23:59' })   # 全天窗口 -> 当前必然处于强制生效时段
$bc.blockedSites     = @('douyin.com', 'youtube.com')
$bc.blockedProcesses = @('chrome')
$bc.whitelist        = @{ sites = @('keep.example.com'); processes = @('teams') }
Set-AfsConfigSafe -InputConfig $bc | Out-Null

$want = Get-AfsConfig
$want.blockedSites = @($want.blockedSites) + @('queued-demo.com')
$qs = Save-AfsPendingQueue -Current (Get-AfsConfig) -Incoming $want
CheckBool 'pending 写入成功 (total>0)' $true ([int]$qs.total -gt 0)
CheckBool 'pending 文件存在' $true (Test-Path (Get-AfsPendingPath))

$r1 = Invoke-AfsPendingApply
CheckBool '生效时段内 -> 不落地' $false $r1.applied
CheckBool '生效时段内 -> 原因 force-active' $true ($r1.reason -eq 'force-active')
CheckBool '生效时段内 -> 队列保留' $true (Test-Path (Get-AfsPendingPath))
CheckBool '生效时段内 -> config 未被改' $false (@(Get-AfsConfig).blockedSites -contains 'queued-demo.com')

# 把窗口挪到"已经过去的 1 分钟" -> 现在是非屏蔽时段
$c2 = Get-AfsConfig
$c2.schedule.windows = @(@{ start = '00:00'; end = '00:01' })
Set-AfsConfigSafe -InputConfig $c2 | Out-Null

$r2 = Invoke-AfsPendingApply
CheckBool '非屏蔽时段 -> 自动落地' $true $r2.applied
CheckBool '落地后 config 已有排队内容' $true (@(Get-AfsConfig).blockedSites -contains 'queued-demo.com')
CheckBool '落地后队列已清空' $false (Test-Path (Get-AfsPendingPath))
CheckBool '落地后 force.enabled 仍保持开启' $true ([bool](Get-AfsConfig).force.enabled)
# 补丁里没有 whitelist 时表示"白名单没动", 不能被当成清空
CheckBool '落地后白名单域名原样保留' $true (@(Get-AfsConfig).whitelist.sites -contains 'keep.example.com')
CheckBool '落地后白名单进程原样保留' $true (@(Get-AfsConfig).whitelist.processes -contains 'teams')
CheckBool '落地后原屏蔽项没丢' $true (@(Get-AfsConfig).blockedSites -contains 'douyin.com')

# 手工篡改队列文件: 塞进"删屏蔽项 / 关开关 / 加白名单 / 改屏蔽时段"
$tamper = @{
    version   = 1
    createdAt = (Get-Date).ToString('o')
    updatedAt = (Get-Date).ToString('o')
    reason    = 'tampered'
    total     = 4
    grouped   = @{ sites = @('- douyin.com'); switches = @(); browser = @(); processes = @(); whitelist = @('+ evil.com') }
    patch     = @{
        blockedSites  = @()                                   # 想清空屏蔽域名
        blockWebsites = $false                                # 想关掉总开关
        schedule      = @{ days = @(1); windows = @(@{ start = '00:00'; end = '00:05' }) }
        whitelist     = @{ sites = @('keep.example.com', 'evil.com') }
    }
}
Write-AfsJson -Path (Get-AfsPendingPath) -Object $tamper
$r3 = Invoke-AfsPendingApply
$after = Get-AfsConfig
CheckBool '被篡改的队列仍然落地' $true $r3.applied
CheckBool '篡改无效: 屏蔽域名没被清空' $true (@($after.blockedSites).Count -eq @(Get-AfsConfig).blockedSites.Count -and (@($after.blockedSites) -contains 'douyin.com'))
CheckBool '篡改无效: 总开关没被关掉' $true ([bool]$after.blockWebsites)
CheckBool '篡改无效: 屏蔽时段没被改' $true (("$($after.schedule.windows[0].start)-$($after.schedule.windows[0].end)") -eq '00:00-00:01')
CheckBool '篡改无效: 白名单没被塞进 evil.com' $false (@($after.whitelist.sites) -contains 'evil.com')
CheckBool '原白名单项仍保留' $true (@($after.whitelist.sites) -contains 'keep.example.com')

Remove-Item -LiteralPath $qdir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------
# F. 卸载守卫: 强制模式期间不允许卸载 (同样用临时目录, 不碰真实 config.json)
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- F. uninstall blocked while force mode is on ---'

$udir = Join-Path $env:TEMP ('afs-verify-uninst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $udir | Out-Null
Set-AfsConfigPath -Path (Join-Path $udir 'config.json')

# F1. 强制开启 + 当前正处于屏蔽时段 -> 拦, 原因 force-active
$uc = Get-AfsDefaultConfig
$uc.force.enabled    = $true
$uc.schedule.days    = @(1, 2, 3, 4, 5, 6, 7)
$uc.schedule.windows = @(@{ start = '00:00'; end = '23:59' })   # 全天窗口 -> 必然生效中
Set-AfsConfigSafe -InputConfig $uc | Out-Null
Save-AfsForceState -Until $null          # 与面板 /api/force 开启时一致: 写独立状态文件(双保险来源2)
$g1 = Get-AfsUninstallBlock
CheckBool '生效时段内 -> 禁止卸载' $true $g1.blocked
CheckBool '生效时段内 -> 原因 force-active' $true ($g1.reason -eq 'force-active')
CheckBool '生效时段内 -> 给出可操作文案' $true ($g1.msg -like '*关闭强制模式*')

# F2. 强制开着但当前不在生效时段(窗口外) -> 放行(只在"真正生效中"才拦)
$uc2 = Get-AfsConfig
$uc2.schedule.windows = @(@{ start = '00:00'; end = '00:01' })   # 已过去的 1 分钟 -> 非生效时段
Set-AfsConfigSafe -InputConfig $uc2 | Out-Null
$g2 = Get-AfsUninstallBlock
CheckBool '窗口外(强制未生效) -> 允许卸载' $false $g2.blocked
CheckBool '窗口外(强制未生效) -> 原因 off' $true ($g2.reason -eq 'off')

# F2b. 开关开着但"今天不在强制星期里"(周末场景) -> 放行
$uc2b = Get-AfsConfig
$uc2b.force.enabled    = $true
$uc2b.force.weekdays   = @(1, 2, 3, 4, 5)                        # 只强制周一到周五
$uc2b.schedule.days    = @(1, 2, 3, 4, 5, 6, 7)
$uc2b.schedule.windows = @(@{ start = '00:00'; end = '23:59' })
Set-AfsConfigSafe -InputConfig $uc2b | Out-Null
$satNow = [datetime]'2026-09-26 18:00'    # 周六 (非强制星期)
$monNow = [datetime]'2026-09-28 18:00'    # 周一 (强制星期 + 全天窗口)
$g2b = Get-AfsUninstallBlock -Now $satNow
CheckBool '非强制星期(周六) -> 允许卸载' $false $g2b.blocked
CheckBool '非强制星期(周六) -> 原因 off' $true ($g2b.reason -eq 'off')
$g2c = Get-AfsUninstallBlock -Now $monNow
CheckBool '强制星期(周一)且窗口内 -> 禁止卸载' $true $g2c.blocked
CheckBool '强制星期(周一) -> 原因 force-active' $true ($g2c.reason -eq 'force-active')

# F3. 手改 config.json 把 force.enabled 改成 false (模拟绕过) -> 状态文件仍在, 仍然拦
#     注: 这不是"窗口外正常情形", 而是配置被手改的痕迹, 属于防篡改, 依然拦。
$uc3 = Get-AfsConfig
$uc3.force.enabled = $false
Write-AfsJson -Path (Get-AfsConfigPath) -Object $uc3
CheckBool '前提: config 已被改成未开启' $false ([bool](Get-AfsConfig).force.enabled)
CheckBool '前提: force-state.json 仍在' $true (Test-Path (Get-AfsForceStatePath))
$g3 = Get-AfsUninstallBlock
CheckBool '手改 config 绕过 -> 仍禁止卸载' $true $g3.blocked
CheckBool '手改 config 绕过 -> 原因 force-residue' $true ($g3.reason -eq 'force-residue')

# F4. 状态文件也清掉 + config 关掉 -> 放行(不能把卸载永久卡死)
Remove-Item (Get-AfsForceStatePath) -Force -ErrorAction SilentlyContinue
$g4 = Get-AfsUninstallBlock
CheckBool '两来源都清掉 -> 允许卸载' $false $g4.blocked
CheckBool '两来源都清掉 -> 原因 off' $true ($g4.reason -eq 'off')

# F5. 从未开启强制模式的全新安装 -> 放行
$udir2 = Join-Path $env:TEMP ('afs-verify-uninst2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $udir2 | Out-Null
Set-AfsConfigPath -Path (Join-Path $udir2 'config.json')
Set-AfsConfigSafe -InputConfig (Get-AfsDefaultConfig) | Out-Null
$g5 = Get-AfsUninstallBlock
CheckBool '全新安装(强制未开) -> 允许卸载' $false $g5.blocked

# F6. 生效中删掉 force-state.json -> 引擎应把它补回来且不报错(长期模式 until 为 $null)
$uc6 = Get-AfsDefaultConfig
$uc6.force.enabled    = $true
$uc6.schedule.days    = @(1, 2, 3, 4, 5, 6, 7)
$uc6.schedule.windows = @(@{ start = '00:00'; end = '23:59' })
Set-AfsConfigSafe -InputConfig $uc6 | Out-Null
Remove-Item (Get-AfsForceStatePath) -Force -ErrorAction SilentlyContinue
$enforceErr = ''
try { $null = Invoke-AfsEnforce -Config (Get-AfsConfig) -HostsPath (Join-Path $udir2 'fake-hosts') -Simulate } catch { $enforceErr = $_.Exception.Message }
CheckBool '生效中删状态文件 -> 引擎不报错' $true ([string]::IsNullOrEmpty($enforceErr))
CheckBool '生效中删状态文件 -> 被自动补回' $true (Test-Path (Get-AfsForceStatePath))

# F7. 卸载脚本收口: 守卫必须存在于脚本里, 且位置早于任何删除动作
$unPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\uninstall.ps1'
$unText = [System.IO.File]::ReadAllText($unPath, [System.Text.Encoding]::UTF8)
$iGuard = $unText.IndexOf('Get-AfsUninstallBlock')
$iElev  = $unText.IndexOf('Get-AfsIsAdmin')
$iDelTask = $unText.IndexOf('schtasks /Delete')
$iDelDir  = $unText.IndexOf('rmdir /s /q')
CheckBool '卸载脚本: 含守卫调用' $true ($iGuard -ge 0)
CheckBool '卸载脚本: 守卫在提权之前' $true ($iGuard -ge 0 -and $iGuard -lt $iElev)
CheckBool '卸载脚本: 守卫在删除计划任务之前' $true ($iGuard -ge 0 -and $iGuard -lt $iDelTask)
CheckBool '卸载脚本: 守卫在删除程序目录之前' $true ($iGuard -ge 0 -and $iGuard -lt $iDelDir)
CheckBool '卸载脚本: 命中即 exit 1' $true ($unText -like "*exit 1*")

# G. 强制模式本体(开关 / 强制星期)不能通过"保存更改"改 —— 否则改完强制立刻"未生效",
#    既绕开强制, 也顺带绕开基于"此刻是否生效"判定的卸载守卫。只能走 /api/force。
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- G. force block locked against /api/config ---'

$gc = New-BaseCfg; $gc.force = @{ enabled = $true; until = $null; weekdays = @(1, 2, 3, 4, 5) }
$gn = New-BaseCfg; $gn.force = @{ enabled = $true; until = $null; weekdays = @(1, 2, 3, 4, 5) }
CheckDiff 'force block untouched'            @('none') $gc $gn

$gn2 = New-BaseCfg; $gn2.force = @{ enabled = $false; until = $null; weekdays = @(1, 2, 3, 4, 5) }
CheckDiff 'turn force off via config'        @('hard') $gc $gn2

$gn3 = New-BaseCfg; $gn3.force = @{ enabled = $true; until = $null; weekdays = @(1, 2, 3, 4) }   # 去掉周五
CheckDiff 'shrink force weekdays via config' @('hard') $gc $gn3

$gn4 = New-BaseCfg                                  # force 块整体消失 -> 会被合并回默认(enabled=false)
CheckDiff 'force block dropped'              @('hard') $gc $gn4

$gn5 = New-BaseCfg; $gn5.force = @{ enabled = $true; until = $null; weekdays = @(5, 4, 3, 2, 1) } # 仅顺序不同
CheckDiff 'force weekdays reordered only'    @('none') $gc $gn5

$gn6 = New-BaseCfg; $gn6.force = @{ enabled = $true; until = $null; weekdays = @(1, 2, 3, 4, 5, 5) } # 重复项
CheckDiff 'force weekdays duplicated only'   @('none') $gc $gn6

# 反向: 未开启时也不允许通过保存把强制打开(必须走卡片, 否则状态文件不会同步写)
$gc2 = New-BaseCfg; $gc2.force = @{ enabled = $false; until = $null; weekdays = @() }
$gn7 = New-BaseCfg; $gn7.force = @{ enabled = $true; until = $null; weekdays = @(1, 2, 3, 4, 5) }
CheckDiff 'turn force on via config'         @('hard') $gc2 $gn7

Remove-Item -LiteralPath $udir  -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $udir2 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:bad) {
    Write-Host ("RESULT: FAIL (" + $script:bad + " case(s))")
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
