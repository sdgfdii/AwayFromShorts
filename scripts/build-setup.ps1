# ============================================================
#  build-setup.ps1 — 生成单文件 EXE 安装器(内嵌懒人包 zip)
#  产物: dist\AwayFromShorts-Setup-<version>.exe
#  用法: powershell -File scripts\build-setup.ps1 -Version 1.0.1
# ============================================================
param([string]$Version = '1.0.1')

$ErrorActionPreference = 'Stop'
$root   = Split-Path $PSScriptRoot
$zip    = Join-Path $root "dist\AwayFromShorts-v$Version-win64.zip"
$outDir = Join-Path $root 'dist'
if (-not (Test-Path $zip)) { throw "懒人包不存在: $zip (先运行 build-release.ps1)" }

# ---------- 1. 生成内嵌 base64 源码 ----------
$bytes = [System.IO.File]::ReadAllBytes($zip)
$b64   = [Convert]::ToBase64String($bytes)
# 按行分块(每行 100 字符)便于阅读和编译
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $b64.Length; $i += 100) {
    $len = [Math]::Min(100, $b64.Length - $i)
    $chunk = $b64.Substring($i, $len)
    $isLast = ($i + $len -ge $b64.Length)
    if ($isLast) { [void]$sb.Append('        "').Append($chunk).Append('"').AppendLine() }
    else         { [void]$sb.Append('        "').Append($chunk).Append('" +').AppendLine() }
}

# ---------- 2. 生成 C# 源码 ----------
$csTemplate = @'
// AwayFromShorts 单文件安装器 (自动生成, 勿手改)
// 双击运行 -> UAC 提权 -> 解压内嵌包 -> 复制文件 -> 注册计划任务 -> 启动面板
using System;
using System.IO;
using System.Diagnostics;
using System.Windows.Forms;

class AfsSetup {
    // 内嵌懒人包 zip (base64, 自动换行)
    static string ZipBase64 =
__B64__;

    [STAThread]
    static void Main() {
        try {
            string tmp = Path.Combine(Path.GetTempPath(), "AFS-Setup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmp);
            try {
                // 1. 解压内嵌包
                byte[] zipBytes = Convert.FromBase64String(ZipBase64);
                string zipPath = Path.Combine(tmp, "pkg.zip");
                File.WriteAllBytes(zipPath, zipBytes);
                System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, tmp);

                // 2. 递归复制整个包到安装目录(幂等)
                string app = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AwayFromShorts");
                Directory.CreateDirectory(app);
                CopyDir(tmp, app);

                // 3. 首次安装时用示例配置生成 config.json(已存在则保留用户配置)
                string cfg = Path.Combine(app, "src", "config.json");
                if (!File.Exists(cfg)) {
                    File.Copy(Path.Combine(app, "src", "config.example.json"), cfg);
                }

                // 4. 备份 hosts
                string hosts = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32\\drivers\\etc\\hosts");
                string bak = Path.Combine(app, "hosts.backup");
                if (!File.Exists(bak) && File.Exists(hosts)) { File.Copy(hosts, bak); }

                // 5. 注册计划任务 (HIGHEST, 每分钟, 隐藏窗口) — 失败则中止安装
                string taskFile = Path.Combine(app, "src", "awayfromshorts.ps1");
                string tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + taskFile + "\"";
                int rc = RunCmd("schtasks", "/Create /F /TN AwayFromShorts /TR \"" + tr.Replace("\"", "\\\"") + "\" /SC MINUTE /MO 1 /RL HIGHEST");
                if (rc != 0) { throw new Exception("计划任务注册失败 (schtasks exit " + rc + ")"); }

                // 6. 立即执行一次(隐藏窗口) + 启动面板
                RunCmd("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + taskFile + "\"");
                Process.Start(new ProcessStartInfo("powershell.exe") {
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(app, "src", "webui.ps1") + "\"",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    CreateNoWindow = true
                });
                System.Threading.Thread.Sleep(1500);
                Process.Start("http://127.0.0.1:8737");

                MessageBox.Show("AwayFromShorts 安装完成!\n\n" +
                    "配置面板已打开: http://127.0.0.1:8737\n" +
                    "屏蔽时段: 周一~周五 19:00-22:00 (可在面板修改)\n\n" +
                    "之后再次打开面板: " + Path.Combine(app, "start-web.bat") + "\n" +
                    "卸载: " + Path.Combine(app, "uninstall.bat"),
                    "AwayFromShorts", MessageBoxButtons.OK, MessageBoxIcon.Information);
            } finally {
                try { Directory.Delete(tmp, true); } catch { }
            }
        } catch (Exception ex) {
            MessageBox.Show("安装失败: " + ex.Message, "AwayFromShorts", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    static void CopyDir(string from, string to) {
        foreach (string dir in Directory.GetDirectories(from, "*", SearchOption.AllDirectories)) {
            Directory.CreateDirectory(Path.Combine(to, dir.Substring(from.Length + 1)));
        }
        foreach (string file in Directory.GetFiles(from, "*", SearchOption.AllDirectories)) {
            string rel = file.Substring(from.Length + 1);
            if (rel.Equals("pkg.zip", StringComparison.OrdinalIgnoreCase)) continue; // 跳过临时包
            File.Copy(file, Path.Combine(to, rel), true);
        }
    }

    static int RunCmd(string file, string args) {
        Process p = new Process();
        p.StartInfo.FileName = file;
        p.StartInfo.Arguments = args;
        p.StartInfo.UseShellExecute = false;
        p.StartInfo.CreateNoWindow = true;
        p.Start();
        if (!p.WaitForExit(30000)) { try { p.Kill(); } catch { } return -1; }
        return p.ExitCode;
    }
}
'@
$cs = $csTemplate.Replace('__B64__;', $sb.ToString().TrimEnd() + ';')
$csPath = Join-Path $env:TEMP 'afs-setup.cs'
[System.IO.File]::WriteAllText($csPath, $cs, [System.Text.UTF8Encoding]::new($false))

# ---------- 3. UAC manifest (requireAdministrator) ----------
$manifest = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{4f476546-9370-4f4f-9b3f-1f8a1f5a1f5a}"/>
    </application>
  </compatibility>
</assembly>
'@
$manifestPath = Join-Path $env:TEMP 'afs-setup.manifest'
[System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))

# ---------- 4. 编译 ----------
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$refs = @(
    'System.IO.Compression.FileSystem.dll',
    'System.Windows.Forms.dll',
    'System.Drawing.dll'
)
$refArgs = $refs | ForEach-Object { "/r:$_" }
$outExe = Join-Path $outDir "AwayFromShorts-Setup-$Version.exe"
$args = @(
    '/nologo',
    '/target:winexe',
    "/out:$outExe",
    "/win32manifest:$manifestPath"
) + $refArgs + @($csPath)
& $csc $args
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "安装器已生成: $outExe"
Write-Host "大小: $((Get-Item $outExe).Length) 字节"
Remove-Item $csPath, $manifestPath -Force -ErrorAction SilentlyContinue
