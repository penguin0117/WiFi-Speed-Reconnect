@echo off
chcp 65001 >nul
title WiFi Speed Test ^& Auto Reconnect
echo ============================================
echo   WiFi Speed Test + Smart Reconnect (SVIST)
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WiFi_Speed_Reconnect.ps1" %*
echo.
pause
