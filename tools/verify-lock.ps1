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

Write-Host ''
if ($script:bad) {
    Write-Host ("RESULT: FAIL (" + $script:bad + " case(s))")
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
