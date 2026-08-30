' AwayFromShorts - hidden launcher for close-browser-windows.ps1 (no console window)
' Runs from the interactive task AwayFromShorts-BrowserClose via wscript (GUI subsystem)
Set ws = CreateObject("WScript.Shell")
app = ws.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\AwayFromShorts\src\close-browser-windows.ps1"
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & app & """", 0, True
