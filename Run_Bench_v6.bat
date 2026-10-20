@echo off
REM ============================================================
REM  WiFi Bench v6 - launcher
REM  Pure ASCII. The PS1 forces console output to UTF8 so netsh
REM  emits parseable English labels; a GBK console would render
REM  that as mojibake, so we switch to 65001 for the run and
REM  restore the original page on exit. Do NOT remove chcp.
REM
REM  Usage:
REM    Double-click                  -> interactive menu
REM    Run_Bench_v6.bat -List
REM    Run_Bench_v6.bat -Connect 9
REM    Run_Bench_v6.bat -Seconds 20
REM    Run_Bench_v6.bat -Auto
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"

set "PS_SCRIPT=%~dp0WiFi_Bench_v6.ps1"

chcp 65001 >nul 2>&1

if not exist "%PS_SCRIPT%" (
    echo [ERROR] WiFi_Bench_v6.ps1 not found:
    echo         %PS_SCRIPT%
    chcp %OLD_CP% >nul 2>&1
    echo.
    pause
    exit /b 1
)

if not "%~1"=="" goto passthru

:menu
echo ==================================================
echo    WiFi Bench v6
echo    steady-state speed / loaded latency / pick AP
echo ==================================================
echo.
echo   1) List APs        - full list, forced rescan
echo   2) Test current    - 15s test on current AP
echo   3) Test deep       - 25s test, more samples
echo   4) Connect to AP   - enter AP number from list
echo   5) Test every 5G AP - switch + test each 5G AP
echo   6) Exit
echo.
set "CHOICE="
set /p "CHOICE=Select [1-6]: "

if "%CHOICE%"=="1" goto opt_list
if "%CHOICE%"=="2" goto opt_cur
if "%CHOICE%"=="3" goto opt_deep
if "%CHOICE%"=="4" goto opt_conn
if "%CHOICE%"=="5" goto opt_auto
if "%CHOICE%"=="6" goto done0

echo.
echo Invalid choice.
chcp %OLD_CP% >nul 2>&1
pause
exit /b 1

:opt_list
call :run -List
goto done
:opt_cur
call :run -Seconds 15
goto done
:opt_deep
call :run -Seconds 25
goto done
:opt_auto
call :run -Auto
goto done

:opt_conn
echo.
echo Enter AP number, or a BSSID like a2:82:3d:91:39:9b
echo (BSSID is more reliable - numbers shift when signal changes)
echo.
set "APNO="
set /p "APNO=AP: "
if not defined APNO goto menu
echo %APNO% | find ":" >nul
if %ERRORLEVEL%==0 (
    call :run -ConnectBssid %APNO%
) else (
    call :run -Connect %APNO%
)
goto done

:passthru
call :run %*
set "RC=%ERRORLEVEL%"
chcp %OLD_CP% >nul 2>&1
exit /b %RC%

:done0
chcp %OLD_CP% >nul 2>&1
exit /b 0

:done
chcp %OLD_CP% >nul 2>&1
exit /b %RC%

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="1" echo [ABORT] No WiFi connection detected.

set "HEADLESS="
for %%A in (%*) do (
    if /I "%%~A"=="-Quiet"  set "HEADLESS=1"
    if /I "%%~A"=="-NoPause" set "HEADLESS=1"
    if /I "%%~A"=="-Auto"   set "HEADLESS=1"
)

if not defined HEADLESS (
    echo.
    pause
)
exit /b %RC%
