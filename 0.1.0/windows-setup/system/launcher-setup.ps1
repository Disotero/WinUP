#Requires -Version 5.1
<#
    Тонкий лаунчер для «Настройка Windows.exe».
    Его собирает system\build-exe.ps1 через PS2EXE (с иконкой и правами администратора).
    Задача простая: найти свою папку и запустить system\win11-setup.ps1.
    Сам win11-setup.ps1 тоже умеет повышать права, так что всё работает и без манифеста.
#>
$ErrorActionPreference = 'SilentlyContinue'

# Путь к самому .exe (в скомпилированном виде $PSScriptRoot пустой)
$exe = try { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $null }
if (-not $exe) { $exe = [Environment]::GetCommandLineArgs()[0] }
$dir = Split-Path $exe -Parent
$ps1 = Join-Path $dir 'system\win11-setup.ps1'

if (-not (Test-Path $ps1)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Не найден файл:`n$ps1`n`nДержите «Настройка Windows.exe» в папке windows-setup (рядом с папкой system).",
        'Настройка ПК', 'OK', 'Error') | Out-Null
    exit 1
}

# Запускаем настройку. .exe уже с админ-правами (манифест), powershell их наследует.
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ps1`""
