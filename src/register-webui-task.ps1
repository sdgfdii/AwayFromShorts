# ============================================================
#  register-webui-task.ps1 — 注册「开机自启面板」计划任务
#  AwayFromShorts-WebUI
#  LogonType=InteractiveToken + RunLevel=HighestAvailable:
#    用户登录时由 Task Scheduler 直接以"提升令牌"启动, 不弹 UAC。
#    (启动文件夹 VBS 是普通权限启动 -> webui 自我提权会弹 UAC,
#     这是"每次开机都要给管理员权限"的根因, 已废弃)
#  Trigger: AtLogOn(当前用户登录时)
#  用法: powershell -File register-webui-task.ps1
# ============================================================
param(
    [switch]$DryRun   # 只生成并打印 XML, 不实际注册
)

$ErrorActionPreference = 'Continue'
$TaskName = 'AwayFromShorts-WebUI'

$webui = Join-Path $PSScriptRoot 'webui.ps1'
if (-not (Test-Path $webui)) {
    Write-Host "错误: 面板脚本不存在: $webui"
    exit 1
}

# XML 转义(路径可能含 & < > 等)
$esc = { param($s) ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
$webuiEsc = & $esc $webui

# 当前用户 SID(AtLogOn 触发器: 仅该用户登录时启动)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$now = Get-Date
$dateStr   = $now.ToString('yyyy-MM-ddTHH:mm:ss')

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
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$webuiEsc"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP ("afs-webui-task-" + [guid]::NewGuid().ToString('N') + ".xml")
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
        Write-Host "计划任务 $TaskName 注册成功 (登录时自动以管理员启动面板, 不再弹 UAC)"
    } else {
        Write-Host "计划任务注册失败 (exit $code)"
    }
    exit $code
} finally {
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
}
