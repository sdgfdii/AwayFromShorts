# ============================================================
#  register-task.ps1 — 注册 AwayFromShorts 计划任务
#  LogonType=S4U: 不管用户是否登录都运行(无需存密码, 仅本机资源)
#  RunLevel=HighestAvailable: 写 hosts 必需
#  Trigger: 每分钟
#  用法: powershell -File register-task.ps1 -TaskFile <引擎脚本路径>
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$TaskFile,
    [switch]$DryRun   # 只生成并打印 XML, 不实际注册
)

$ErrorActionPreference = 'Continue'
$TaskName = 'AwayFromShorts'

if (-not (Test-Path $TaskFile)) {
    Write-Host "错误: 引擎脚本不存在: $TaskFile"
    exit 1
}

# XML 转义(路径可能含 & < > 等)
$esc = { param($s) ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
$taskFileEsc = & $esc $TaskFile

# 当前用户 SID(任务以该身份在后台运行)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$now = Get-Date
$dateStr   = $now.ToString('yyyy-MM-ddTHH:mm:ss')
$startStr  = $now.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss')

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$dateStr</Date>
    <Author>$(($env:USERDOMAIN) + '\' + $env:USERNAME)</Author>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$startStr</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$taskFileEsc"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP ("afs-task-" + [guid]::NewGuid().ToString('N') + ".xml")
try {
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
    if ($DryRun) {
        Write-Host "---- [DryRun] 待注册的任务 XML ----"
        Write-Host $xml
        Write-Host "-----------------------------------"
        exit 0
    }
    schtasks /Create /F /TN $TaskName /XML $xmlPath 2>&1 | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host "计划任务 $TaskName 注册成功 (S4U: 不登录也运行, 最高权限)"
    } else {
        Write-Host "计划任务注册失败 (exit $code)"
    }
    exit $code
} finally {
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
}
