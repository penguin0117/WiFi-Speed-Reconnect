@echo off
REM Worker script. Prefer USE\2_BEFORE_GAME.bat which wraps this with a UI.
REM Puts Band Guard into "observe only" mode: if the link drops to 2.4GHz
REM it just logs it, it will NOT disconnect you.
REM Pure ASCII on purpose.
setlocal EnableExtensions
cd /d "%~dp0"

for /f "tokens=2 delims=:" %%C in ('chcp') do set "OLD_CP=%%C"
set "OLD_CP=%OLD_CP: =%"
chcp 65001 >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Band_Guard.ps1" -Pause -NoPause

chcp %OLD_CP% >nul 2>&1
endlocal
exit /b 0
