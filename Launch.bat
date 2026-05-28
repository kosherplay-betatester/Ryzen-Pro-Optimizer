@echo off
setlocal

REM ============================================================================
REM   Launch.bat - Ryzen Pro Optimizer entry point
REM ============================================================================
REM   What it does (in order):
REM     1. Self-elevates to administrator (CO writes hit SMU registers,
REM        which need admin).
REM     2. Runs the installer if anything required is missing:
REM        - corecycler/script-corecycler.ps1 (the stress engine)
REM        - vendor/LibreHardwareMonitorLib.dll (the sensor library)
REM        - PawnIO Windows service (the kernel driver)
REM     3. Detects a stale, incompatible LHM DLL (.NET Core/10 build that
REM        PowerShell 5.1 can't load) and re-triggers the installer to
REM        replace it with the net472 build from NuGet.
REM     4. Starts server.ps1 in its own console window so you can see
REM        logs and Ctrl+C cleanly when done.
REM
REM   Open in a new window (instead of waiting): we want the launcher
REM   process to exit immediately so users can close the launcher cmd
REM   without killing the server.
REM ============================================================================

title Ryzen Pro Optimizer - Launcher

echo Starting Ryzen Pro Optimizer...

REM Check for admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Admin rights required. Requesting elevation...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM Run installer if corecycler is missing OR vendor DLL is missing/incompatible OR PawnIO not registered
set RUN_INSTALLER=0
if not exist "%~dp0corecycler\script-corecycler.ps1" set RUN_INSTALLER=1
if not exist "%~dp0vendor\LibreHardwareMonitorLib.dll" set RUN_INSTALLER=1
sc.exe query PawnIO >nul 2>&1
if %errorlevel% neq 0 set RUN_INSTALLER=1
REM Detect incompatible (.NET Core/10) DLL build - PowerShell 5.1 can't load it
if exist "%~dp0vendor\LibreHardwareMonitorLib.dll" (
    powershell -NoProfile -Command "$t=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes('%~dp0vendor\LibreHardwareMonitorLib.dll')); if ($t -match '\.NETCoreApp,Version=v\d') { exit 1 } else { exit 0 }"
    if errorlevel 1 (
        echo Detected incompatible LibreHardwareMonitor build [.NET Core/10]. Reinstalling...
        set RUN_INSTALLER=1
    )
)

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
