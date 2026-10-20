@echo off
REM ============================================================
REM  Tune WiFi - launcher with self-elevation
REM
REM  A .ps1 has no "Run as administrator" context menu entry on
REM  Windows, so this wraps it: double-click -> UAC -> Yes -> menu.
REM
REM  Elevation uses the --admin marker instead of probing rights
REM  repeatedly, so saying "No" to UAC cannot cause a loop.
REM
REM  Keep this file pure ASCII. cmd.exe reads it byte-wise in the
REM  OEM code page; UTF-8 Chinese would print as mojibake before
REM  the chcp call.
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "SELF=%~f0"
set "PS1=%~dp0Tune_WiFi.ps1"

if not exist "%PS1%" (
    echo [ERROR] Tune_WiFi.ps1 not found:
    echo         %PS1%
    echo.
    pause
    exit /b 1
)

REM ---------- first launch: no marker, so elevate ----------
if /I not "%~1"=="--admin" (
    echo.
    echo Administrator rights are required to change adapter settings.
    echo A UAC prompt will appear - click Yes.
    echo If you click No, this window closes. Alternative:
    echo   right-click Start - Terminal ^(Admin^) - run the command manually
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%SELF%' -ArgumentList '--admin' -Verb RunAs"
    exit /b
)

REM ---------- elevated: show menu ----------
for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul 2>&1

:menu
cls
echo ==================================================
echo    Tune WiFi  (administrator)
echo    knobs available on the adapter side
echo ==================================================
echo.
echo   1) Show current values
echo   2) Apply tuning   (power save Low / roaming Lowest)
echo   3) Revert to default
echo   4) Exit
echo.
set "CHOICE="
set /p "CHOICE=Select [1-4]: "

if "%CHOICE%"=="1" goto do_show
if "%CHOICE%"=="2" goto do_apply
if "%CHOICE%"=="3" goto do_revert
if "%CHOICE%"=="4" goto done
goto menu

:do_show
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Show -NoPause
echo.
pause
goto menu

:do_apply
echo.
echo The adapter will restart once. Network drops for 3-5 seconds.
echo On a campus network you may need to re-login the portal page.
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Apply -NoPause
echo.
pause
goto menu

:do_revert
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Revert -NoPause
echo.
pause
goto menu

:done
chcp %OLD_CP% >nul 2>&1
endlocal
exit /b 0
