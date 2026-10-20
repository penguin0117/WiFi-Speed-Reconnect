@echo off
REM ============================================================
REM  2) BEFORE GAME  -  double-click this right before you play.
REM
REM  Puts the band guard into "observe only" mode:
REM  if the link drops to 2.4GHz it just logs it and does NOT
REM  disconnect you. Slower, but no 2-second drop mid-match.
REM
REM  Remember to run 3_AFTER_GAME.bat when you are done.
REM  Pure ASCII on purpose.
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0.."

cls
echo ==================================================
echo    2) BEFORE GAME  -  pausing auto-fix
echo ==================================================
echo.

call "%~dp0..\GUARD_PAUSE.bat"

echo.
echo   From now on: if you drift to 2.4GHz it will NOT disconnect you.
echo   Remember to run 3_AFTER_GAME.bat when you stop playing.
echo.
echo   (Press any key to close.)
pause >nul
endlocal
exit /b 0
