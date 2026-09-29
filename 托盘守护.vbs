Option Explicit

Dim shell, command, fso, root, exitRequest
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
exitRequest = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\S3Drive\exit.request")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\S3Drive管理器.ps1"" -Mode Tray"

' Keep the scheduled task alive. If the tray PowerShell process is force-ended,
' restart it silently after a short delay.
Do
  If fso.FileExists(exitRequest) Then Exit Do
  shell.Run command, 0, True
  If fso.FileExists(exitRequest) Then Exit Do
  WScript.Sleep 5000
Loop
