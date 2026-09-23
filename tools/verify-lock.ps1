# ============================================================
#  AwayFromShorts - Force-mode lock guard offline regression test
#  Usage: powershell -ExecutionPolicy Bypass -File tools/verify-lock.ps1
#  Covers every branch of Get-AfsConfigLockDiff / Test-AfsConfigLockViolation (core.ps1):
#    hard (reject)   = schedule(days/windows)  -> 定义"何时算非屏蔽时段", 不能排队
#    queue (defer)   = blockedSites / blockWebsites / browser(windows/enabled/urlBlock)
#                      / blockedProcesses / whitelist  -> 生效时段内入队, 非屏蔽时段自动落地
#    allowed         = untouched config, case+order+duplicate-only edits, unrelated fields
#  Exit code: 0 = all pass, 1 = failures
# ============================================================
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\core.ps1')

$script:bad = 0
function Check {
    param([string]$Name, [bool]$ExpectBlocked, $Cur, $New)
    $v = Test-AfsConfigLockViolation -Current $Cur -Incoming $New
    $blocked = -not [string]::IsNullOrEmpty([string]$v)
    $ok = ($blocked -eq $ExpectBlocked)
    if (-not $ok) { $script:bad++ }
    $tag = if ($blocked) { 'blocked' } else { 'allowed' }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + $tag.PadRight(7) + ' ' + $Name)
}

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

Write-Host '--- should be ALLOWED ---'

Check 'identical config' $false (New-BaseCfg) (New-BaseCfg)

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites     = @('YouTube.com', 'DOUYIN.COM')          # case differs
$n.blockedProcesses = @('msedge', 'chrome', 'MSEDGE')         # order + duplicate
Check 'case / order / duplicate only' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.web      = @{ port = 9000 }                                # unrelated new field
$n.override = @{ mode = 'none'; until = $null }
$n.enabled  = $false
Check 'unrelated fields (web/override/enabled)' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.schedule.windows = @(@{ start = '07:15'; end = '09:15' })  # rebuild, same content
Check 'schedule.windows rebuilt identical' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites = @('douyin.com', 'youtube.com', '')          # blank entry ignored
Check 'blank entry ignored' $false $c $n

$c = New-BaseCfg
Check 'null incoming (defensive)' $false $c $null
Check 'null current (defensive)' $false $null $c

Write-Host '--- should be BLOCKED ---'

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites += 'tiktok.com'
Check 'blockedSites: add domain' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites = @('douyin.com')
Check 'blockedSites: remove domain' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = $false
Check 'blockWebsites: turn off' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.windows += 'Entertainment'
Check 'browser.windows: add workspace' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.urlBlock = $true
Check 'browser.urlBlock: toggle' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.enabled = $false
Check 'browser.enabled: turn off' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses += 'steam'
Check 'blockedProcesses: add process' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses = @('chrome')
Check 'blockedProcesses: remove process' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.sites += 'mail.example.com'
Check 'whitelist.sites: add domain' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.processes += 'teams'
Check 'whitelist.processes: add process' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2, 3, 4)
Check 'schedule.days: add day' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.windows = @(@{ start = '08:00'; end = '10:00' })
Check 'schedule.windows: change time' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.Remove('browser')
Check 'browser field dropped' $true $c $n

# whitelist: empty stays harmless, non-empty must be protected
$c = New-BaseCfg; $n = New-BaseCfg; $n.Remove('whitelist')
Check 'whitelist dropped while empty' $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$c.whitelist.sites = @('mail.example.com')
$n.Remove('whitelist')
Check 'whitelist dropped while non-empty' $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = 'true'   # string vs bool
Check 'blockWebsites: truthy string equals bool' $false $c $n

# ---------------------------------------------------------------
# 分类: 硬拒(屏蔽星期/时段) vs 可排队(屏蔽网页/进程/白名单)
# 强制模式生效时段内, 可排队项由 webui 存进 pending-config.json, 非屏蔽时段自动落地。
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- classification: hard (reject) vs queueable (defer) ---'

function CheckDiff {
    param([string]$Name, [bool]$ExpectHard, [bool]$ExpectQueue, $Cur, $New)
    $d = Get-AfsConfigLockDiff -Current $Cur -Incoming $New
    $hard  = (@($d.hardKeys).Count  -gt 0)
    $queue = (@($d.queueKeys).Count -gt 0)
    $ok = (($hard -eq $ExpectHard) -and ($queue -eq $ExpectQueue))
    if (-not $ok) { $script:bad++ }
    $tag = if ($hard -and $queue) { 'both' } elseif ($hard) { 'hard' } elseif ($queue) { 'queue' } else { 'none' }
    $note = if ($ok) { '' } else { "  (expect hard=$ExpectHard queue=$ExpectQueue, got hard=$hard queue=$queue)" }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + $tag.PadRight(7) + ' ' + $Name + $note)
}

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedSites += 'tiktok.com'
CheckDiff 'blockedSites -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockWebsites = $false
CheckDiff 'blockWebsites -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.windows += 'Fun'
CheckDiff 'browser.windows -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.browser.urlBlock = $true
CheckDiff 'browser.urlBlock -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.blockedProcesses += 'steam'
CheckDiff 'blockedProcesses -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.whitelist.sites += 'mail.example.com'
CheckDiff 'whitelist.sites -> queue' $false $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2, 3, 4)
CheckDiff 'schedule.days -> hard' $true $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.windows = @(@{ start = '08:00'; end = '10:00' })
CheckDiff 'schedule.windows -> hard' $true $false $c $n

$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites += 'tiktok.com'
$n.schedule.days = @(1, 2, 3, 4, 5)
CheckDiff 'sites + schedule -> both' $true $true $c $n

$c = New-BaseCfg; $n = New-BaseCfg
CheckDiff 'identical -> none' $false $false $c $n

# 排队补丁: 只装可排队字段, 且 total 反映变更条数
$c = New-BaseCfg; $n = New-BaseCfg
$n.blockedSites += 'tiktok.com'
$n.blockedProcesses += 'steam'
$n.browser.windows += 'Fun'
$np = New-AfsPendingPatch -Current $c -Incoming $n
$pk = (@($np.patch.Keys) | Sort-Object) -join ','
$okPatch = (($pk -eq 'blockedProcesses,blockedSites,browser') -and ($np.total -ge 3))
if (-not $okPatch) { $script:bad++ }
Write-Host (($(if ($okPatch) { 'OK  ' } else { 'FAIL' })) + ' patch   ' + "pending patch keys=[$pk] total=$($np.total)")

# 硬拒项绝不能混进补丁
$c = New-BaseCfg; $n = New-BaseCfg; $n.schedule.days = @(1, 2)
$np2 = New-AfsPendingPatch -Current $c -Incoming $n
$okHard = (@($np2.patch.Keys).Count -eq 0) -and ([int]$np2.total -eq 0)
if (-not $okHard) { $script:bad++ }
Write-Host (($(if ($okHard) { 'OK  ' } else { 'FAIL' })) + ' patch   ' + "schedule change never queued (total=$($np2.total))")

# ---------------------------------------------------------------
# 队列落地时机: 强制生效时段内不落地, 进入非屏蔽时段自动合并进 config
# (用临时目录做, 不碰真实 config.json)
# ---------------------------------------------------------------
Write-Host ''
Write-Host '--- pending queue: apply timing ---'

function CheckBool {
    param([string]$Name, [bool]$Expect, $Actual)
    $ok = ([bool]$Actual -eq $Expect)
    if (-not $ok) { $script:bad++ }
    $note = if ($ok) { '' } else { "  (expect $Expect, got $Actual)" }
    Write-Host (($(if ($ok) { 'OK  ' } else { 'FAIL' })) + ' ' + 'queue'.PadRight(7) + ' ' + $Name + $note)
}

$qdir = Join-Path $env:TEMP ('afs-verify-queue-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $qdir | Out-Null
Set-AfsConfigPath -Path (Join-Path $qdir 'config.json')

$bc = Get-AfsDefaultConfig
$bc.force.enabled = $true
$bc.schedule.days = @(1, 2, 3, 4, 5, 6, 7)
$bc.schedule.windows = @(@{ start = '00:00'; end = '23:59' })   # 全天窗口 -> 当前必然处于强制生效时段
Set-AfsConfigSafe -InputConfig $bc | Out-Null

$want = Get-AfsConfig
$want.blockedSites = @($want.blockedSites) + @('queued-demo.com')
$qs = Save-AfsPendingQueue -Current (Get-AfsConfig) -Incoming $want
CheckBool 'pending 写入成功(total>0)' $true ([int]$qs.total -gt 0)
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

Remove-Item -LiteralPath $qdir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:bad) {
    Write-Host ("RESULT: FAIL (" + $script:bad + " case(s))")
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
