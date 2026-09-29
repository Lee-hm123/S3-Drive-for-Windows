Option Explicit

Dim shell, command, fso, root, exitRequest
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
exitRequest = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\S3Drive\exit.request")
If fso.FileExists(exitRequest) Then fso.DeleteFile exitRequest, True
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\S3Drive管理器.ps1"" -Mode Tray"
shell.Run command, 0, False
