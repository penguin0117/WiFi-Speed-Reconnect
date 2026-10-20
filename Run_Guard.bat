@echo off
REM ============================================================
REM  Band Guard v1 - launcher
REM
REM  Pure ASCII on purpose. The PS1 sets [Console]::OutputEncoding
REM  to UTF8, so the console is switched to 65001 for the run and
REM  restored afterwards. Do NOT remove the chcp calls.
REM
REM  Usage:
REM    Double-click          -> interactive menu
REM    Run_Guard.bat -Status
REM    Run_Guard.bat -Once -DryRun
REM    Run_Guard.bat -Pause
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"

set "PS_SCRIPT=%~dp0Band_Guard.ps1"

chcp 65001 >nul 2>&1

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Band_Guard.ps1 not found:
    echo         %PS_SCRIPT%
    chcp %OLD_CP% >nul 2>&1
    echo.
    pause
    exit /b 1
)

if not "%~1"=="" goto passthru

:menu
cls
echo ==================================================
echo    Band Guard
echo    keep the link on 5GHz / 6GHz
echo ==================================================
echo.
echo   1) Watch         - run in foreground, Ctrl+C to stop
echo   2) Check once    - single check, no loop
echo   3) Status        - summarize the log
echo   4) Pause fix     - while gaming: log only, never disconnect
echo   5) Resume fix
echo   6) Exit
echo.
set "CHOICE="
set /p "CHOICE=Select [1-6]: "

if "%CHOICE%"=="1" goto opt_watch
if "%CHOICE%"=="2" goto opt_once
if "%CHOICE%"=="3" goto opt_status
if "%CHOICE%"=="4" goto opt_pause
if "%CHOICE%"=="5" goto opt_resume
if "%CHOICE%"=="6" goto done0

echo.
echo Invalid choice.
chcp %OLD_CP% >nul 2>&1
pause
exit /b 1

:opt_watch
call :run
set "RC=%ERRORLEVEL%"
goto done

:opt_once
call :run -Once
set "RC=%ERRORLEVEL%"
goto done

:opt_status
call :run -Status
set "RC=%ERRORLEVEL%"
goto done

:opt_pause
call :run -Pause
set "RC=%ERRORLEVEL%"
goto done

:opt_resume
call :run -Resume
set "RC=%ERRORLEVEL%"
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %* -NoPause
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" echo [OK]
if "%RC%"=="1" echo [ABORT] No WiFi connection detected.
if "%RC%"=="3" echo [WARN] Still on 2.4GHz after retries.

set "HEADLESS="
for %%A in (%*) do (
    if /I "%%~A"=="-Once"   set "HEADLESS=1"
    if /I "%%~A"=="-Status" set "HEADLESS=1"
    if /I "%%~A"=="-Pause"  set "HEADLESS=1"
    if /I "%%~A"=="-Resume" set "HEADLESS=1"
    if /I "%%~A"=="-NoPause" set "HEADLESS=1"
)

if not defined HEADLESS (
    echo.
    pause
)
exit /b %RC%
