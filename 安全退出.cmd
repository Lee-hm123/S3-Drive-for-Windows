@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0S3Drive管理器.ps1" -Mode Stop
if errorlevel 1 pause
exit /b %ERRORLEVEL%
