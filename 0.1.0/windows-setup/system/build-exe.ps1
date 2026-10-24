#Requires -Version 5.1
<#
    Сборка .exe-лаунчеров с иконкой — запускать на Windows.

    Делает из тонких лаунчеров (launcher-setup.ps1 / launcher-transfer.ps1) два файла:
        windows-setup\Настройка Windows.exe
        windows-setup\Перенос данных.exe
    с иконкой system\icon.ico и запросом прав администратора.

    .bat-файлы остаются как запасной вариант — .exe их не трогает.

    Как запустить: ПКМ по этому файлу -> «Выполнить с помощью PowerShell».
    Нужен интернет (один раз), чтобы скачать модуль PS2EXE из PowerShell Gallery.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$here = Split-Path $MyInvocation.MyCommand.Path -Parent   # ...\windows-setup\system
$root = Split-Path $here -Parent                           # ...\windows-setup
$icon   = Join-Path $here 'icon.ico'       # основная иконка
$iconDb = Join-Path $here 'icon-db.ico'    # иконка переноса данных (база данных)

if (-not (Test-Path $icon)) { Write-Host "Нет иконки: $icon" -ForegroundColor Red; Read-Host 'Enter'; exit 1 }

Write-Host 'Проверяю модуль PS2EXE...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Устанавливаю PS2EXE из PowerShell Gallery (нужен интернет)...' -ForegroundColor Yellow
    try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null } catch {}
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted } catch {}
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$targets = @(
    @{ In = 'launcher-setup.ps1';    Out = 'Настройка Windows.exe'; Title = 'WinUP';     Icon = $icon }
    @{ In = 'launcher-transfer.ps1'; Out = 'Перенос данных.exe';    Title = 'Перенос данных'; Icon = $iconDb }
)

$ok = 0
foreach ($t in $targets) {
    $in  = Join-Path $here $t.In
    $out = Join-Path $root $t.Out
    $ico = if ((Test-Path $t.Icon)) { $t.Icon } else { $icon }
    Write-Host "Собираю: $($t.Out)" -ForegroundColor Cyan
    try {
        Invoke-ps2exe -inputFile $in -outputFile $out -iconFile $ico `
            -requireAdmin -noConsole -noOutput -noError `
            -title $t.Title -company 'DISOTERO' -product 'WinUP' -version '1.0.0'
        if (Test-Path $out) { Write-Host "  готово: $out" -ForegroundColor Green; $ok++ }
        else { Write-Host "  НЕ собралось: $($t.Out)" -ForegroundColor Red }
    } catch { Write-Host "  ошибка: $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host ''
Write-Host "Собрано: $ok из $($targets.Count). Файлы .exe лежат в папке windows-setup рядом с .bat." -ForegroundColor Green
Read-Host 'Нажмите Enter, чтобы закрыть'
