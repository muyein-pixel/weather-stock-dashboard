@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ========================================
echo  대한민국 날씨 대시보드 시작
echo ========================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
pause
