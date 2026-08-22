' AwayFromShorts - auto-start the config panel on login (hidden, no flash)
' Skips if port 8737 is already listening (idempotent)
Set ws = CreateObject("WScript.Shell")
app = ws.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\AwayFromShorts\src\webui.ps1"
chk = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""if (Get-NetTCPConnection -LocalPort 8737 -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"""
rc = ws.Run(chk, 0, True)
If rc <> 0 Then
    ws.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & app & """", 0, False
End If
