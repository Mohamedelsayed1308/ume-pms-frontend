@echo off
setlocal EnableExtensions
REM ======================================================================
REM  Read-only migration audit launcher for the OLD laptop.
REM  Keep this file in the same folder as Audit-OldLaptop.ps1.
REM  Usage:  Run-Audit.cmd                 full read-only audit
REM          Run-Audit.cmd -SelfTest       redaction self-test only (scans nothing)
REM          Run-Audit.cmd -ExtraRoots "D:\Work","E:\Archive"
REM  "-ExecutionPolicy Bypass" applies to this one PowerShell process only;
REM  the computer's execution policy is not changed.
REM ======================================================================

REM Always use the 64-bit Windows PowerShell 5.1 by full path (no PATH lookup).
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0Audit-OldLaptop.ps1"

if not exist "%PS_EXE%" goto :no_ps
if not exist "%SCRIPT%" goto :no_script

echo.
echo  Read-only migration audit
echo  - Reads project folders, Claude settings, scheduled tasks and software lists.
echo  - Changes nothing on this computer and uploads nothing.
echo  - Writes only into a NEW results folder in your user profile.
echo.
echo  Close this window now to cancel.
pause

"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" echo Result: OK - audit COMPLETE, or self-test passed
if "%RC%"=="2" echo Result: PARTIAL - read AUDIT_STATUS.txt in the results folder
if not "%RC%"=="0" if not "%RC%"=="2" echo Result: INCOMPLETE, REFUSED or FAILED - exit code %RC%. Read the messages above.
goto :finish

:no_ps
echo Windows PowerShell 5.1 was not found at "%PS_EXE%".
set "RC=1"
goto :finish

:no_script
echo Audit-OldLaptop.ps1 must be in the same folder as this file.
set "RC=1"
goto :finish

:finish
echo.
echo Press any key to close this window.
pause >nul
endlocal & exit /b %RC%
