#Requires -Version 5.1
<#
    Тонкий лаунчер для «Перенос данных.exe».
    Его собирает system\build-exe.ps1 через PS2EXE (с иконкой и правами администратора).
    Находит свою папку и запускает system\data-transfer.ps1.
#>
$ErrorActionPreference = 'SilentlyContinue'

$exe = try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null }
if (-not $exe) { $exe = [Environment]::GetCommandLineArgs()[0] }
$dir = Split-Path $exe -Parent
$ps1 = Join-Path $dir 'system\data-transfer.ps1'

if (-not (Test-Path $ps1)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Не найден файл:`n$ps1`n`nДержите «Перенос данных.exe» в папке windows-setup (рядом с папкой system).",
        'Перенос данных', 'OK', 'Error') | Out-Null
    exit 1
}

Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ps1`""
