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

REM Run installer if corecycler/ is missing
if not exist "%~dp0corecycler\script-corecycler.ps1" (
    echo CoreCycler not found. Running installer...
    powershell -ExecutionPolicy Bypass -File "%~dp0installer.ps1"
    if %errorlevel% neq 0 (
        echo.
        echo Installer failed. Press any key to exit.
        pause >nul
        exit /b 1
    )
)

REM Start the server in a new window
start "Ryzen Pro Optimizer Server" cmd /k "cd /d %~dp0 && powershell -ExecutionPolicy Bypass -File server.ps1"

exit /b 0
