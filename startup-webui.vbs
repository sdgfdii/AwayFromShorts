' AwayFromShorts - auto-start the config panel on login (hidden, no flash)
' Idempotent: webui.ps1 exits silently if port 8737 is already in use.
' (Old version ran a slow synchronous PowerShell port check first, which
'  delayed panel startup by several seconds after login - removed.)
Set ws = CreateObject("WScript.Shell")
app = ws.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\AwayFromShorts\src\webui.ps1"
ws.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & app & """", 0, False