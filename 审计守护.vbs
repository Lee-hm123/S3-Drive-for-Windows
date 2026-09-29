Option Explicit

Dim shell, command, fso, root, exitRequest
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
exitRequest = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%\S3Drive\exit.request")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & root & "\S3Drive审计.ps1"""

' Keep audit running across accidental or forced PowerShell termination.
Do
  If fso.FileExists(exitRequest) Then Exit Do
  shell.Run command, 0, True
  If fso.FileExists(exitRequest) Then Exit Do
  WScript.Sleep 5000
Loop
