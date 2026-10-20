@echo off
REM ============================================================
REM  3) AFTER GAME  -  double-click this when you stop playing.
REM
REM  Puts the band guard back into normal mode:
REM  from now on, if you drift to 2.4GHz it will pull you back
REM  to 5GHz again (at the cost of a 2-second reconnect).
REM
REM  Pure ASCII on purpose.
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0.."

cls
echo ==================================================
echo    3) AFTER GAME  -  resuming auto-fix
echo ==================================================
echo.

call "%~dp0..\GUARD_RESUME.bat"

echo.
echo   Back to normal: drifting to 2.4GHz will be auto-corrected again.
echo.
echo   (Press any key to close.)
pause >nul
endlocal
exit /b 0
