@echo off
REM ============================================================
REM  WiFi Channel Benchmark v5 - launcher
REM
REM  This file is deliberately pure ASCII so it never depends on
REM  the system ANSI code page.
REM
REM  Encoding: the PS1 sets [Console]::OutputEncoding to UTF8 so
REM  that netsh emits parseable English. A GB2312 console then
REM  renders that UTF8 text as mojibake, so we switch the console
REM  to 65001 for the run and restore the original page on exit.
REM  Do NOT remove the chcp calls.
REM
REM  Usage:
REM    Double-click              -> interactive menu
REM    Run_Benchmark.bat -ScanOnly
REM    Run_Benchmark.bat -DryRun
REM    Run_Benchmark.bat -MaxTries 20 -NoPause
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

REM remember the original code page so we can put it back
for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"

set "PS_SCRIPT=%~dp0WiFi_Speed_Reconnect.ps1"

REM match the console to the UTF8 output of the PS1 script
chcp 65001 >nul 2>&1

if not exist "%PS_SCRIPT%" (
    echo [ERROR] WiFi_Speed_Reconnect.ps1 not found:
    echo         %PS_SCRIPT%
    chcp %OLD_CP% >nul 2>&1
    echo.
    pause
    exit /b 1
)

REM ---------- no arguments: show menu ----------
if "%~1"=="" goto menu

REM ---------- arguments given: pass through ----------
call :run %*
set "RC=%ERRORLEVEL%"
chcp %OLD_CP% >nul 2>&1
exit /b %RC%

:menu
echo ==================================================
echo    WiFi Channel Benchmark v5
echo    Enumerate APs - sample - pick best channel
echo ==================================================
echo.
echo   1) Quick scan  - list all APs, no speed test
echo   2) Safe test   - measure only, never disconnect
echo   3) Full run    - 12 rounds, then switch to best
echo   4) Deep test   - 24 rounds, more samples
echo   5) Custom      - enter your own arguments
echo   6) Exit
echo.
set "CHOICE="
set /p "CHOICE=Select [1-6]: "

if "%CHOICE%"=="1" goto opt_scan
if "%CHOICE%"=="2" goto opt_dry
if "%CHOICE%"=="3" goto opt_full
if "%CHOICE%"=="4" goto opt_deep
if "%CHOICE%"=="5" goto custom
if "%CHOICE%"=="6" goto done0

echo.
echo Invalid choice.
chcp %OLD_CP% >nul 2>&1
pause
exit /b 1

:opt_scan
call :run -ScanOnly
set "RC=%ERRORLEVEL%"
goto done

:opt_dry
call :run -DryRun
set "RC=%ERRORLEVEL%"
goto done

:opt_full
call :run
set "RC=%ERRORLEVEL%"
goto done

:opt_deep
call :run -MaxTries 24
set "RC=%ERRORLEVEL%"
goto done

:custom
echo.
echo Examples:
echo   -ScanOnly
echo   -DryRun -MaxTries 8
echo   -MaxTries 20 -SpeedSeconds 8 -NoPause
echo   -MinSpeedMbps 300 -LinkRatio 0.5
echo.
set "ARGS="
set /p "ARGS=Arguments (blank to go back): "
if not defined ARGS goto menu
call :run %ARGS%
set "RC=%ERRORLEVEL%"
goto done

:done0
chcp %OLD_CP% >nul 2>&1
exit /b 0

:done
chcp %OLD_CP% >nul 2>&1
exit /b %RC%

REM ---------- core runner ----------
:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" echo [OK] Finished.
if "%RC%"=="1" echo [ABORT] No WiFi connection detected.
if "%RC%"=="2" echo [ABORT] All speed-test sources unavailable.

REM Only pause when interactive and not explicitly headless.
set "HEADLESS="
for %%A in (%*) do (
    if /I "%%~A"=="-NoPause" set "HEADLESS=1"
    if /I "%%~A"=="-ScanOnly" set "HEADLESS=1"
)

if not defined HEADLESS (
    echo.
    pause
)
exit /b %RC%