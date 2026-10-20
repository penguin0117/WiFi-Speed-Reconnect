@echo off
REM ============================================================
REM  1) BOOT / FIX  -  run this after boot, or whenever the link
REM                   feels slow and you suspect it fell to 2.4GHz.
REM
REM  What it does: checks the band. If you are on 2.4GHz it
REM  disconnects and reconnects until it lands on 5GHz (up to 3
REM  tries, then gives up and waits 5 minutes).
REM
REM  Exit codes: 0 = on 5GHz ok, 3 = still 2.4GHz, 1 = no wifi
REM  Pure ASCII on purpose - cmd reads .bat byte-wise in the OEM
REM  code page, so UTF-8 Chinese here would print as mojibake.
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0.."

for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul 2>&1

cls
echo ==================================================
echo    1) BOOT / FIX  -  checking band
echo ==================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Band_Guard.ps1" -Once -NoPause
set "RC=%ERRORLEVEL%"

chcp %OLD_CP% >nul 2>&1

echo.
echo ==================================================
if "%RC%"=="0" echo    RESULT: OK - you are on 5GHz. Nothing to do.
if "%RC%"=="3" echo    RESULT: WARN - still on 2.4GHz after 3 tries.
if "%RC%"=="1" echo    RESULT: WARN - WiFi is not connected.
if "%RC%"=="0" echo    Peak speed may still be limited by the AP or the campus uplink.
if "%RC%"=="0" echo    Run 4_SPEED_TEST if you want numbers.
if "%RC%"=="3" echo    The 5GHz signal may really be gone. Try moving closer
if "%RC%"=="3" echo    to the door / away from the metal bed frame, then retry.
if "%RC%"=="1" echo    Click the WiFi icon on the taskbar and connect to SVIST.
echo ==================================================
echo.
echo   (This window stays open now. Press any key to close.)
pause >nul
endlocal
exit /b %RC%
