@echo off
REM ============================================================================
REM  Update.bat - Manual update check (bypasses the 6h rate-limit)
REM ============================================================================
REM  Run this any time to force an update probe + prompt. Useful after you
REM  bumped past a "skipped" version and want to re-check.
REM ============================================================================

title Ryzen Pro Optimizer - Update Check

REM Self-elevate (writes to install dir + may bypass file locks)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Admin rights required. Requesting elevation...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Force

echo.
pause
