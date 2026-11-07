@echo off
REM Read-only migration audit launcher for the OLD laptop.
REM Double-click this file, or run it from a Command Prompt in this folder.
REM "-ExecutionPolicy Bypass" applies to this single PowerShell process only;
REM it does not change the computer's execution policy.
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Audit-OldLaptop.ps1" %*
echo.
echo Press any key to close this window.
pause >nul
