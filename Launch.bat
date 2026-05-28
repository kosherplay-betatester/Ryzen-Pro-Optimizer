@echo off
setlocal

REM Ryzen Pro Optimizer launcher
REM Self-elevates to admin and starts server.ps1

title Ryzen Pro Optimizer - Launcher

echo Starting Ryzen Pro Optimizer...

REM Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Admin rights required. Requesting elevation...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM Run installer if corecycler is missing OR if PawnIO service isn't registered
set RUN_INSTALLER=0
if not exist "%~dp0corecycler\script-corecycler.ps1" set RUN_INSTALLER=1
if not exist "%~dp0vendor\LibreHardwareMonitorLib.dll" set RUN_INSTALLER=1
sc.exe query PawnIO >nul 2>&1
if %errorlevel% neq 0 set RUN_INSTALLER=1

if "%RUN_INSTALLER%"=="1" (
    echo Required components missing or out of date. Running installer...
    powershell -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
    if %errorlevel% neq 0 (
        echo.
        echo Installer reported an error. Continuing anyway in case it was non-fatal.
        echo If the app fails to read sensors or CO values, run Install.bat manually.
        echo.
        timeout /t 5 >nul
    )
)

REM Start the server in a new window
start "Ryzen Pro Optimizer Server" cmd /k "cd /d %~dp0 && powershell -ExecutionPolicy Bypass -File server.ps1"

exit /b 0
