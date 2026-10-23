@echo off
rem Data transfer tool: backup / restore personal files, Steam libraries, user folders to another drive.
rem The script asks for administrator rights itself.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\data-transfer.ps1"
if errorlevel 1 pause
