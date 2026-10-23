@echo off
rem Windows 11 setup. The script asks for administrator rights itself.
rem No if-blocks here: a path with brackets like "folder (1)" must not break cmd.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\win11-setup.ps1"
if errorlevel 1 pause
