@echo off
REM ============================================================
REM  4) SPEED TEST  -  only when you want numbers.
REM
REM  Opens the menu. Useful picks:
REM    2) Test current  - 15s test on the AP you are on
REM    5) Test every 5G AP - switch + test each 5G AP, then
REM       prints a comparison table sorted by real throughput
REM
REM  Nothing here changes your settings. It only measures.
REM  Pure ASCII on purpose.
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0.."

call "%~dp0..\Run_Bench_v6.bat"

exit /b 0
