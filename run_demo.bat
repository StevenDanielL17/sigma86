@echo off
color 0F
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0run_fork_demo.ps1"
echo.
pause
