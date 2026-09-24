@echo off
setlocal
title Wooltari Daily Check-In Runner

echo ========================================================
echo           Wooltari Daily Check-In (Manual Run)
echo ========================================================
echo Starting check-in process...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Invoke-WooltariDailyCheckIn.ps1"
set CHECKIN_EXIT=%ERRORLEVEL%

echo.
echo ========================================================
if %CHECKIN_EXIT% EQU 0 (
    echo [SUCCESS] Daily check-in completed or already verified for today!
) else if %CHECKIN_EXIT% EQU 2 (
    echo [ACTION REQUIRED] Could not confirm login.
    echo Please open Chrome, log in to https://wooltariusa.com once,
    echo and make sure your credentials are saved.
) else if %CHECKIN_EXIT% EQU 4 (
    echo [NOTICE] Check-in text was found, but button was not clickable.
) else if %CHECKIN_EXIT% EQU 5 (
    echo [NOTICE] Clicked check-in, but final confirmation timed out.
) else if %CHECKIN_EXIT% EQU 6 (
    echo [NOTICE] Check-in button or completed state was not detected.
) else (
    echo [ERROR] Script exited with code %CHECKIN_EXIT%.
)
echo ========================================================
echo.
echo Log files are saved in:
echo   %~dp0wooltari-checkin-logs\
echo.
echo Press any key to close this window...
pause >nul
