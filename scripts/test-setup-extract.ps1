# test-setup-extract.ps1 - 验证内嵌 zip 完整性的测试构建(无副作用, 不带 UAC manifest)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$zip = Join-Path $root 'dist\AwayFromShorts-v1.0.1-win64.zip'
if (-not (Test-Path $zip)) { throw "缺少 $zip" }

$bytes = [System.IO.File]::ReadAllBytes($zip)
$b64   = [Convert]::ToBase64String($bytes)
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $b64.Length; $i += 100) {
    $len = [Math]::Min(100, $b64.Length - $i)
    $chunk = $b64.Substring($i, $len)
    $isLast = ($i + $len -ge $b64.Length)
    if ($isLast) { [void]$sb.Append('        "').Append($chunk).Append('"').AppendLine() }
    else         { [void]$sb.Append('        "').Append($chunk).Append('" +').AppendLine() }
}

$csTemplate = @'
using System;
using System.IO;

class AfsTest {
    static string ZipBase64 =
__B64__;

    [STAThread]
    static int Main() {
        try {
            string tmp = Path.Combine(Path.GetTempPath(), "AFS-Setup-Test");
            Directory.CreateDirectory(tmp);
            byte[] zipBytes = Convert.FromBase64String(ZipBase64);
            string zipPath = Path.Combine(tmp, "pkg.zip");
            File.WriteAllBytes(zipPath, zipBytes);
            System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, tmp);
            string[] files = Directory.GetFiles(tmp, "*", SearchOption.AllDirectories);
            File.WriteAllText(Path.Combine(tmp, "EXTRACT-OK.txt"), files.Length + " files extracted");
            Console.WriteLine("EXTRACT-OK " + files.Length + " files");
            return 0;
        } catch (Exception ex) {
            try {
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "AFS-Setup-Test", "ERROR.txt"), ex.ToString());
            } catch { }
            Console.WriteLine("EXTRACT-FAILED " + ex.Message);
            return 1;
        }
    }
}
'@
$cs = $csTemplate.Replace('__B64__;', $sb.ToString().TrimEnd() + ';')
$csPath = Join-Path $env:TEMP 'afs-setup-test.cs'
[System.IO.File]::WriteAllText($csPath, $cs, [System.Text.UTF8Encoding]::new($false))

Remove-Item (Join-Path $env:TEMP 'AFS-Setup-Test') -Recurse -Force -ErrorAction SilentlyContinue
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$testExe = Join-Path $root 'dist\test-extract.exe'
$refArgs = @('System.IO.Compression.FileSystem.dll','System.Windows.Forms.dll','System.Drawing.dll') | ForEach-Object { "/r:$_" }
& $csc /nologo /target:winexe "/out:$testExe" $refArgs $csPath
if ($LASTEXITCODE -ne 0) { throw "csc failed: $LASTEXITCODE" }
Write-Host "test-extract.exe OK: $((Get-Item $testExe).Length) bytes"
