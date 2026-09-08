@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install-CodexUsageHUD.ps1"
if errorlevel 1 pause
