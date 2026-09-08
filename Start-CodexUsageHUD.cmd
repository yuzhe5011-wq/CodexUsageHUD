@echo off
start "Codex Usage HUD" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CodexUsageHUD.ps1"
