@echo off
REM Worker script. Prefer USE\3_AFTER_GAME.bat which wraps this with a UI.
REM Takes Band Guard out of "observe only" mode: it will pull you back to
REM 5GHz again when you drift to 2.4GHz.
REM Pure ASCII on purpose.
setlocal EnableExtensions
cd /d "%~dp0"

for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Band_Guard.ps1" -Resume -NoPause

chcp %OLD_CP% >nul 2>&1
endlocal
exit /b 0
