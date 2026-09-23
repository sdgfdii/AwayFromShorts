# ============================================================
#  AwayFromShorts - Force-mode lock guard offline regression test
#  Usage: powershell -ExecutionPolicy Bypass -File tools/verify-lock.ps1
#  Covers every branch of Test-AfsConfigLockViolation (core.ps1):
#    locked  = schedule(days/windows) / blockedSites / blockWebsites /
#              browser(windows/enabled/urlBlock) / blockedProcesses / whitelist
#    allowed = untouched config, case+order+duplicate-only edits, unrelated fields
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

Write-Host ''
if ($script:bad) {
    Write-Host ("RESULT: FAIL (" + $script:bad + " case(s))")
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
