#Requires -Version 5.1
<#
    Настройка чистой Windows 11 одной командой.

    Что делает (по порядку; в режимах «Только ...» часть шагов пропускается):
       - Подготовка: точка восстановления; в фоне начинают скачиваться
         драйвер видеокарты и ставиться Microsoft Office
       - Проверка системы: память (XMP/EXPO), диски, активация, UEFI / Secure Boot / TPM
       - Отключает ненужные службы, телеметрию и рекламу
       - Удаляет предустановленный мусор (Clipchamp, Новости, Solitaire и т.п.)
       - Устанавливает программы из списка (через winget), дожидается Office
       - Обновляет драйверы через Центр обновления Windows
       - Ставит драйвер видеокарты с сайта NVIDIA / AMD / Intel
       - Ставит максимальное разрешение и частоту экрана
       - Игровые настройки и удобство, электропитание
       - Отключает автоматические обновления Windows
       - Оптимизация и очистка: удаляет временный и системный мусор (temp, кэш обновлений,
         логи, дампы, остатки обновлений ОС, Windows.old, корзина), сжимает хранилище
         компонентов; безопасные сетевые настройки (сброс кэша DNS, без троттлинга, сетевая
         карта не спит); ускорение (фоновые приложения off, Storage Sense); доп. опции по выбору
       - (по желанию) Стресс-тест: процессор и память (7-Zip), видеокарта (FurMark),
         температуры и троттлинг, оценка WinSAT; итог в отдельном окне
       - Паспорт ПК (HTML) на рабочем столе

    Без интернета: кнопка «Собрать офлайн-папку» в стартовом окне собирает папку system\offline,
    после этого «Настройка Windows.bat»    ставит всё из неё.

    При запуске открывается окно с режимами: «Только стресс-тесты», «Только установка программ»,
    «Всё», «Только оптимизация и очистка», галочками «Со стресс-тестом» / «Оптимизация и очистка»
    и кнопкой «Старт».
    После «Старт» показывается список того, что будет сделано: «ОК» — начать, «Отмена» — выйти.

    Каждый шаг пишется строкой: [ OK ] / [ -- ] / [FAIL].
    Пока идёт долгая операция, внизу крутится индикатор с таймером.
    В конце — итог и путь к подробному логу.

    Структура:  Настройка Windows.bat   — этот скрипт
                Перенос данных.bat      — программа переноса данных (system\data-transfer.ps1)
                system\                 — скрипты, README, версия, офлайн-папка, логи и отчёты

    Запуск: двойной клик по «Настройка Windows.bat» (сам попросит права администратора).
#>
param(
    # Собрать офлайн-папку (так запускает кнопка «Собрать офлайн-папку» в стартовом окне)
    [switch]$PrepareOffline
)

# Любая непредвиденная ошибка: показать её и не закрывать окно, чтобы было видно, что случилось
trap {
    $msg = "ОШИБКА: $($_.Exception.Message)"
    if ($_.InvocationInfo.ScriptLineNumber) { $msg += "`nСтрока $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" }
    Write-Host ''; Write-Host $msg -ForegroundColor Red
    try { Write-Log "ОШИБКА: $($_ | Out-String)" } catch {}
    # Прибраться перед выходом: выгрузить профиль по умолчанию (если был загружен для «режима передачи»)
    # и вернуть разрешение сна. Всё в try/catch: на раннем этапе функций и типов может ещё не быть.
    try { if (Get-Command Dismount-DefaultUserHive -ErrorAction SilentlyContinue) { Dismount-DefaultUserHive } } catch {}
    try { if ('SleepBlock' -as [type]) { [void][SleepBlock]::SetThreadExecutionState([uint32]2147483648) } } catch {}
    # Если GUI уже загружен (консоль может быть скрыта) — показываем ошибку окном, иначе ждём Enter в консоли
    if ('System.Windows.Forms.MessageBox' -as [type]) {
        try { [System.Windows.Forms.MessageBox]::Show("$msg`n`nСфотографируйте это окно и пришлите.", 'WinUP — ошибка', 'OK', 'Error') | Out-Null } catch {}
    } else {
        Read-Host 'Скрипт остановлен. Сфотографируйте ошибку и нажмите Enter' | Out-Null
    }
    exit 1
}

# ============================================================================
#  НАСТРОЙКИ — меняйте здесь
# ============================================================================

# Какие шаги выполнять ($true = да, $false = пропустить)
$DoRestorePoint   = $true
$DoInstallApps    = $true
$DoInstallOffice  = $true
$DoUpdateDrivers  = $true
$DoGpuDriver      = $true
$DoMaxDisplay     = $true   # макс. разрешение и частота экрана
$DoSystemCheck    = $true   # проверка: память (XMP), диски, активация, UEFI/TPM (ничего не меняет)
$DoGameTweaks     = $true   # игровой режим, планирование GPU, без Game DVR и ускорения мыши
$DoComfortTweaks  = $true   # меню как в Win10, расширения файлов, без рекламы в «Пуск», тёмная тема
$DoPowerPlan      = $true   # «Высокая производительность» и без гибернации (на ноутбуке — «Сбалансированная»)
$DoPassport       = $true   # паспорт ПК (HTML) на рабочем столе в конце
$DoRegion         = $true   # часовой пояс, синхронизация времени, раскладки клавиатуры
$DoDefaultApps    = $true   # программы по умолчанию: Chrome, ImageGlass, VLC, WinRAR
$DoOneDriveEdge   = $true   # без автозапуска и навязчивых окон OneDrive и Edge
$DoDisableAI      = $true   # без Recall, Click to Do, ИИ в Paint и Блокноте
$DoStartupCleanup = $true   # убрать из автозагрузки Steam, Discord, OneDrive, Edge и т.п.
$DoCleanup        = $true   # в конце: очистка временных файлов, кэша обновлений, корзины
$DoMemTest        = $true   # со стресс-тестом: проверка памяти Windows при следующей перезагрузке
$DoDisableUpdates = $true
$DoDisableDefender = $false
$DoDisableServices = $true
$DoRemoveBloat    = $true
$DoOptimize       = $true   # оптимизация и очистка: мусор, временные/системные ненужные файлы, сеть, ускорение

# --- Оптимизация и очистка: дополнительные опции ---
# Безопасные действия (очистка temp/кэша/логов, сеть, фоновые приложения, Storage Sense и т.п.)
# выполняются всегда, когда включён $DoOptimize. Ниже — опции по выбору; меняются галочками
# в окне (вкладка «Оптимизация»). ВЫКЛючены по умолчанию, т.к. подходят не всем.
$OptDefaults = [ordered]@{
    BrowserCache    = $false   # очистить кэши браузеров (пароли и закладки не трогаются)
    OldDrivers      = $false   # удалить старые версии драйверов в DriverStore (активные оставить)
    Hibernate       = $false   # отключить гибернацию и удалить hiberfil.sys (ТОЛЬКО на десктопе)
    ReservedStorage = $false   # отключить «Зарезервированное хранилище» (освобождает ~7 ГБ)
    OneDriveRemove  = $false   # удалить OneDrive полностью (а не только из автозагрузки)
    ExtraServices   = $false   # отключить дополнительные службы (SysMain, кошелёк и т.п.)
    VisualEffects   = $false   # визуальные эффекты «на производительность» (шрифты сглажены)
    SfcDism         = $false   # проверка и починка системных файлов (DISM /RestoreHealth + sfc)
    PrivacyHandover = $false   # очистить историю (недавние, «Выполнить», буфер) — для передачи ПК
    ResetBase       = $false   # 🔴 предельное сжатие WinSxS: НЕОБРАТИМО, нельзя удалять обновления
}
# Показывать ли окно консоли (подробный лог) во время работы. $true = видно, $false = скрыть.
$ShowConsole = $false
# Тема окна: 'light' (светлая) или 'dark' (тёмная)
$UiTheme = 'dark'

# Галочка «Со стресс-тестом» в стартовом окне по умолчанию ($true = стоит)
$StressTestDefault = $false
# Галочка «Удалить программы для тестов после стресс-теста» по умолчанию
$RemoveTestToolsDefault = $true
# Галочка «Переустановить программы, которые уже установлены» по умолчанию
$ReinstallDefault = $false
# Сколько проходов стресс-теста процессора (7-Zip). 20 проходов ≈ 3–8 минут.
$StressPasses = 20
# Сколько секунд длится стресс-тест видеокарты (FurMark)
$GpuStressSeconds = 180

# Отключать брандмауэр Windows. По умолчанию НЕТ: без него ПК открыт всем в сети.
$DisableFirewall  = $false

# Программы для установки. ID ищется командой:  winget search <название>
# или на сайте https://winstall.app
# Галочка «Подготовить для передачи другому человеку» по умолчанию
$ClientModeDefault = $false
# В режиме передачи удалить вашу (техническую) учётную запись после первого входа нового владельца
$ClientRemoveTechUser = $true

# --- Регион и время ---
# Часовой пояс. Москва — 'Russian Standard Time'. Полный список: команда  tzutil /l
$TimeZone     = 'Russian Standard Time'
# Раскладки клавиатуры (первая — основная) и сочетание для переключения: 'Alt+Shift' или 'Ctrl+Shift'
$Languages    = @('ru-RU', 'en-US')
$LayoutHotkey = 'Alt+Shift'
# Через сколько минут гасить экран на ПК (сон на ПК отключается; ноутбук не трогаем)
$MonitorOffMinutes = 20

# --- Автозагрузка: что отключить (можно со звёздочкой) ---
$StartupBlock = @('Steam', 'Discord', 'OneDrive', 'MicrosoftEdgeAutoLaunch*', 'EpicGamesLauncher',
                  'Spotify', 'Teams', 'com.squirrel.Teams.Teams', 'Skype*', 'CCleaner*')

# --- Программы по умолчанию: какая программа открывает какие файлы ---
# Match — как программа называется в реестре (регулярное выражение)
$DefaultApps = @(
    @{ Name = 'Google Chrome'; Match = 'Chrome';     Types = @('http', 'https', '.htm', '.html', '.pdf') }
    @{ Name = 'ImageGlass';    Match = 'ImageGlass'; Types = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tif', '.tiff', '.heic', '.ico') }
    @{ Name = 'VLC';           Match = 'VLC';        Types = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.flv', '.mp3', '.flac', '.wav', '.m4a', '.ogg') }
    @{ Name = 'WinRAR';        Match = 'WinRAR';     Types = @('.zip', '.rar', '.7z', '.tar', '.gz') }
)

# Порядок важен: сначала библиотеки, от которых зависят другие программы, потом архиваторы
# (7-Zip нужен для распаковки драйвера NVIDIA), потом всё остальное.
$Apps = @(
    # Системные библиотеки (нужны играм и многим программам)
    @{ Id = 'Microsoft.VCRedist.2015+.x64'; Name = 'Visual C++ 2015-2022 x64' }
    @{ Id = 'Microsoft.VCRedist.2015+.x86'; Name = 'Visual C++ 2015-2022 x86' }
    # Архиваторы
    @{ Id = '7zip.7zip';                    Name = '7-Zip' }
    @{ Id = 'RARLab.WinRAR';                Name = 'WinRAR' }
    # Браузер и общение
    @{ Id = 'Google.Chrome';                Name = 'Google Chrome' }
    @{ Id = 'Telegram.TelegramDesktop';     Name = 'Telegram' }
    @{ Id = 'Discord.Discord';              Name = 'Discord' }
    # Игры и загрузки
    @{ Id = 'Valve.Steam';                  Name = 'Steam' }
    @{ Id = 'qBittorrent.qBittorrent';      Name = 'qBittorrent (торрент, без рекламы)' }
    # Медиа
    @{ Id = 'VideoLAN.VLC';                 Name = 'VLC' }
    @{ Id = 'DuongDieuPhap.ImageGlass';     Name = 'ImageGlass (просмотр фото)' }
    # Инструменты
    @{ Id = 'Notepad++.Notepad++';          Name = 'Notepad++' }
)

# Microsoft Office. Нужна лицензия: подписка Microsoft 365 или купленный Office.
#   Подписка Microsoft 365 (Personal / Family) -> 'O365HomePremRetail'
#   Office 2024 для дома                       -> 'Home2024Retail'
#   Office 2021 для дома и учёбы               -> 'HomeStudent2021Retail'
$OfficeProduct = 'O365HomePremRetail'
# Какие приложения ставить. Возможные: Word, Excel, PowerPoint, Outlook, OneNote, Access, Publisher, Teams
$OfficeApps = @('Word', 'Excel', 'PowerPoint')
# Язык Office. В офлайн-папку скачивается именно он; при установке через интернет — язык системы.
$OfficeLanguage = 'ru-ru'

# Для сравнения в итоге стресс-теста: примерный результат 7-Zip (MIPS) у известных процессоров
$CpuReference = @(
    @{ Name = 'Intel Core i5-4460';   Score = 15000 }
    @{ Name = 'Intel Core i3-10100';  Score = 30000 }
    @{ Name = 'Intel Core i5-10400';  Score = 45000 }
    @{ Name = 'AMD Ryzen 5 3600';     Score = 50000 }
    @{ Name = 'Intel Core i5-12400';  Score = 60000 }
    @{ Name = 'AMD Ryzen 5 5600X';    Score = 65000 }
    @{ Name = 'AMD Ryzen 7 5800X';    Score = 85000 }
    @{ Name = 'Intel Core i5-13600K'; Score = 105000 }
    @{ Name = 'AMD Ryzen 9 7950X';    Score = 190000 }
)

# Для оценки «пойдут ли игры»: минимум по процессору (MIPS 7-Zip) и видеопамяти (ГБ) — ориентировочно
$GameTiers = @(
    @{ Games = 'CS2, Dota 2, Valorant, Minecraft';         Cpu = 20000; Vram = 2 }
    @{ Games = 'GTA V, Fortnite, Apex Legends, PUBG';      Cpu = 35000; Vram = 4 }
    @{ Games = 'Cyberpunk 2077, новые AAA-игры';            Cpu = 55000; Vram = 8 }
)

# Службы, которые будут отключены
$Services = @(
    @{ Name = 'DiagTrack';        Desc = 'Телеметрия Microsoft' }
    @{ Name = 'dmwappushservice'; Desc = 'Передача данных телеметрии (WAP Push)' }
    @{ Name = 'WerSvc';           Desc = 'Отчёты об ошибках Windows' }
    @{ Name = 'MapsBroker';       Desc = 'Скачивание офлайн-карт' }
    @{ Name = 'lfsvc';            Desc = 'Геолокация' }
    @{ Name = 'RetailDemo';       Desc = 'Демо-режим для магазинов' }
    @{ Name = 'Fax';              Desc = 'Факс' }
    @{ Name = 'RemoteRegistry';   Desc = 'Удалённый реестр' }
    @{ Name = 'WMPNetworkSvc';    Desc = 'Сетевой доступ Windows Media Player' }
    @{ Name = 'wisvc';            Desc = 'Программа предварительной оценки (Insider)' }
    @{ Name = 'WpcMonSvc';        Desc = 'Родительский контроль' }
    @{ Name = 'PhoneSvc';         Desc = 'Телефонная связь' }
    # Службы Xbox. Если играете через Xbox/Game Pass — удалите эти 4 строки.
    @{ Name = 'XblAuthManager';   Desc = 'Xbox Live: вход' }
    @{ Name = 'XblGameSave';      Desc = 'Xbox Live: сохранения' }
    @{ Name = 'XboxNetApiSvc';    Desc = 'Xbox Live: сеть' }
    @{ Name = 'XboxGipSvc';       Desc = 'Xbox: аксессуары' }
)

# Предустановленные приложения, которые будут удалены
$Bloatware = @(
    @{ Name = 'Clipchamp.Clipchamp';                    Desc = 'Clipchamp' }
    @{ Name = 'Microsoft.BingNews';                     Desc = 'Новости' }
    @{ Name = 'Microsoft.BingWeather';                  Desc = 'Погода' }
    @{ Name = 'Microsoft.BingSearch';                   Desc = 'Поиск Bing' }
    @{ Name = 'Microsoft.GetHelp';                      Desc = 'Техподдержка' }
    @{ Name = 'Microsoft.Getstarted';                   Desc = 'Советы' }
    @{ Name = 'Microsoft.MicrosoftSolitaireCollection'; Desc = 'Solitaire' }
    @{ Name = 'Microsoft.MicrosoftOfficeHub';           Desc = 'Microsoft 365 (Office Hub)' }
    @{ Name = 'Microsoft.People';                       Desc = 'Люди' }
    @{ Name = 'Microsoft.PowerAutomateDesktop';         Desc = 'Power Automate' }
    @{ Name = 'Microsoft.Todos';                        Desc = 'To Do' }
    @{ Name = 'Microsoft.WindowsFeedbackHub';           Desc = 'Центр отзывов' }
    @{ Name = 'Microsoft.WindowsMaps';                  Desc = 'Карты' }
    @{ Name = 'Microsoft.ZuneMusic';                    Desc = 'Медиаплеер' }
    @{ Name = 'Microsoft.ZuneVideo';                    Desc = 'Кино и ТВ' }
    @{ Name = 'MicrosoftCorporationII.QuickAssist';     Desc = 'Быстрая помощь' }
    @{ Name = 'MSTeams';                                Desc = 'Teams (личный)' }
    @{ Name = 'MicrosoftTeams';                         Desc = 'Teams (старый)' }
    @{ Name = 'Microsoft.OutlookForWindows';            Desc = 'Новый Outlook' }
)

# Дополнительные службы (отключаются только при галочке «доп. службы» в оптимизации).
# Спорные: кому-то нужны, поэтому не в основном списке $Services.
$ExtraServices = @(
    @{ Name = 'SysMain';            Desc = 'SysMain (Superfetch) — предзагрузка приложений' }
    @{ Name = 'WalletService';      Desc = 'Кошелёк' }
    @{ Name = 'WbioSrvc';           Desc = 'Биометрия (если нет сканера отпечатков/лица)' }
    @{ Name = 'SCardSvr';           Desc = 'Смарт-карты' }
)

# Папки, которые безопасно чистить при оптимизации (только мусор: temp, кэш, логи, дампы).
# Пути с системными переменными раскрываются во время выполнения. Документы не трогаются.
$CleanTargets = @(
    @{ Path = "$env:SystemRoot\Temp";                                         Desc = 'Временные файлы Windows' }
    @{ Path = "$env:SystemRoot\SoftwareDistribution\Download";                Desc = 'Кэш загрузок Центра обновления' }
    @{ Path = "$env:SystemRoot\Logs\CBS";                                     Desc = 'Логи обслуживания (CBS)' }
    @{ Path = "$env:SystemRoot\Logs\DISM";                                    Desc = 'Логи DISM' }
    @{ Path = "$env:SystemRoot\Panther";                                      Desc = 'Логи установки Windows' }
    @{ Path = "$env:SystemRoot\Minidump";                                     Desc = 'Малые дампы при синих экранах' }
    @{ Path = "$env:SystemRoot\LiveKernelReports";                            Desc = 'Отчёты ядра' }
    @{ Path = "$env:ProgramData\Microsoft\Windows\WER";                       Desc = 'Отчёты об ошибках Windows' }
    @{ Path = "$env:SystemDrive\`$WINDOWS.~BT";                               Desc = 'Остатки обновления ОС (~BT)' }
    @{ Path = "$env:SystemDrive\`$WINDOWS.~WS";                               Desc = 'Остатки обновления ОС (~WS)' }
    @{ Path = "$env:SystemDrive\`$GetCurrent";                                Desc = 'Остатки помощника обновления' }
)

# ============================================================================
#  ДАЛЬШЕ МЕНЯТЬ НЕ НУЖНО
# ============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Временные файлы — в папку без кириллицы и пробелов (C:\Windows\Temp\win11-setup).
# Установщики Office, NVIDIA и 7-Zip иногда ломаются, если путь вида C:\Users\Иван\...
# Меняем TEMP для самого скрипта и всех программ, которые он запускает.
try {
    $WorkDir = Join-Path $env:SystemRoot 'Temp\win11-setup'
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $env:TEMP = $WorkDir
    $env:TMP  = $WorkDir
} catch {}

$TotalSteps = 8
# Папка программы (там лежат два .bat) и папка для логов и отчётов
$AppRoot = Split-Path $PSScriptRoot -Parent
$LogDir  = Join-Path $PSScriptRoot 'logs'
try { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } catch {}
$LogFile = Join-Path $LogDir ("setup-log_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))
$script:Results      = New-Object System.Collections.Generic.List[object]
$script:BgTasks      = New-Object System.Collections.Generic.List[object]   # то, что идёт в фоне
$script:RebootNeeded = $false
$script:Reinstall    = $false
$script:TestInstalled = New-Object System.Collections.Generic.List[object]   # что поставили только ради тестов
$script:SpinnerShown = $false
$script:StartTime    = Get-Date
$script:ManualActions = New-Object System.Collections.Generic.List[object]   # «сделать руками» — печатается в конце и в паспорте
$script:FailedInstalls = New-Object System.Collections.Generic.List[object]  # что не установилось — для «повторить только неудачное»

# Действие, которое пользователю нужно сделать самому (видеокарта без драйвера, XMP в BIOS и т.п.)
function Add-Manual([string]$Text) {
    if ($Text -and ($script:ManualActions -notcontains $Text)) { $script:ManualActions.Add($Text) }
}

function Write-Log([string]$Text) {
    try { Add-Content -Path $LogFile -Value ("{0:HH:mm:ss}  {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch {}
}

# Пишет в лог содержимое файла вывода установщика, выбрасывая мусор: полоски прогресса winget
# (в консоли это ▒▒▒██, в перекодированном логе — «в–€в–’») и строки «12.3 MB / 45.6 MB».
function Write-Log-Clean([string]$File) {
    Get-Content $File -ErrorAction SilentlyContinue | Where-Object {
        $_ -match '\w' -and
        $_ -notmatch '[▀-▟░-▓]' -and   # ▀▄█░▒▓ и др. псевдографика
        $_ -notmatch 'в[–—]' -and                          # та же псевдографика, испорченная кодировкой
        $_ -notmatch '\d[\d.,]*\s*(MB|KB|GB|МБ|КБ|ГБ)\s*/\s*\d'   # «2.00 MB / 17.8 MB»
    } | ForEach-Object { Write-Log ("    " + ($_.Trim())) }
}

function Get-ConsoleWidth {
    try { [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch { 79 }
}

function Clear-Spinner {
    if ($script:SpinnerShown) {
        Write-Host -NoNewline ("`r" + (' ' * (Get-ConsoleWidth)) + "`r")
        $script:SpinnerShown = $false
    }
}

# Номер шага считается сам: «шаг N из M» (M — сколько шагов включено в выбранном режиме)
$script:StepNo = 0
function Write-Step([string]$Title) {
    Clear-Spinner
    $n = ''
    if ($Title -ne 'ИТОГ') { $script:StepNo++; $n = $script:StepNo; $Title = "$n. $Title" }
    Write-Host ''
    Write-Host "===== $Title =====" -ForegroundColor Cyan -NoNewline
    Write-Host '   не выключайте компьютер' -ForegroundColor DarkYellow
    Write-Log ''
    Write-Log "===== $Title ====="
    # Процент — по «весу» уже пройденных шагов, а не по их числу (длинные шаги весят больше).
    # На шаге «ИТОГ» показываем 100%: раньше полоса прогресса в конце сбрасывалась в ноль.
    $pct = 100
    if ($n -and $script:TotalWeight) {
        $pct = [int](100 * $script:DoneWeight / $script:TotalWeight)
        $w = if ($script:StepWeights -and $n -le $script:StepWeights.Count) { $script:StepWeights[$n - 1] } else { 1 }
        $script:DoneWeight += $w
    }
    $stepText = if ($n) { "шаг $n из $TotalSteps ($pct%)" } else { $Title }
    try { $Host.UI.RawUI.WindowTitle = "Настройка ПК — $stepText — НЕ ВЫКЛЮЧАЙТЕ КОМПЬЮТЕР" } catch {}
    if ($script:ProgForm) {
        try {
            $script:ProgStep.Text = $Title
            $script:ProgBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$pct))
            [Windows.Forms.Application]::DoEvents()
        } catch {}
    }
}

# Status: OK (получилось), SKIP (не нужно / уже сделано), WARN (частично), FAIL (не получилось)
function Report([string]$Status, [string]$Text, [string]$Details = '') {
    Clear-Spinner
    $tag, $color = switch ($Status) {
        'OK'   { '[ OK ]', 'Green' }
        'SKIP' { '[ -- ]', 'DarkGray' }
        'WARN' { '[ !! ]', 'Yellow' }
        'FAIL' { '[FAIL]', 'Red' }
    }
    $line = "$tag $Text"
    if ($Details) { $line += "  ($Details)" }
    Write-Host $line -ForegroundColor $color
    Write-Log $line
    $script:Results.Add([pscustomobject]@{ Status = $Status; Text = $Text; Details = $Details })
    if ($script:ProgForm) {
        try { $script:ProgLog.AppendText($line + "`r`n"); [Windows.Forms.Application]::DoEvents() } catch {}
    }
}

# ---------------------------------------------------------------------------
#  Задачи с индикатором «не завис»
#
#  Долгие операции запускаются как задачи. Пока задача идёт, внизу крутится
#  строка вида:   / 02:14  Steam — устанавливается   | в фоне: Office
#  Задачи из $script:BgTasks работают параллельно с остальными шагами.
# ---------------------------------------------------------------------------
function New-TaskStatus([string]$Text) {
    [hashtable]::Synchronized(@{
        Text  = $Text
        Lines = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })
}

# Задача-скрипт: выполняется в отдельном потоке PowerShell.
# Внутри доступна $Status: $Status.Text меняет подпись индикатора,
# $Status.Lines.Add(@{ Status='OK'; Text='...'; Details='...'; Reboot=$false }) — строка в отчёт.
function Start-ScriptTask([string]$Name, [string]$Text, [scriptblock]$Script, [object[]]$ArgumentList = @(), [string]$WatchFile) {
    $status = New-TaskStatus $Text
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Status', $status)
    $rs.SessionStateProxy.SetVariable('ErrorActionPreference', 'Stop')
    $rs.SessionStateProxy.SetVariable('ProgressPreference', 'SilentlyContinue')
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
    [pscustomobject]@{
        Kind = 'script'; Name = $Name; Status = $status; WatchFile = $WatchFile
        PS = $ps; Handle = $ps.BeginInvoke(); Timer = [Diagnostics.Stopwatch]::StartNew()
    }
}

# Задача-программа: запускает внешний .exe
function Start-ProcessTask([string]$Name, [string]$Text, [string]$File, [string[]]$Arguments = @(), [string]$OutFile, [switch]$Visible) {
    $params = @{ FilePath = $File; PassThru = $true }
    if ($Arguments) { $params.ArgumentList = $Arguments }
    if ($OutFile) {
        $params.NoNewWindow = $true
        $params.RedirectStandardOutput = $OutFile
        $params.RedirectStandardError  = "$OutFile.err"
    } elseif (-not $Visible) {
        $params.WindowStyle = 'Hidden'
    }
    $p = Start-Process @params
    $null = $p.Handle   # без этого PowerShell 5.1 иногда теряет код возврата
    [pscustomobject]@{
        Kind = 'process'; Name = $Name; Status = (New-TaskStatus $Text); WatchFile = $null
        Proc = $p; Timer = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Test-TaskDone($Task) {
    if ($Task.Kind -eq 'script') { $Task.Handle.IsCompleted } else { $Task.Proc.HasExited }
}

function Show-Spinner($Task, [int]$Frame) {
    $text = $Task.Status.Text
    if ($Task.WatchFile -and (Test-Path $Task.WatchFile)) {
        $bytes = if (Test-Path $Task.WatchFile -PathType Container) {
            if ($Frame % 8 -eq 0 -or -not $Task.Status.Bytes) {
                $Task.Status.Bytes = (Get-ChildItem $Task.WatchFile -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            }
            $Task.Status.Bytes
        } else { (Get-Item $Task.WatchFile).Length }
        $text += ' — скачано {0:N0} МБ' -f ($bytes / 1MB)
    }
    $bg = @($script:BgTasks | Where-Object { $_ -ne $Task -and -not (Test-TaskDone $_) } | ForEach-Object { $_.Name })
    if ($bg) { $text += '   | в фоне: ' + ($bg -join ', ') }
    if ($script:TempStatus -and $Task.Status -ne $script:TempStatus -and "$($script:TempStatus.Text)" -match '°C') {
        $text += '   | ' + $script:TempStatus.Text
    }

    $line = '       {0} {1:mm\:ss}  {2}' -f '|/-\'[$Frame % 4], $Task.Timer.Elapsed, $text
    $w = Get-ConsoleWidth
    if ($line.Length -gt $w) { $line = $line.Substring(0, $w - 3) + '...' }
    Write-Host -NoNewline ("`r" + $line.PadRight($w)) -ForegroundColor DarkGray
    $script:SpinnerShown = $true
    if ($script:ProgForm) { try { [Windows.Forms.Application]::DoEvents() } catch {} }
}

function Receive-TaskLines($Task) {
    while ($Task.Status.Lines.Count -gt 0) {
        $l = $Task.Status.Lines[0]
        $Task.Status.Lines.RemoveAt(0)
        if ($l.Reboot) { $script:RebootNeeded = $true }
        Report $l.Status $l.Text $l.Details
    }
}

# Ждёт задачу, показывая индикатор. Возвращает результат скрипта или код выхода программы.
# -TimeoutSec: через сколько секунд принудительно закрыть программу (вместе со всеми её окнами)
# -KillNames:  имена процессов, которые нужно закрыть после задачи (окна, оставшиеся после программы)
function Wait-Task($Task, [int]$TimeoutSec = 0, [string[]]$KillNames = @()) {
    $frame = 0
    $Task | Add-Member -NotePropertyName TimedOut -NotePropertyValue $false -Force
    while (-not (Test-TaskDone $Task)) {
        if ($TimeoutSec -and $Task.Kind -eq 'process' -and $Task.Timer.Elapsed.TotalSeconds -gt $TimeoutSec) {
            if (-not $Task.TimedOut) {
                $Task.TimedOut = $true
                Write-Log "  «$($Task.Name)»: время вышло, закрываю принудительно"
                # Закрываем всё дерево процессов: у некоторых программ окно — это дочерний процесс
                try { Start-Process taskkill.exe -ArgumentList "/PID $($Task.Proc.Id) /T /F" -WindowStyle Hidden -Wait } catch {}
                try { $Task.Proc.Kill() } catch {}
                if ($KillNames) { Get-Process -Name $KillNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
            }
            # Если программа игнорирует принудительное закрытие ещё 30 секунд — не зависаем:
            # выходим ошибкой, вызывающий код пометит шаг как FAIL
            if ($Task.Timer.Elapsed.TotalSeconds -gt ($TimeoutSec + 30)) {
                Write-Log "  «$($Task.Name)»: не закрывается, перестаю ждать"
                Clear-Spinner
                [void]$script:BgTasks.Remove($Task)
                throw "программа «$($Task.Name)» не закрылась после таймаута"
            }
            Show-Spinner $Task $frame
            $frame++
            Start-Sleep -Milliseconds 250
            continue
        }
        Receive-TaskLines $Task
        Show-Spinner $Task $frame
        $frame++
        Start-Sleep -Milliseconds 250
    }
    Receive-TaskLines $Task
    if ($KillNames) { Get-Process -Name $KillNames -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Clear-Spinner
    [void]$script:BgTasks.Remove($Task)
    Write-Log ("  «{0}» заняло {1:mm\:ss}" -f $Task.Name, $Task.Timer.Elapsed)

    if ($Task.Kind -eq 'process') {
        $Task.Proc.WaitForExit()
        return $Task.Proc.ExitCode
    }
    try {
        $out = $Task.PS.EndInvoke($Task.Handle)
        if ($Task.PS.Streams.Error.Count -gt 0) { throw $Task.PS.Streams.Error[0].Exception }
        return $out
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        throw $e.Message
    } finally {
        $Task.PS.Runspace.Dispose()
        $Task.PS.Dispose()
    }
}

# ---------------------------------------------------------------------------
#  Повторы при сбоях сети
#  Скачивания и установки иногда обрываются по таймауту или сбросу соединения.
#  Две-три попытки с паузой почти всегда доводят дело до конца.
# ---------------------------------------------------------------------------
# Коды winget/установщиков, означающие проблему сети (а не «пакет плохой»):
#   0x80072EE2 таймаут, 0x80072EE7 нет имени (DNS), 0x80072EFD/EFE обрыв соединения
#   winget: 0x8A150008 не удалось скачать, 0x8A150107 нет сети, 0x8A15006C не скачались зависимости,
#           0x8A15006D служба занята (повторить позже), 0x8A150102 другая установка уже идёт
# (примечание: 0x8A150104 «нет зависимости» и 0x8A150002 «неверные аргументы» раньше попадали
#  в этот список ошибочно — повторы при них не помогают и маскируют настоящую причину)
$NetworkErrorCodes = @(
    -2147012894, -2147012889, -2147012867, -2147012866,   # HTTP/WinHTTP
    -1978335224, -1978334969, -1978335124, -1978335123, -1978334974
)

# Выполнить веб-действие с повторами. $Action — scriptblock; при исключении ждём и пробуем снова.
function Invoke-WithRetry([scriptblock]$Action, [int]$Tries = 3, [int]$DelaySec = 4, [string]$What = '') {
    for ($i = 1; $i -le $Tries; $i++) {
        try { return & $Action }
        catch {
            if ($i -eq $Tries) { throw }
            Write-Log ("  {0}: попытка {1} не удалась ({2}), жду {3} с и пробую снова" -f $What, $i, $_.Exception.Message, $DelaySec)
            Start-Sleep -Seconds $DelaySec
            $DelaySec *= 2
        }
    }
}

# ---------------------------------------------------------------------------
#  winget
# ---------------------------------------------------------------------------
# В Windows PowerShell 5.1 вывод программы в stderr при 'Stop' превращается в исключение,
# поэтому быстрые команды winget вызываем с 'Continue'. Код возврата — в $LASTEXITCODE.
function Invoke-Winget {
    $ErrorActionPreference = 'Continue'
    & winget @args 2>&1
}

function Ensure-Winget {
    if ($script:WingetExe) { return $true }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host '       winget не найден, пробую включить...' -ForegroundColor DarkGray
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
        } catch { Write-Log "Регистрация App Installer: $($_.Exception.Message)" }
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                    "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        try {
            $tmp = Join-Path $env:TEMP 'winget.msixbundle'
            $t = Start-ScriptTask 'winget' 'Скачиваю winget с сайта Microsoft' {
                param($Out) Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $Out -UseBasicParsing
            } @($tmp) $tmp
            Wait-Task $t | Out-Null
            Add-AppxPackage -Path $tmp
        } catch { Write-Log "Установка winget: $($_.Exception.Message)" }
    }
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    $script:WingetExe = $cmd.Source
    Invoke-Winget source update | Out-Null
    return $true
}

# -AllowReinstall: если стоит галочка «Переустановить», уже установленная программа ставится заново
# -ForTest: программа нужна только для тестов (её можно удалить после них)
function Install-WingetApp([string]$Id, [string]$Name, [string[]]$Extra = @(), [switch]$AllowReinstall, [switch]$ForTest) {
    if ($Offline) { Install-OfflineApp $Id $Name -AllowReinstall:$AllowReinstall -ForTest:$ForTest; return }
    if (-not (Ensure-Winget)) {
        Report FAIL "$Name — не установлен" 'winget недоступен: обновите «Установщик приложений» в Microsoft Store'
        return
    }
    Invoke-Winget list --id $Id -e --accept-source-agreements | Out-Null
    $present = ($LASTEXITCODE -eq 0)
    $again   = $present -and $AllowReinstall -and $script:Reinstall
    if ($present -and -not $again) { Report SKIP "$Name — уже установлен"; return }
    if ($again) { $Extra += '--force' }
    $verb = if ($again) { 'переустанавливается' } else { 'устанавливается' }
    $done = if ($again) { 'переустановлен' } else { 'установлен' }

    $out = Join-Path $env:TEMP ('winget-' + ($Id -replace '[^\w.-]', '_') + '.log')
    $wargs = @('install', '--id', $Id, '-e', '--source', 'winget', '--silent',
              '--accept-package-agreements', '--accept-source-agreements') + $Extra
    # До 3 попыток, если обрыв сети (по коду возврата winget).
    # Сбой запуска winget не должен ронять всю настройку: это просто ещё одна
    # неудачная установка — её предложат повторить в конце, как и остальные.
    $code = 0
    try {
        for ($try = 1; $try -le 3; $try++) {
            $code = Wait-Task (Start-ProcessTask $Name "$Name — $verb$(if ($try -gt 1) { " (попытка $try)" })" $script:WingetExe $wargs $out)
            Write-Log "winget install $Id -> $code (попытка $try)"
            if ($code -notin $NetworkErrorCodes -or $try -eq 3) { break }
            Write-Log "  похоже на обрыв сети, жду и пробую снова"
            Start-Sleep -Seconds (4 * $try)
        }
    } catch {
        Write-Log "winget install ${Id}: не удалось запустить — $($_.Exception.Message)"
        Report FAIL "$Name — ошибка установки" $_
        $script:FailedInstalls.Add(@{ Kind = 'winget'; Id = $Id; Name = $Name; AllowReinstall = [bool]$AllowReinstall })
        return
    }
    Write-Log-Clean $out

    if ($ForTest -and $code -in 0, -1978334967) { $script:TestInstalled.Add(@{ Id = $Id; Name = ($Name -split ' \(')[0] }) }
    switch ($code) {
        0            { Report OK   "$Name — $done" }
        -1978334967  { Report OK   "$Name — $done" 'нужна перезагрузка'; $script:RebootNeeded = $true }
        -1978335135  { Report SKIP "$Name — уже установлен" }
        -1978335212  { Report FAIL "$Name — не найден в winget" "проверьте ID: $Id"; $script:FailedInstalls.Add(@{ Kind = 'winget'; Id = $Id; Name = $Name; AllowReinstall = [bool]$AllowReinstall }) }
        default      {
            $why = if ($code -in $NetworkErrorCodes) { "обрыв сети (код 0x{0:X8}) — интернет пропадал; повторный запуск обычно доставит" } else { "код 0x{0:X8}, подробности в логе" }
            Report FAIL "$Name — ошибка установки" ($why -f $code)
            $script:FailedInstalls.Add(@{ Kind = 'winget'; Id = $Id; Name = $Name; AllowReinstall = [bool]$AllowReinstall })
        }
    }
}

function Uninstall-WingetApp([string]$Id, [string]$Name) {
    if (-not (Ensure-Winget)) { Report FAIL "$Name — не удалён" 'winget недоступен'; return }
    $out = Join-Path $env:TEMP ('winget-un-' + ($Id -replace '[^\w.-]', '_') + '.log')
    $code = $null
    try {
        $code = Wait-Task (Start-ProcessTask $Name "$Name — удаляется" $script:WingetExe @(
            'uninstall', '--id', $Id, '-e', '--silent', '--disable-interactivity', '--accept-source-agreements') $out)
    } catch { Write-Log "winget uninstall ${Id}: $($_.Exception.Message)" }
    # Если winget вообще не запустился, $code пустой. Раньше [int]$null = 0 давало
    # ложное «удалён» — теперь это честный WARN, а код приводим к int только для формата.
    Write-Log "winget uninstall $Id -> $code"
    if ($null -eq $code) { Report WARN "$Name — не удалось удалить (осталась на ПК)" 'winget не запустился; подробности в логе' }
    elseif ($code -eq 0) { Report OK "$Name — удалён" }
    else { Report WARN "$Name — не удалось удалить (осталась на ПК)" ("код 0x{0:X8}" -f [int]$code) }
}

# ---------------------------------------------------------------------------
#  Офлайн-режим
#  Если есть папка system\offline\ (её собирает кнопка «Собрать офлайн-папку» в стартовом окне),
#  программы, Office и драйверы ставятся из неё — интернет не нужен.
# ---------------------------------------------------------------------------
$OfflineDir  = Join-Path $PSScriptRoot 'offline'
# Офлайн-папка от старой версии (лежала рядом с .bat) — переносим в system\offline
$oldOffline = Join-Path $AppRoot 'offline'
if ((Test-Path (Join-Path $oldOffline 'offline-info.txt')) -and -not (Test-Path $OfflineDir)) {
    try { Move-Item $oldOffline $OfflineDir } catch {}
}
$OfflineInfo = Join-Path $OfflineDir 'offline-info.txt'
$Offline     = Test-Path $OfflineInfo

# При сборке офлайн-папки для некоторых программ берём конкретный тип установщика
# (иначе winget может скачать zip-версию, которую нельзя тихо установить)
$OfflineInstallerType = @{
    '7zip.7zip'                = 'exe'
    'Telegram.TelegramDesktop' = 'inno'
    'Notepad++.Notepad++'      = 'nullsoft'
    'VideoLAN.VLC'             = 'nullsoft'
    'Geeks3D.FurMark.2'        = 'inno'
}

# Программы, которые нужны только для стресс-теста (тоже кладутся в офлайн-папку)
# Какие классы драйверов считаются базовыми (для офлайн-папки)
$BaseDriverClasses = @('Net', 'Bluetooth', 'System', 'HDC', 'SCSIAdapter', 'USB')

$TestTools = @(
    @{ Id = '7zip.7zip';                                 Name = '7-Zip' }
    @{ Id = 'Geeks3D.FurMark.2';                         Name = 'FurMark' }
    @{ Id = 'namazso.PawnIO';                            Name = 'PawnIO (драйвер датчиков)' }
    @{ Id = 'LibreHardwareMonitor.LibreHardwareMonitor'; Name = 'LibreHardwareMonitor' }
)

function Get-OfflinePackage([string]$Id) {
    $dir = Join-Path $OfflineDir ('apps\' + ($Id -replace '[^\w.+-]', '_'))
    if (-not (Test-Path $dir)) { return $null }
    $yaml = Get-ChildItem $dir -File -Filter '*.yaml' -ErrorAction SilentlyContinue | Select-Object -First 1
    $file = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.yaml' } | Select-Object -First 1
    if (-not $file) { return $null }
    $m = if ($yaml) { Get-Content $yaml.FullName -Raw -Encoding UTF8 } else { '' }
    $get = { param($key) if ($m -match "(?m)^\s*-?\s*${key}:\s*(.+?)\s*$") { $Matches[1].Trim("'", '"') } else { '' } }
    [pscustomobject]@{
        File        = $file.FullName
        Type        = (& $get 'InstallerType')
        NestedType  = (& $get 'NestedInstallerType')
        Silent      = (& $get 'Silent')
        PackageName = (& $get 'PackageName')
    }
}

# Установлена ли программа (без интернета: winget list, если работает, иначе по списку программ Windows)
function Test-AppInstalled([string]$Id, $Pkg) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Invoke-Winget list --id $Id -e --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    if (-not $Pkg -or -not $Pkg.PackageName) { return $false }
    if ($Pkg.Type -in 'msix', 'appx') {
        return [bool](Get-AppxPackage -AllUsers -Name "*$($Pkg.PackageName -replace '\s', '')*" -ErrorAction SilentlyContinue)
    }
    return [bool](Get-ArpEntry $Pkg.PackageName)
}

function Get-ArpEntry([string]$DisplayName) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -like "$DisplayName*" } | Select-Object -First 1
}

function Install-OfflineApp([string]$Id, [string]$Name, [switch]$AllowReinstall, [switch]$ForTest) {
    $pkg = Get-OfflinePackage $Id
    if (-not $pkg) { Report FAIL "$Name — нет в офлайн-папке" 'соберите офлайн-папку на ПК с интернетом (кнопка в стартовом окне)'; return }

    $present = Test-AppInstalled $Id $pkg
    $again   = $present -and $AllowReinstall -and $script:Reinstall
    if ($present -and -not $again) { Report SKIP "$Name — уже установлен"; return }
    $verb = if ($again) { 'переустанавливается' } else { 'устанавливается' }
    $done = if ($again) { 'переустановлен' } else { 'установлен' }
    $f = $pkg.File

    try {
        # Портативные программы (zip) и пакеты Store (msix) ставятся без внешнего установщика
        if ($pkg.Type -eq 'zip') {
            $dest = Join-Path $env:ProgramFiles ($Name -split ' \(')[0]
            Wait-Task (Start-ScriptTask $Name "$Name — распаковывается" {
                param($Zip, $To) Expand-Archive -Path $Zip -DestinationPath $To -Force
            } @($f, $dest)) | Out-Null
            Report OK "$Name — $done" "распакован в $dest"
            if ($ForTest) { $script:TestInstalled.Add(@{ Id = $Id; Name = ($Name -split ' \(')[0]; Folder = $dest }) }
            return
        }
        if (($pkg.Type -in 'msix', 'appx') -or ($f -match '\.(msix|appx)(bundle)?$')) {
            Wait-Task (Start-ScriptTask $Name "$Name — устанавливается" {
                param($P) Add-AppxProvisionedPackage -Online -PackagePath $P -SkipLicense | Out-Null
            } @($f)) | Out-Null
            Report OK "$Name — $done"
            return
        }

        # Обычные установщики: ключи тихой установки по типу (как это делает winget)
        $file = $f; $argv = @()
        switch -Regex ($pkg.Type) {
            '^(msi|wix)$' { $file = "$env:SystemRoot\System32\msiexec.exe"; $argv = @('/i', "`"$f`"", '/qn', '/norestart') }
            '^burn$'      { $argv = @('/install', '/quiet', '/norestart') }
            '^nullsoft$'  { $argv = @('/S') }
            '^inno$'      { $argv = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') }
            default       { if ($f -match '\.msi$') { $file = "$env:SystemRoot\System32\msiexec.exe"; $argv = @('/i', "`"$f`"", '/qn', '/norestart') } }
        }
        if ($pkg.Silent -and $pkg.Type -notmatch '^(msi|wix)$') { $argv = $pkg.Silent -split '\s+' }

        $code = Wait-Task (Start-ProcessTask $Name "$Name — $verb (из офлайн-папки)" $file $argv)
        Write-Log "офлайн-установка $Id ($($pkg.Type)) -> $code"
        switch ($code) {
            { $_ -in 0 }          { Report OK "$Name — $done" }
            { $_ -in 3010, 1641 } { Report OK "$Name — $done" 'нужна перезагрузка'; $script:RebootNeeded = $true }
            1638                  { Report SKIP "$Name — уже установлен (более новая версия)" }
            default               { Report FAIL "$Name — ошибка установки" "код $code" }
        }
        if ($ForTest -and $code -in 0, 3010, 1641) { $script:TestInstalled.Add(@{ Id = $Id; Name = ($Name -split ' \(')[0]; Arp = $pkg.PackageName }) }
    } catch {
        Report FAIL "$Name — ошибка установки" $_
    }
}

# Удаление без интернета: через «тихую» команду удаления, записанную самой программой
function Uninstall-OfflineApp($Entry) {
    $name = $Entry.Name
    if ($Entry.Folder) {
        try { Remove-Item $Entry.Folder -Recurse -Force; Report OK "$name — удалён" } catch { Report FAIL "$name — не удалось удалить" $_ }
        return
    }
    $arp = Get-ArpEntry $Entry.Arp
    if (-not $arp) { Report SKIP "$name — не найден среди установленных"; return }
    $cmd = if ($arp.QuietUninstallString) { $arp.QuietUninstallString } else { $arp.UninstallString }
    if (-not $arp.QuietUninstallString) {
        if ($cmd -match 'msiexec') { $cmd = ($cmd -replace '/I', '/X') + ' /qn /norestart' }
        elseif ($cmd -match 'unins\d+\.exe') { $cmd += ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        else { $cmd += ' /S' }
    }
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
    else { $exe, $rest = $cmd -split '\s+', 2 }
    $code = Wait-Task (Start-ProcessTask $name "$name — удаляется" $exe @($rest | Where-Object { $_ }))
    if ($code -in 0, 3010) { Report OK "$name — удалён" } else { Report FAIL "$name — не удалось удалить" "код $code" }
}

# Поиск и скачивание драйвера NVIDIA (используется и при обычной установке, и при сборке офлайн-папки).
# Аргументы: название видеокарты, текущая версия драйвера (или ''), куда сохранить.
$NvidiaDownloadScript = {
    param($GpuName, $DriverVersion, $Out)
    $name = $GpuName -replace '^NVIDIA\s+', ''

    # Ищем модель в каталоге NVIDIA, чтобы получить её ID (pfid) и серию (psid)
    $psid = 120; $pfid = 929   # если модель не найдётся — общий драйвер GeForce
    try {
        [xml]$xml = (Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3').Content
        $match = $xml.LookupValueSearch.LookupValues.LookupValue |
            Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($match) { $psid = $match.ParentID; $pfid = $match.Value }
    } catch {}

    $api = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php' +
           "?func=DriverManualLookup&psid=$psid&pfid=$pfid&osID=135&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"
    # Сайт отдаёт JSON как text/html, поэтому разбираем вручную
    $info = ((Invoke-WebRequest -Uri $api -UseBasicParsing).Content | ConvertFrom-Json).IDS[0].downloadInfo
    if (-not $info.DownloadURL) { throw 'NVIDIA не вернула ссылку на драйвер' }

    # Версия Windows "32.0.15.6094" -> версия NVIDIA "560.94"
    $digits  = "$DriverVersion" -replace '\.', ''
    $current = if ($digits.Length -ge 5) { $digits.Substring($digits.Length - 5).Insert(3, '.') } else { '' }
    $result  = [pscustomobject]@{ Latest = $info.Version; Current = $current; Skip = ($current -eq $info.Version) }
    if ($result.Skip) { return $result }

    $Status.Text = "Драйвер NVIDIA $($info.Version): скачивается (около 700 МБ)"
    Remove-Item $Out -Force -ErrorAction SilentlyContinue
    # 3 попытки: большой файл, соединение может оборваться
    $last = $null
    for ($try = 1; $try -le 3; $try++) {
        try { Invoke-WebRequest -Uri $info.DownloadURL -OutFile $Out -UseBasicParsing; return $result }
        catch { $last = $_; if ($try -lt 3) { Start-Sleep -Seconds (4 * $try) } }
    }
    throw $last
}

# Установка скачанного драйвера NVIDIA (распаковка 7-Zip, если есть, и тихая установка)
function Install-NvidiaPackage($Gpu, [string]$Exe, [string]$Version, [string]$Current) {
    $setup = $Exe
    $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"
    if (Test-Path $sevenZip) {
        $dir = Join-Path $env:TEMP 'nvidia-driver'
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        Wait-Task (Start-ProcessTask 'распаковка' "Драйвер NVIDIA $($Version): распаковывается" `
            $sevenZip @('x', "`"$Exe`"", "-o`"$dir`"", '-y')) | Out-Null
        $setup = Join-Path $dir 'setup.exe'
    }
    $code = Wait-Task (Start-ProcessTask 'NVIDIA' "Драйвер NVIDIA $($Version): устанавливается (экран может мигнуть)" `
        $setup @('-s', '-noreboot', '-noeula'))
    if ($code -eq 0) {
        $script:RebootNeeded = $true
        $from = if ($Current) { "было $Current" } else { '' }
        Report OK "$($Gpu.Name) — драйвер NVIDIA $Version установлен" $from
    } else {
        Report FAIL "$($Gpu.Name) — драйвер NVIDIA не установился" "код $code; вручную: https://www.nvidia.com/drivers"
    }
}

# XML-настройка для установщика Office (ODT). $Source — папка с офлайн-дистрибутивом или пусто.
function Get-OfficeConfig([string]$Source, [switch]$ForDownload) {
    $allOfficeApps = 'Word', 'Excel', 'PowerPoint', 'Outlook', 'OutlookForWindows', 'OneNote',
                     'Access', 'Publisher', 'Teams', 'Lync', 'Groove', 'OneDrive', 'Bing'
    $exclude = if ($ForDownload) { '' } else {
        ($allOfficeApps | Where-Object { $_ -notin $OfficeApps } |
            ForEach-Object { "      <ExcludeApp ID=`"$_`" />" }) -join "`r`n"
    }
    $srcAttr  = if ($Source) { " SourcePath=`"$Source`" AllowCdnFallback=`"FALSE`"" } else { '' }
    $language = if ($Source) { "<Language ID=`"$OfficeLanguage`" />" } else { "<Language ID=`"MatchOS`" Fallback=`"$OfficeLanguage`" />" }
    $display  = if ($ForDownload) { '' } else { '  <Display Level="None" AcceptEULA="TRUE" />' }
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current"$srcAttr>
    <Product ID="$OfficeProduct">
      $language
$exclude
    </Product>
  </Add>
$display
</Configuration>
"@
}

# Установлен ли Office: по exe-файлу любого приложения из $OfficeApps, а не только по Word —
# Word может быть исключён из набора, и тогда WINWORD.EXE не появится
$script:OfficeExe = @{ Word = 'WINWORD.EXE'; Excel = 'EXCEL.EXE'; PowerPoint = 'POWERPNT.EXE'
                       Outlook = 'OUTLOOK.EXE'; OneNote = 'ONENOTE.EXE'; Access = 'MSACCESS.EXE'; Publisher = 'MSPUB.EXE' }
function Test-OfficeInstalled {
    $root = "$env:ProgramFiles\Microsoft Office\root\Office16"
    if (-not (Test-Path $root)) { return $false }
    return [bool](@($OfficeApps | ForEach-Object { $script:OfficeExe[$_] } |
        Where-Object { $_ -and (Test-Path (Join-Path $root $_)) }))
}

# Установка Office из заранее подготовленного установщика (ставится ПОСЛЕ программ, по очереди).
# При ошибке 1603 и других — дописывает в лог журнал установщика Office (ODT).
function Invoke-OfficeInstall {
    if (-not $script:OfficeReady) { return }
    try {
        $code = Wait-Task (Start-ProcessTask 'Office' "Microsoft Office ($($OfficeApps -join ', ')) — $(if ($script:OfficeAgain) { 'переустанавливается' } else { 'устанавливается' })" `
            $script:OfficeOdt @('/configure', "`"$($script:OfficeCfg)`""))
        Write-Log "Office /configure -> $code"
        if ($code -eq 0 -and (Test-OfficeInstalled)) {
            Report OK "Microsoft Office — $(if ($script:OfficeAgain) { 'переустановлен' } else { 'установлен' })" 'при первом запуске войдите в учётную запись Microsoft с лицензией'
            $script:OfficeReady = $false
            return
        }
        # Не встал — сохраняем журнал установщика Office в наш лог (он помогает понять причину 1603)
        $olog = Get-ChildItem $env:TEMP -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)office|Microsoft.*Setup|SCS' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($olog) {
            Write-Log "--- журнал установщика Office ($($olog.Name)), последние строки: ---"
            Get-Content $olog.FullName -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "    $_" }
        }
        $hint = if ($code -eq 1603) { 'код 1603 — обычно мешает уже стоящий Office/остатки; удалите его и запустите «Только установка программ»' } else { "код $code" }
        Report FAIL 'Microsoft Office — не установился' $hint
        $script:FailedInstalls.Add(@{ Kind = 'office'; Name = 'Microsoft Office' })
        Add-Manual 'Microsoft Office не установился. Запустите «Настройка Windows.bat» -> «Только установка программ» ещё раз; если снова ошибка 1603 — сначала удалите Office из «Программы и компоненты».'
    } catch {
        Report FAIL 'Microsoft Office — не установился' $_
        $script:FailedInstalls.Add(@{ Kind = 'office'; Name = 'Microsoft Office' })
    }
}

# ---------------------------------------------------------------------------
#  Сведения о железе и системе (для проверки системы и паспорта ПК)
# ---------------------------------------------------------------------------
# Вызов консольной программы без исключений на stderr; вывод — строками, код — в $LASTEXITCODE
function Invoke-Quiet([string]$Exe) {
    $ErrorActionPreference = 'Continue'
    & $Exe @args 2>&1 | ForEach-Object { "$_" }
}

# Заявленная частота памяти: из маркировки модуля (там обычно указан XMP/EXPO-профиль) или из SPD
function Get-RatedRamSpeed([string]$Part, [int]$Spd) {
    $p = "$Part".Trim().ToUpper()
    $c = @($Spd)
    if ($p -match '^(KF|HX)\d(\d{2})C')  { $c += [int]$Matches[2] * 100 }   # Kingston Fury / HyperX: KF432C16 -> 3200
    if ($p -match '^F[45]-(\d{4})')       { $c += [int]$Matches[1] }         # G.Skill: F4-3600C16
    if ($p -match '^BL\d+G(\d{2})C')      { $c += [int]$Matches[1] * 100 }   # Crucial Ballistix: BL8G32C16 -> 3200
    if ($p -match '(?<!\d)(2133|2400|2666|2933|3000|3200|3466|3600|3733|3866|4000|4266|4400|4800|5200|5600|6000|6200|6400|6800|7200|7600|8000)(?!\d)') {
        $c += [int]$Matches[1]                                               # Corsair CMK16GX4M2B3200C16 и т.п.
    }
    ($c | Measure-Object -Maximum).Maximum
}

function Get-RamInfo {
    @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        [pscustomobject]@{
            Slot       = "$($_.DeviceLocator)".Trim()
            SizeGB     = [Math]::Round($_.Capacity / 1GB)
            Maker      = "$($_.Manufacturer)".Trim()
            Part       = "$($_.PartNumber)".Trim()
            # На части плат с DDR5 WMI отдаёт ConfiguredClockSpeed = 0 — тогда берём SPD-частоту,
            # чтобы не пугать пользователя «память работает на 0 МГц»
            Configured = if ($_.ConfiguredClockSpeed) { [int]$_.ConfiguredClockSpeed } else { [int]$_.Speed }
            Rated      = Get-RatedRamSpeed $_.PartNumber ([int]$_.Speed)
            Type       = switch ([int]$_.SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { '' } }
        }
    })
}

function Get-HealthRu([string]$H) {
    switch ($H) { 'Healthy' { 'исправен' } 'Warning' { 'предупреждение' } 'Unhealthy' { 'неисправен' } default { $H } }
}

function Get-DiskInfo {
    @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId | ForEach-Object {
        $r = $null
        try { $r = $_ | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        [pscustomobject]@{
            Model   = "$($_.FriendlyName)".Trim()
            SizeGB  = [Math]::Round($_.Size / 1GB)
            Media   = "$($_.MediaType)"
            Bus     = "$($_.BusType)"
            Health  = "$($_.HealthStatus)"
            Wear    = if ($r -and $null -ne $r.Wear) { [int]$r.Wear } else { $null }
            Temp    = if ($r -and $r.Temperature) { [int]$r.Temperature } else { $null }
            TempMax = if ($r -and $r.TemperatureMax) { [int]$r.TemperatureMax } else { $null }
            Hours   = if ($r -and $r.PowerOnHours) { [int]$r.PowerOnHours } else { $null }
            Errors  = if ($r) { [int]$r.ReadErrorsUncorrected + [int]$r.WriteErrorsUncorrected } else { 0 }
        }
    })
}

function Get-PlatformInfo {
    $i = [ordered]@{ Activated = $null; Uefi = $null; SecureBoot = $null; Tpm = $null; FreeGB = $null; SysGB = $null }
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        $i.Activated = ($lic.LicenseStatus -eq 1)
    } catch {}
    try { $i.Uefi = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType).PEFirmwareType -eq 2) } catch {}
    try { $i.SecureBoot = [bool](Confirm-SecureBootUEFI) } catch { if ($i.Uefi -eq $false) { $i.SecureBoot = $false } }
    try {
        $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        $i.Tpm = if ($t) { ("$($t.SpecVersion)" -split ',')[0].Trim() } else { '' }
    } catch { $i.Tpm = '' }
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        $i.FreeGB = [Math]::Round($d.FreeSpace / 1GB); $i.SysGB = [Math]::Round($d.Size / 1GB)
    } catch {}
    [pscustomobject]$i
}

function Test-IsLaptop {
    if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { return $true }
    $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
    return [bool]($types | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 })
}

# Настоящие видеокарты (NVIDIA/AMD/Intel) и стоит ли у них драйвер производителя.
# Если Windows поставила «Базовый видеоадаптер (Майкрософт)» — драйвера, по сути, нет.
function Get-GpuState {
    @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match '^PCI' } | ForEach-Object {
        $vendor = switch -Regex ("$($_.PNPDeviceID)") {
            'VEN_10DE' { 'NVIDIA' } 'VEN_1002' { 'AMD' } 'VEN_8086' { 'Intel' } default { 'другой' }
        }
        # «Базовый видеоадаптер», Microsoft как поставщик драйвера или отсутствие версии = драйвера нет
        $basic = ("$($_.Name)" -match 'Basic|Базов' ) -or
                 ("$($_.InstalledDisplayDrivers)" -match '\\BasicDisplay\\|\\BasicRender\\') -or
                 (-not $_.DriverVersion)
        [pscustomobject]@{
            Name = "$($_.Name)".Trim(); Vendor = $vendor
            DriverVersion = "$($_.DriverVersion)"; HasDriver = (-not $basic)
        }
    })
}

# Короткая сводка железа для начала работы: процессор, видеокарта(ы) + драйвер, память, ноут/ПК.
function Write-HardwareSummary {
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $ram = @(Get-RamInfo)
        $ramGB = ($ram | Measure-Object SizeGB -Sum).Sum
        $ramType = ($ram | Select-Object -First 1).Type
        $kind = if (Test-IsLaptop) { 'ноутбук' } else { 'настольный ПК' }
        Report OK ("Это {0}: {1}" -f $kind, ("$($cpu.Name)".Trim()))
        if ($ramGB) { Report OK ("Память: {0} ГБ {1}, планок: {2}" -f $ramGB, $ramType, $ram.Count) }
        foreach ($g in (Get-GpuState | Where-Object { $_.Vendor -in 'NVIDIA', 'AMD', 'Intel' })) {
            if ($g.HasDriver) { Report OK ("Видеокарта: {0} (драйвер {1})" -f $g.Name, $g.DriverVersion) }
            else { Report WARN ("Видеокарта: {0} — драйвер не установлен" -f $g.Name) 'работает как «Базовый видеоадаптер»; скрипт попробует поставить драйвер' }
        }
    } catch { Write-Log "Сводка железа: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Температуры во время стресс-теста
#  LibreHardwareMonitor (с открытым кодом) запускается свёрнутым с локальным веб-сервером,
#  фоновая задача раз в 2 секунды читает температуры и частоту процессора.
# ---------------------------------------------------------------------------
$LhmPort = 8085

function Find-LhmExe {
    foreach ($root in "$env:ProgramFiles\LibreHardwareMonitor", "$env:ProgramFiles\WinGet\Packages",
                      "$env:LOCALAPPDATA\Microsoft\WinGet\Packages") {
        $f = Get-ChildItem $root -Recurse -Filter 'LibreHardwareMonitor.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
}

function Start-TempMonitor {
    # Нужен драйвер датчиков PawnIO и сама программа
    Install-WingetApp 'namazso.PawnIO' 'PawnIO (драйвер датчиков температуры)' -ForTest
    $exe = Find-LhmExe
    if (-not $exe) {
        Install-WingetApp 'LibreHardwareMonitor.LibreHardwareMonitor' 'LibreHardwareMonitor (температуры)' -ForTest
        $exe = Find-LhmExe
    }
    $lhm = $null
    if ($exe) {
        # Настройки: свернуть в трей при запуске и включить локальный веб-сервер с данными датчиков
        $cfg = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="startMinMenuItem" value="true" />
    <add key="minTrayMenuItem" value="true" />
    <add key="runWebServerMenuItem" value="true" />
    <add key="listenerPort" value="$LhmPort" />
  </appSettings>
</configuration>
"@
        try { Set-Content -Path (Join-Path (Split-Path $exe) 'LibreHardwareMonitor.config') -Value $cfg -Encoding UTF8 } catch {}
        Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        try { $lhm = Start-Process $exe -WindowStyle Minimized -PassThru } catch { Write-Log "LibreHardwareMonitor: $($_.Exception.Message)" }
    } else {
        Report WARN 'LibreHardwareMonitor не установлен' 'температура процессора не будет измерена'
    }

    $task = Start-ScriptTask 'датчики' 'Слежу за температурами' {
        param($Port)
        $Status.CpuMax = $null; $Status.GpuMax = $null; $Status.Perf = New-Object System.Collections.ArrayList
        $Status.Source = ''
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $num = { param($v) $d = 0.0; if ([double]::TryParse(("$v" -replace ',', '.' -replace '[^\d.\-]', ''), [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { $d } else { $null } }
        $nvsmi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
        if (-not $nvsmi -and (Test-Path "$env:SystemRoot\System32\nvidia-smi.exe")) { $nvsmi = "$env:SystemRoot\System32\nvidia-smi.exe" }

        while (-not $Status.Stop) {
            $cpuT = $null; $gpuT = $null
            try {
                $j = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/data.json" -TimeoutSec 3
                $Status.Source = 'LibreHardwareMonitor'
                $stack = New-Object System.Collections.Stack
                $stack.Push(@($j, ''))
                while ($stack.Count) {
                    $item = $stack.Pop(); $n = $item[0]; $hw = $item[1]
                    if ($n.ImageURL -match 'images_icon/(\w+)\.png') {
                        switch -Regex ($Matches[1]) { '^cpu$' { $hw = 'cpu' } '^(nvidia|ati|amd|intel|intelgpu|gpu)' { $hw = 'gpu' } }
                    }
                    if ($n.Type -eq 'Temperature') {
                        $v = & $num $(if ($null -ne $n.RawValue) { $n.RawValue } else { $n.Value })
                        if ($v -and $v -gt 0 -and $v -lt 150) {
                            if ($hw -eq 'cpu' -and $n.Text -match 'Package|Tctl|Tdie|Core Max|CPU') { if ($null -eq $cpuT -or $v -gt $cpuT) { $cpuT = $v } }
                            if ($hw -eq 'gpu' -and $n.Text -match '^GPU Core$|^GPU$|Core') { if ($null -eq $gpuT -or $v -gt $gpuT) { $gpuT = $v } }
                        }
                    }
                    foreach ($c in @($n.Children)) { if ($c) { $stack.Push(@($c, $hw)) } }
                }
            } catch {}
            # Видеокарта NVIDIA: если LibreHardwareMonitor не дал температуру — берём из nvidia-smi
            if ($null -eq $gpuT -and $nvsmi) {
                try { $gpuT = & $num ((& $nvsmi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null) | Select-Object -First 1) } catch {}
            }
            if ($null -ne $cpuT -and ($null -eq $Status.CpuMax -or $cpuT -gt $Status.CpuMax)) { $Status.CpuMax = $cpuT }
            if ($null -ne $gpuT -and ($null -eq $Status.GpuMax -or $gpuT -gt $Status.GpuMax)) { $Status.GpuMax = $gpuT }

            # Частота процессора в % от номинала — по ней видно троттлинг (сброс частоты от перегрева)
            if ($Status.Phase -eq 'cpu') {
                try {
                    $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
                    [void]$Status.Perf.Add([int]$p.PercentProcessorPerformance)
                } catch {}
            }
            $parts = @()
            if ($null -ne $Status.CpuMax) { $parts += "CPU макс. $([int]$Status.CpuMax) °C" }
            if ($null -ne $Status.GpuMax) { $parts += "GPU макс. $([int]$Status.GpuMax) °C" }
            if ($parts) { $Status.Text = 'Температуры: ' + ($parts -join ', ') }
            Start-Sleep -Seconds 2
        }
    } @($LhmPort)
    $task.Status.Phase = 'idle'
    [pscustomobject]@{ Task = $task; Process = $lhm }
}

function Stop-TempMonitor($Mon) {
    if (-not $Mon) { return $null }
    $s = $Mon.Task.Status
    $s.Stop = $true
    try { Wait-Task $Mon.Task | Out-Null } catch {}
    if ($Mon.Process) { try { Stop-Process -Id $Mon.Process.Id -Force -ErrorAction SilentlyContinue } catch {} }
    Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Троттлинг: сравниваем частоту в начале нагрузки и в последней трети теста
    $perf = @($s.Perf | Where-Object { $_ -gt 0 })
    $drop = $null
    if ($perf.Count -ge 9) {
        $n = [Math]::Floor($perf.Count / 3)
        $first = ($perf[0..($n - 1)] | Measure-Object -Average).Average
        $last  = ($perf[($perf.Count - $n)..($perf.Count - 1)] | Measure-Object -Average).Average
        if ($first -gt 0) { $drop = [Math]::Round(100 * ($first - $last) / $first) }
    }
    [pscustomobject]@{ CpuMax = $s.CpuMax; GpuMax = $s.GpuMax; Source = $s.Source; FreqDrop = $drop }
}

# ---------------------------------------------------------------------------
#  Паспорт ПК: HTML-страница на рабочем столе
# ---------------------------------------------------------------------------
function Write-Passport {
    $h = { param($v) [System.Net.WebUtility]::HtmlEncode("$v") }
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bb   = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match '^PCI' })
    $ram  = Get-RamInfo
    $disks = Get-DiskInfo
    $pl   = Get-PlatformInfo
    $yn   = { param($v, $yes = 'да', $no = 'нет') if ($null -eq $v) { '—' } elseif ($v) { $yes } else { $no } }

    $rows = { param($pairs) ($pairs | ForEach-Object { "<tr><th>$(& $h $_[0])</th><td>$(& $h $_[1])</td></tr>" }) -join "`n" }
    $sys = & $rows @(
        ,@('Компьютер', "$($cs.Manufacturer) $($cs.Model)")
        ,@('Материнская плата', "$($bb.Manufacturer) $($bb.Product)")
        ,@('BIOS', "$($bios.SMBIOSBIOSVersion) от $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('dd.MM.yyyy') })")
        ,@('Процессор', "$("$($cpu.Name)".Trim()) — $($cpu.NumberOfCores) ядер / $($cpu.NumberOfLogicalProcessors) потоков")
        ,@('Оперативная память', ('{0} ГБ, планок: {1}' -f ($ram | Measure-Object SizeGB -Sum).Sum, $ram.Count))
        ,@('Windows', "$($os.Caption) (сборка $($os.BuildNumber))")
        ,@('Активация', (& $yn $pl.Activated 'активирована' 'НЕ активирована'))
        ,@('UEFI / Secure Boot / TPM', "$(& $yn $pl.Uefi 'UEFI' 'Legacy BIOS') / $(& $yn $pl.SecureBoot 'вкл' 'выкл') / $(if ($pl.Tpm) { "TPM $($pl.Tpm)" } else { 'нет TPM' })")
        ,@('Системный диск', "свободно $($pl.FreeGB) из $($pl.SysGB) ГБ")
    )
    $gpuRows = ($gpus | ForEach-Object {
        "<tr><td>$(& $h $_.Name)</td><td>$(& $h $_.DriverVersion)</td><td>$(& $h "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution) $($_.CurrentRefreshRate) Гц")</td></tr>"
    }) -join "`n"
    $ramRows = ($ram | ForEach-Object {
        $st = if ($_.Rated -gt $_.Configured * 1.05) { ' class="warn"' } else { '' }
        "<tr$st><td>$(& $h $_.Slot)</td><td>$($_.SizeGB) ГБ $($_.Type)</td><td>$(& $h "$($_.Maker) $($_.Part)")</td><td>$($_.Configured) / $($_.Rated) МГц</td></tr>"
    }) -join "`n"
    $diskRows = ($disks | Where-Object { $_.Bus -notin 'USB', 'SD', 'MMC' } | ForEach-Object {
        $st = if ($_.Health -ne 'Healthy' -or $_.Errors -gt 0) { ' class="bad"' } elseif ($_.Wear -ge 80) { ' class="warn"' } else { '' }
        $wear = if ($null -ne $_.Wear) { "$($_.Wear)%" } else { '—' }
        $temp = if ($_.Temp) { "$($_.Temp) °C" } else { '—' }
        $hrs  = if ($_.Hours) { '{0:N0} ч' -f $_.Hours } else { '—' }
        "<tr$st><td>$(& $h $_.Model)</td><td>$($_.SizeGB) ГБ $($_.Media) $($_.Bus)</td><td>$(& $h (Get-HealthRu $_.Health))</td><td>$wear</td><td>$temp</td><td>$hrs</td></tr>"
    }) -join "`n"

    $stress = ''
    if ($script:StressData) {
        $d = $script:StressData
        $stress = '<h2>Стресс-тест</h2><table>' + (& $rows @(
            ,@('Процессор (7-Zip)', $(if ($d.Rating) { ('{0:N0} MIPS, {1}' -f $d.Rating, (& $yn $d.Stable 'стабильно' 'ОШИБКИ')) } else { '—' }))
            ,@('Видеокарта (FurMark)', $(if ($null -ne $d.GpuStable) { "$(if ($d.GpuScore) { "$($d.GpuScore) очков, " })$(& $yn $d.GpuStable 'стабильно' 'сбои / прерван')" } else { '—' }))
            ,@('Макс. температура CPU', $(if ($d.CpuMax) { "$([int]$d.CpuMax) °C" } else { '—' }))
            ,@('Макс. температура GPU', $(if ($d.GpuMax) { "$([int]$d.GpuMax) °C" } else { '—' }))
            ,@('Троттлинг процессора', $(if ($null -ne $d.FreqDrop) { if ($d.FreqDrop -ge 15) { "да, частота упала на $($d.FreqDrop)%" } else { 'нет' } } else { '—' }))
            ,@('Оценки WinSAT (CPU / RAM / графика / диск)', $(if ($d.Sat) { "$($d.Sat.CPUScore) / $($d.Sat.MemoryScore) / $($d.Sat.D3DScore) / $($d.Sat.DiskScore)" } else { '—' }))
        )) + '</table>'
    }

    $manualHtml = ''
    if ($script:ManualActions.Count) {
        $manualHtml = '<h2>Что сделать руками</h2><ul>' +
            (($script:ManualActions | ForEach-Object { "<li class=`"warn`">$(& $h $_)</li>" }) -join '') + '</ul>'
    }

    $issues = @($script:Results | Where-Object { $_.Status -in 'FAIL', 'WARN' })
    $issueHtml = if ($issues) {
        '<h2>Замечания</h2><ul>' + (($issues | ForEach-Object {
            $cls = if ($_.Status -eq 'FAIL') { 'bad' } else { 'warn' }
            "<li class=`"$cls`">$(& $h $_.Text)$(if ($_.Details) { " — $(& $h $_.Details)" })</li>"
        }) -join '') + '</ul>'
    } else { '<h2>Замечания</h2><p class="ok">Замечаний нет.</p>' }

    $html = @"
<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8"><title>Паспорт ПК — $(& $h $env:COMPUTERNAME)</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;max-width:980px;margin:24px auto;padding:0 16px;color:#1b1b1b}
 h1{margin-bottom:4px} .sub{color:#666;margin-top:0}
 h2{margin-top:28px;border-bottom:2px solid #e5e5e5;padding-bottom:4px}
 table{border-collapse:collapse;width:100%} th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #eee;vertical-align:top}
 th{width:260px;color:#444;font-weight:600} thead th{background:#f5f5f5;width:auto}
 .warn{background:#fff6db} .bad{background:#ffe3e3} .ok{color:#1a7f37}
 @media print{body{margin:0}}
</style></head><body>
<h1>Паспорт ПК</h1>
<p class="sub">$(& $h $env:COMPUTERNAME) · составлен $(Get-Date -Format 'dd.MM.yyyy HH:mm')</p>
<h2>Система</h2><table>$sys</table>
<h2>Видеокарты</h2><table><thead><tr><th>Модель</th><th>Драйвер</th><th>Режим экрана</th></tr></thead>$gpuRows</table>
<h2>Оперативная память</h2><table><thead><tr><th>Слот</th><th>Объём</th><th>Модуль</th><th>Частота: работает / заявлена</th></tr></thead>$ramRows</table>
<h2>Диски</h2><table><thead><tr><th>Модель</th><th>Тип</th><th>Состояние</th><th>Износ</th><th>Температура</th><th>Наработка</th></tr></thead>$diskRows</table>
$stress
$manualHtml
$issueHtml
</body></html>
"@
    $name = "Паспорт ПК $(Get-Date -Format 'yyyy-MM-dd HH-mm').html"
    # На рабочий стол и копия рядом со скриптом (если рабочего стола нет — только рядом со скриптом)
    $local = Join-Path $LogDir $name
    Set-Content -Path $local -Value $html -Encoding UTF8
    $desk = [Environment]::GetFolderPath('Desktop')
    if ($desk -and (Test-Path $desk)) {
        $file = Join-Path $desk $name
        try { Copy-Item $local $file -Force; return $file } catch {}
    }
    return $local
}

# ---------------------------------------------------------------------------
#  Отчёт для разбора: один архив с логом, итогом стресс-теста, паспортом и сведениями о системе.
#  Его удобно отправить одним файлом, если что-то пошло не так.
# ---------------------------------------------------------------------------
function New-ReportBundle {
    try {
        $stage = Join-Path $env:TEMP ("win11-report_{0:yyyy-MM-dd_HH-mm}" -f (Get-Date))
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        # Лог этого запуска, итог стресс-теста и паспорт (последние по времени)
        if (Test-Path $LogFile) { Copy-Item $LogFile $stage -Force -ErrorAction SilentlyContinue }
        foreach ($mask in 'stress-test_*.txt', 'Паспорт ПК*.html') {
            Get-ChildItem $LogDir -Filter $mask -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
                ForEach-Object { Copy-Item $_.FullName $stage -Force -ErrorAction SilentlyContinue }
        }
        # Короткая сводка по системе
        try {
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $sysTxt = @(
                "Компьютер: $((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)"
                "Тип: $(if (Test-IsLaptop) { 'ноутбук' } else { 'настольный ПК' })"
                "Процессор: $("$($cpu.Name)".Trim())"
                "ОС: $($os.Caption) (сборка $($os.BuildNumber))"
                "Видеокарты:"
            ) + @(Get-GpuState | ForEach-Object { "  - $($_.Name): $(if ($_.HasDriver) { "драйвер $($_.DriverVersion)" } else { 'драйвер НЕ установлен' })" })
            Set-Content -Path (Join-Path $stage 'система.txt') -Value ($sysTxt -join "`r`n") -Encoding UTF8
        } catch {}

        $zipName = "Отчёт для разбора $(Get-Date -Format 'yyyy-MM-dd HH-mm').zip"
        $zipLocal = Join-Path $LogDir $zipName
        Remove-Item $zipLocal -Force -ErrorAction SilentlyContinue
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipLocal -Force
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

        $desk = [Environment]::GetFolderPath('Desktop')
        if ($desk -and (Test-Path $desk)) {
            try { Copy-Item $zipLocal (Join-Path $desk $zipName) -Force; return (Join-Path $desk $zipName) } catch {}
        }
        return $zipLocal
    } catch { Write-Log "Сборка отчёта: $($_.Exception.Message)"; return $null }
}

# ---------------------------------------------------------------------------
#  Реестр профиля «по умолчанию» (для новых пользователей в режиме передачи ПК)
#  Пока он загружен, все настройки HKCU записываются ещё и туда.
# ---------------------------------------------------------------------------
$script:DefaultHive = $null
function Mount-DefaultUserHive {
    $dat = "$env:SystemDrive\Users\Default\NTUSER.DAT"
    Invoke-Quiet "$env:SystemRoot\System32\reg.exe" load 'HKU\W11SetupDefault' $dat | Out-Null
    if ($LASTEXITCODE -eq 0) { $script:DefaultHive = 'W11SetupDefault' }
    return [bool]$script:DefaultHive
}
function Dismount-DefaultUserHive {
    if (-not $script:DefaultHive) { return }
    $script:DefaultHive = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 500
    Invoke-Quiet "$env:SystemRoot\System32\reg.exe" unload 'HKU\W11SetupDefault' | Out-Null
}
# HKCU:\... -> тот же путь в профиле по умолчанию
function Get-DefaultHivePath([string]$Path) {
    if ($script:DefaultHive -and $Path -match '^HKCU:\\(.*)$') { "Registry::HKEY_USERS\$($script:DefaultHive)\$($Matches[1])" }
}

# ---------------------------------------------------------------------------
#  Программы по умолчанию: ищем ProgId программы для типа файла
# ---------------------------------------------------------------------------
function Find-ProgId([string]$Type, [string]$Match) {
    $isUrl = -not $Type.StartsWith('.')
    # 1) Зарегистрированные приложения (Chrome, VLC и др. описывают свои типы файлов)
    foreach ($root in 'HKLM:\SOFTWARE\RegisteredApplications', 'HKCU:\SOFTWARE\RegisteredApplications') {
        $apps = Get-ItemProperty $root -ErrorAction SilentlyContinue
        if (-not $apps) { continue }
        foreach ($p in $apps.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            if ($p.Name -notmatch $Match -and "$($p.Value)" -notmatch $Match) { continue }
            $hive = if ($root -like 'HKLM*') { 'HKLM:' } else { 'HKCU:' }
            $sub  = if ($isUrl) { 'URLAssociations' } else { 'FileAssociations' }
            $id = (Get-ItemProperty "$hive\$($p.Value)\$sub" -ErrorAction SilentlyContinue).$Type
            if ($id) { return $id }
        }
    }
    # 2) «Открыть с помощью» у расширения (так регистрируются WinRAR и приложения из Store)
    if (-not $isUrl) {
        $ow = Get-Item "Registry::HKEY_CLASSES_ROOT\$Type\OpenWithProgids" -ErrorAction SilentlyContinue
        foreach ($id in @($ow.Property)) {
            if ($id -match $Match) { return $id }
            $appName = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$id\Application" -ErrorAction SilentlyContinue).ApplicationName
            if ("$appName" -match $Match) { return $id }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  Реестр и службы
# ---------------------------------------------------------------------------
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    # В режиме передачи ПК настройки пользователя пишутся и в профиль по умолчанию (для нового владельца)
    $d = Get-DefaultHivePath $Path
    if ($d) {
        try {
            if (-not (Test-Path $d)) { New-Item -Path $d -Force | Out-Null }
            New-ItemProperty -Path $d -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        } catch { Write-Log "  профиль по умолчанию: $d\$Name — $($_.Exception.Message)" }
    }
}

# Применяет набор параметров реестра и пишет одну строку результата
function Apply-RegSet([string]$Title, [array]$Items) {
    try {
        foreach ($i in $Items) { Set-Reg @i }
        Report OK $Title
    } catch {
        Report FAIL $Title $_.Exception.Message
    }
}

# Открыть файл (например, паспорт ПК) в БРАУЗЕРЕ, а не в программе по умолчанию для .html
# (у разработчиков .html часто назначен на редактор — тогда страница открывалась бы как код)
function Open-InBrowser([string]$File) {
    if (-not $File -or -not (Test-Path $File)) { return }
    # 1) Браузер по умолчанию = обработчик протокола http
    try {
        $progId = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -ErrorAction Stop).ProgId
        $cmd    = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction Stop).'(default)'
        $exe    = if ($cmd -match '"([^"]+\.exe)"') { $Matches[1] } elseif ($cmd -match '^(\S+\.exe)') { $Matches[1] } else { $null }
        # Путь в кавычках: иначе браузер делит имя с пробелами на несколько «файлов»
        if ($exe -and (Test-Path $exe)) { Start-Process $exe -ArgumentList "`"$File`""; return }
    } catch {}
    # 2) Запасные варианты: известные браузеры
    foreach ($b in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) { if (Test-Path $b) { Start-Process $b -ArgumentList "`"$File`""; return } }
    # 3) Последний шанс — программа по умолчанию для .html
    try { Start-Process $File } catch {}
}

function Disable-ServiceSafe([string]$Name, [string]$Desc) {
    $label = "$Desc [$Name]"
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Report SKIP "$label — нет на этом ПК"; return }
    if ($svc.StartType -eq 'Disabled' -and $svc.Status -ne 'Running') {
        Report SKIP "$label — уже отключена"; return
    }
    try {
        if ($svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction Stop }
    } catch {
        Write-Log "  не удалось остановить ${Name}: $($_.Exception.Message)"
    }
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        Report OK "$label — отключена"
    } catch {
        # Некоторые службы защищены от Set-Service — пробуем напрямую через реестр
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value 4 -ErrorAction Stop
            Report OK "$label — отключена (через реестр)"
        } catch {
            Report FAIL "$label — не удалось отключить" 'служба защищена системой'
        }
    }
}

# ---------------------------------------------------------------------------
#  Проверка прав администратора
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    # Перезапускаем себя от имени администратора
    $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($PrepareOffline) { $elevArgs += '-PrepareOffline' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $elevArgs
    } catch {
        Write-Host 'Нужны права администратора: в окне Windows нажмите «Да».' -ForegroundColor Red
        Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null
    }
    exit
}

$os = Get-CimInstance Win32_OperatingSystem
$IsWin11 = [int]$os.BuildNumber -ge 22000

# ---------------------------------------------------------------------------
#  СБОРКА ОФЛАЙН-ПАПКИ (кнопка «Собрать офлайн-папку» в стартовом окне)
#  Запускается один раз на ПК с интернетом. Скачивает в папку offline\ всё,
#  что нужно, чтобы потом «Настройка Windows.bat» работала без интернета.
# ---------------------------------------------------------------------------
if ($PrepareOffline) {
    foreach ($l in @(
        ''
        '  ############################################################  '
        '  #     СБОРКА ОФЛАЙН-УСТАНОВЩИКА                            #  '
        '  #     Скачиваются программы, Office и драйверы (6-8 ГБ).   #  '
        '  #     Нужен интернет. Не закрывайте это окно.              #  '
        '  ############################################################  '
        ''
    )) { Write-Host $l -ForegroundColor Black -BackgroundColor Yellow }
    try { $Host.UI.RawUI.WindowTitle = 'Сборка офлайн-установщика — не закрывайте окно' } catch {}
    if (-not ('SleepBlock' -as [type])) {
        Add-Type -Namespace '' -Name 'SleepBlock' -MemberDefinition `
            '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    }
    try { [void][SleepBlock]::SetThreadExecutionState([uint32]2147483651) } catch {}
    try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}
    $TotalSteps = 4
    Write-Host "Папка: $OfflineDir"
    if ($OfflineDir -match '[^\x00-\x7F]') {
        Report WARN 'В пути к папке есть русские буквы' 'установщик Office может с этим не справиться — лучше положить папку, например, в D:\WinSetup'
    }
    New-Item -ItemType Directory -Path $OfflineDir -Force | Out-Null

    # --- 1. Программы ---
    Write-Step 'Программы'
    if (-not (Ensure-Winget)) {
        Report FAIL 'winget недоступен — программы не скачаны' 'обновите «Установщик приложений» в Microsoft Store'
    } else {
        # winget download появился в версии 1.8
        $ver = "$(Invoke-Winget --version | Select-Object -First 1)" -replace '[^\d.]', ''
        $vp  = @($ver -split '\.' | Where-Object { $_ }) + @('0', '0', '0')
        $wv  = try { [version]('{0}.{1}.{2}' -f $vp[0], $vp[1], $vp[2]) } catch { [version]'0.0.0' }
        if ($wv -lt [version]'1.8.0') {
            Report FAIL "winget $ver слишком старый — нужен 1.8 или новее" 'обновите «Установщик приложений» в Microsoft Store'
        } else {
            $all = @($Apps) + @($TestTools | Where-Object { $_.Id -notin $Apps.Id })
            foreach ($app in $all) {
                $dir = Join-Path $OfflineDir ('apps\' + ($app.Id -replace '[^\w.+-]', '_'))
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $a = @('download', '--id', $app.Id, '-e', '--source', 'winget', '-d', "`"$dir`"",
                       '--accept-package-agreements', '--accept-source-agreements')
                if ($OfflineInstallerType[$app.Id]) { $a += @('--installer-type', $OfflineInstallerType[$app.Id]) }
                $log = Join-Path $env:TEMP ('dl-' + ($app.Id -replace '[^\w.-]', '_') + '.log')
                $code = Wait-Task (Start-ProcessTask $app.Name "$($app.Name) — скачивается" $script:WingetExe $a $log)
                Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '\w' } | ForEach-Object { Write-Log "    $_" }
                $pkg = Get-OfflinePackage $app.Id
                if ($code -eq 0 -and $pkg) {
                    Report OK ("$($app.Name) — скачан ({0:N0} МБ)" -f ((Get-Item $pkg.File).Length / 1MB))
                } else {
                    Report FAIL "$($app.Name) — не скачан" ("код 0x{0:X8}, подробности в логе" -f $code)
                }
            }
        }
    }

    # --- 2. Office ---
    Write-Step 'Microsoft Office'
    if ($DoInstallOffice) {
        try {
            $officeDir = Join-Path $OfflineDir 'office'
            New-Item -ItemType Directory -Path $officeDir -Force | Out-Null
            $odt = Join-Path $officeDir 'setup.exe'
            Wait-Task (Start-ScriptTask 'Office' 'Microsoft Office: скачиваю установщик' {
                param($Out) Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $Out -UseBasicParsing
            } @($odt)) | Out-Null
            $cfg = Join-Path $env:TEMP 'office-download.xml'
            Set-Content -Path $cfg -Value (Get-OfficeConfig $officeDir -ForDownload) -Encoding UTF8
            $t = Start-ProcessTask 'Office' "Microsoft Office ($OfficeLanguage): скачивается дистрибутив, 3–4 ГБ" $odt @('/download', "`"$cfg`"")
            $t.WatchFile = $officeDir
            $code = Wait-Task $t
            if ($code -eq 0 -and (Test-Path (Join-Path $officeDir 'Office\Data'))) { Report OK "Microsoft Office — скачан ($OfficeProduct, $OfficeLanguage)" }
            else { Report FAIL 'Microsoft Office — не скачан' "код $code" }
        } catch { Report FAIL 'Microsoft Office — не скачан' $_ }
    } else { Report SKIP 'Office выключен в настройках ($DoInstallOffice)' }

    # --- 3. Драйверы этого ПК (встроенный экспорт Windows) ---
    Write-Step 'Драйверы этого компьютера'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $pcName = ("$($cs.Manufacturer) $($cs.Model)" -replace '[^\w.-]+', '_').Trim('_')
        $drvDir = Join-Path $OfflineDir "drivers\$pcName"
        Remove-Item $drvDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
        # Только базовые драйверы: сеть (проводная и Wi-Fi), Bluetooth, чипсет, контроллеры дисков и USB.
        # Видео и звук не берём: они тяжёлые, а видео ставится отдельно с сайта производителя.
        $n = Wait-Task (Start-ScriptTask 'драйверы' "Выгружаю базовые драйверы этого ПК ($($cs.Manufacturer) $($cs.Model))" {
            param($To, $Classes)
            $count = 0
            foreach ($d in Get-WindowsDriver -Online | Where-Object { $_.ClassName -in $Classes }) {
                $sub = Join-Path $To ([IO.Path]::GetFileNameWithoutExtension($d.Driver))
                & "$env:SystemRoot\System32\pnputil.exe" /export-driver $d.Driver $sub 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $count++ }
            }
            $count
        } @($drvDir, $BaseDriverClasses)) | Select-Object -Last 1
        $mb = (Get-ChildItem $drvDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
        Report OK ("Базовые драйверы этого ПК выгружены: $n шт., {0:N0} МБ" -f $mb) "папка drivers\$pcName"
    } catch { Report FAIL 'Драйверы этого ПК не выгружены' $_ }

    # --- 4. Драйвер видеокарты NVIDIA (общий для GeForce) ---
    Write-Step 'Драйверы видеокарт'
    try {
        $nvDir = Join-Path $OfflineDir 'gpu\nvidia'
        New-Item -ItemType Directory -Path $nvDir -Force | Out-Null
        $nvExe = Join-Path $nvDir 'nvidia-driver.exe'
        $nvGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' } | Select-Object -First 1
        $nvName = if ($nvGpu) { $nvGpu.Name } else { 'GeForce' }
        $r = Wait-Task (Start-ScriptTask 'NVIDIA' 'Драйвер NVIDIA: ищу последнюю версию' $NvidiaDownloadScript @($nvName, '', $nvExe) $nvExe) | Select-Object -Last 1
        Set-Content -Path (Join-Path $nvDir 'version.txt') -Value $r.Latest
        Report OK "Драйвер NVIDIA $($r.Latest) скачан" 'подходит для видеокарт GeForce'
    } catch { Report FAIL 'Драйвер NVIDIA не скачан' $_ }
    $amdDir = Join-Path $OfflineDir 'gpu\amd'
    New-Item -ItemType Directory -Path $amdDir -Force | Out-Null
    if (Get-ChildItem $amdDir -Filter '*.exe' -ErrorAction SilentlyContinue) {
        Report OK 'Драйвер AMD — уже лежит в папке gpu\amd'
    } else {
        Report WARN 'Драйвер AMD не скачивается автоматически' 'если нужен: скачайте полный пакет Adrenalin с amd.com и положите в offline\gpu\amd'
    }

    # --- Итог сборки ---
    $size = (Get-ChildItem $OfflineDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
    Set-Content -Path $OfflineInfo -Encoding UTF8 -Value @(
        "Офлайн-установщик собран: $(Get-Date -Format 'dd.MM.yyyy HH:mm')"
        "На компьютере: $env:COMPUTERNAME"
        ('Размер: {0:N1} ГБ' -f $size)
    )
    $fail = @($Results | Where-Object Status -eq 'FAIL')
    Write-Step 'ИТОГ'
    try { [void][SleepBlock]::SetThreadExecutionState([uint32]2147483648) } catch {}
    Write-Host ('Офлайн-папка готова: {0} ({1:N1} ГБ)' -f $OfflineDir, $size) -ForegroundColor Green
    Write-Host 'Теперь скопируйте всю папку windows-setup (вместе с system\offline) на флешку или сервер.'
    Write-Host '«Настройка Windows.bat» увидит папку offline и будет ставить всё без интернета.'
    if ($fail.Count) {
        Write-Host ''
        Write-Host 'Не получилось:' -ForegroundColor Red
        foreach ($r in $fail) { Write-Host " - $($r.Text)  ($($r.Details))" -ForegroundColor Red }
    }
    Write-Host "Подробный лог: $LogFile"
    Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null
    exit 0
}


# ---------------------------------------------------------------------------
#  Стартовое окно: выбор стресс-теста, кнопка «Старт», подтверждение
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# Скрытие/показ окна консоли (для настройки «показывать консоль»)
if (-not ('ConHelper' -as [type])) {
    Add-Type -Namespace '' -Name 'ConHelper' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
}
# Прячем консоль сразу, чтобы она не торчала за окном программы (вернём после диалога, если попросят)
try { [void][ConHelper]::ShowWindow([ConHelper]::GetConsoleWindow(), 0) } catch {}

# -------- Тема (светлая / тёмная) --------
function Get-Theme([string]$Name) {
    if ($Name -eq 'dark') {
        @{ Bg=[Drawing.Color]::FromArgb(30,31,34);  Panel=[Drawing.Color]::FromArgb(42,43,47)
           Fg=[Drawing.Color]::FromArgb(230,230,230); SubFg=[Drawing.Color]::FromArgb(160,160,160)
           Accent=[Drawing.Color]::FromArgb(79,140,255); AccentFg=[Drawing.Color]::White
           TileOff=[Drawing.Color]::FromArgb(52,54,59); Border=[Drawing.Color]::FromArgb(70,72,80)
           TileHover=[Drawing.Color]::FromArgb(64,66,72); AccentHover=[Drawing.Color]::FromArgb(105,160,255)
           Danger=[Drawing.Color]::FromArgb(255,107,107) }
    } else {
        @{ Bg=[Drawing.Color]::FromArgb(243,243,243); Panel=[Drawing.Color]::White
           Fg=[Drawing.Color]::FromArgb(27,27,27); SubFg=[Drawing.Color]::FromArgb(110,110,110)
           Accent=[Drawing.Color]::FromArgb(37,99,235); AccentFg=[Drawing.Color]::White
           TileOff=[Drawing.Color]::FromArgb(233,233,236); Border=[Drawing.Color]::FromArgb(210,210,214)
           TileHover=[Drawing.Color]::FromArgb(221,221,228); AccentHover=[Drawing.Color]::FromArgb(29,78,216)
           Danger=[Drawing.Color]::FromArgb(192,57,43) }
    }
}
$script:ThemeName = if ($UiTheme -eq 'dark') { 'dark' } else { 'light' }
$script:Theme     = Get-Theme $script:ThemeName
$script:tiles     = @()

# Опции оптимизации: рабочая копия значений по умолчанию (меняются на вкладке «Оптимизация»)
$OptOptions = [ordered]@{}
foreach ($k in $OptDefaults.Keys) { $OptOptions[$k] = $OptDefaults[$k] }

function Set-CtlTheme($parent, $t) {
    foreach ($c in $parent.Controls) {
        switch ($c.GetType().Name) {
            'Label'      { $c.BackColor=[Drawing.Color]::Transparent
                           $c.ForeColor = if ($c.Tag -eq 'danger') { $t.Danger } elseif ($c.Tag -eq 'sub') { $t.SubFg } else { $t.Fg } }
            'LinkLabel'  { $c.BackColor=[Drawing.Color]::Transparent; $c.LinkColor=$t.Accent; $c.ActiveLinkColor=$t.Accent; $c.ForeColor=$t.SubFg }
            'CheckBox'   { $c.BackColor=[Drawing.Color]::Transparent
                           $c.ForeColor = if ($c.Tag -eq 'danger') { $t.Danger } else { $t.Fg } }
            'TextBox'    { $c.BackColor=$t.Panel; $c.ForeColor=$t.Fg }
            'TabPage'    { $c.BackColor=$t.Panel }
            'TabControl' { $c.BackColor=$t.Bg }
            'Panel'      { $c.BackColor=$t.Panel }
            'GroupBox'   { $c.BackColor=[Drawing.Color]::Transparent; $c.ForeColor=$t.Fg }
            default      { }
        }
        if ($c.Controls.Count) { Set-CtlTheme $c $t }
    }
}
function Highlight-Tiles($t) {
    foreach ($b in $script:tiles) {
        if ("$($b.Tag)" -eq $script:SelMode) {
            $b.BackColor=$t.Accent; $b.ForeColor=$t.AccentFg; $b.FlatAppearance.BorderColor=$t.Accent; $b.FlatAppearance.BorderSize=2
            $b.FlatAppearance.MouseOverBackColor=$t.AccentHover; $b.FlatAppearance.MouseDownBackColor=$t.Accent
        } else {
            $b.BackColor=$t.TileOff; $b.ForeColor=$t.Fg; $b.FlatAppearance.BorderColor=$t.Border; $b.FlatAppearance.BorderSize=1
            $b.FlatAppearance.MouseOverBackColor=$t.TileHover; $b.FlatAppearance.MouseDownBackColor=$t.Border
        }
    }
}
function Apply-Theme {
    $t = $script:Theme
    $form.BackColor = $t.Bg
    Set-CtlTheme $form $t
    Highlight-Tiles $t
    $btnTheme.BackColor=$t.TileOff; $btnTheme.ForeColor=$t.Fg; $btnTheme.FlatAppearance.BorderColor=$t.Border; $btnTheme.FlatAppearance.MouseOverBackColor=$t.TileHover
    $btnStart.BackColor=$t.Accent;  $btnStart.ForeColor=$t.AccentFg; $btnStart.FlatAppearance.BorderColor=$t.Accent; $btnStart.FlatAppearance.MouseOverBackColor=$t.AccentHover
    if ($btnTransfer) { $btnTransfer.BackColor=$t.TileOff; $btnTransfer.ForeColor=$t.Fg; $btnTransfer.FlatAppearance.BorderColor=$t.Border; $btnTransfer.FlatAppearance.MouseOverBackColor=$t.TileHover }
}

# -------- Окно --------
$form = New-Object Windows.Forms.Form
$form.Text            = 'WinUP'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.TopMost         = $true
$form.Font            = New-Object Drawing.Font('Segoe UI', 10)
$form.ClientSize      = New-Object Drawing.Size(640, 600)
try {
    $iconPath = Join-Path $PSScriptRoot 'icon.ico'
    if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
} catch {}

# Заголовок
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text='Ваша версия ОС'; $lblTitle.AutoSize=$true; $lblTitle.Location=New-Object Drawing.Point(16,14)
$lblTitle.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Text="$($os.Caption) (сборка $($os.BuildNumber))"; $lblSub.Tag='sub'; $lblSub.AutoSize=$true
$lblSub.Location=New-Object Drawing.Point(18,46)
$form.Controls.Add($lblSub)

# Кнопка переключения темы (справа вверху)
$btnTheme = New-Object Windows.Forms.Button
$btnTheme.Text = if ($script:ThemeName -eq 'dark') { '☼ Светлая тема' } else { '☾ Тёмная тема' }
$btnTheme.Size=New-Object Drawing.Size(140,32); $btnTheme.Location=New-Object Drawing.Point(504,16)
$btnTheme.FlatStyle='Flat'; $btnTheme.FlatAppearance.BorderSize=1; $btnTheme.Cursor='Hand'
$form.Controls.Add($btnTheme)
$btnTheme.Add_Click({
    $script:ThemeName = if ($script:ThemeName -eq 'dark') { 'light' } else { 'dark' }
    $script:Theme = Get-Theme $script:ThemeName
    $btnTheme.Text = if ($script:ThemeName -eq 'dark') { '☼ Светлая тема' } else { '☾ Тёмная тема' }
    Apply-Theme
})

# Предупреждения (офлайн / не Windows 11)
$noteY = 72
if ($Offline) {
    $l = New-Object Windows.Forms.Label; $l.Tag='sub'; $l.AutoSize=$true; $l.MaximumSize=New-Object Drawing.Size(600,0)
    $l.Text = 'Режим БЕЗ ИНТЕРНЕТА — всё ставится из папки offline. ' + ((Get-Content $OfflineInfo -Encoding UTF8 | Select-Object -First 1))
    $l.Location=New-Object Drawing.Point(18,$noteY); $form.Controls.Add($l); $noteY += $l.PreferredHeight + 4
}
if (-not $IsWin11) {
    $l = New-Object Windows.Forms.Label; $l.Tag='danger'; $l.AutoSize=$true; $l.MaximumSize=New-Object Drawing.Size(600,0)
    $l.Text = 'ВНИМАНИЕ: скрипт сделан под Windows 11. На другой системе часть шагов может не сработать — на свой страх и риск.'
    $l.Location=New-Object Drawing.Point(18,$noteY); $form.Controls.Add($l); $noteY += $l.PreferredHeight + 4
}

# -------- Вкладки --------
$tabs = New-Object Windows.Forms.TabControl
$tabs.Location=New-Object Drawing.Point(12,($noteY+6)); $tabs.Size=New-Object Drawing.Size(616,430)
$form.Controls.Add($tabs)
$tabRun = New-Object Windows.Forms.TabPage; $tabRun.Text='Запуск'
$tabOpt = New-Object Windows.Forms.TabPage; $tabOpt.Text='Оптимизация'
$tabPrev= New-Object Windows.Forms.TabPage; $tabPrev.Text='Выбранное'
$tabs.TabPages.AddRange(@($tabRun,$tabOpt,$tabPrev))

# ---- Вкладка «Запуск» ----
$lblMode = New-Object Windows.Forms.Label; $lblMode.Text='Режим:'; $lblMode.AutoSize=$true
$lblMode.Location=New-Object Drawing.Point(14,12); $lblMode.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
$tabRun.Controls.Add($lblMode)

$modeDefs = @(
    @{ Key='all';      Title='Всё';               Desc='Настройка, программы, драйверы' }
    @{ Key='apps';     Title='Программы';          Desc='Только программы и Office' }
    @{ Key='optimize'; Title='Оптимизация';        Desc='Место, скорость, мусор' }
    @{ Key='stress';   Title='Стресс-тест';        Desc='Проверка железа, ничего не меняет' }
)
$script:SelMode = 'all'
$tx=14; $ty=38; $i=0
foreach ($m in $modeDefs) {
    $b = New-Object Windows.Forms.Button
    $b.Text = "$($m.Title)`n$($m.Desc)"; $b.Tag=$m.Key
    $b.Size=New-Object Drawing.Size(285,52)
    $col = $i % 2; $row = [math]::Floor($i/2)   # [int](3/2) в PowerShell даёт 2, не 1 — поэтому Floor
    $b.Location=New-Object Drawing.Point(($tx+$col*295),($ty+$row*60))
    $b.FlatStyle='Flat'; $b.TextAlign='MiddleLeft'; $b.Cursor='Hand'; $b.Padding=New-Object Windows.Forms.Padding(8,0,0,0)
    $b.Add_Click({ $script:SelMode = "$($this.Tag)"; Update-Checks; Highlight-Tiles $script:Theme; Update-Preview })
    $tabRun.Controls.Add($b); $script:tiles += $b; $i++
}

$optY = $ty + 2*60 + 14
function Add-RunCheck([string]$Text,[int]$X,[bool]$Checked) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text=$Text; $c.AutoSize=$true
    $c.Location=New-Object Drawing.Point($X,$script:optY); $c.Checked=$Checked
    $tabRun.Controls.Add($c); $script:optY += $c.PreferredSize.Height + 4; return $c
}
$chk          = Add-RunCheck 'Со стресс-тестом (проверка железа и оценка для игр)' 14 $StressTestDefault
$chkRemove    = Add-RunCheck 'Удалить программы для тестов после (FurMark и др.)' 34 $RemoveTestToolsDefault
$script:optY += 4
$chkOptimize  = Add-RunCheck 'Оптимизация и очистка (освободить место, ускорить)' 14 $DoOptimize
$chkReinstall = Add-RunCheck 'Переустановить уже установленные программы' 14 $ReinstallDefault
$chkClient    = Add-RunCheck 'Подготовить для передачи другому человеку' 14 $ClientModeDefault
$script:optY += 4
$chkConsole   = Add-RunCheck 'Показывать окно консоли (подробный лог) во время работы' 14 $ShowConsole

# ---- Вкладка «Оптимизация» ----
$optLbl = New-Object Windows.Forms.Label; $optLbl.AutoSize=$true; $optLbl.MaximumSize=New-Object Drawing.Size(590,0); $optLbl.Tag='sub'
$optLbl.Text='Базовая очистка и безопасные настройки выполняются всегда. Ниже — дополнительные опции (по умолчанию выключены).'
$optLbl.Location=New-Object Drawing.Point(14,12); $tabOpt.Controls.Add($optLbl)

$optDefsUI = @(
    @{ Key='BrowserCache';    Text='Очистить кэши браузеров (пароли и закладки не трогаются)' }
    @{ Key='OldDrivers';      Text='Удалить старые версии драйверов (активные оставить)' }
    @{ Key='Hibernate';       Text='Отключить гибернацию и удалить hiberfil.sys (только десктоп)' }
    @{ Key='ReservedStorage'; Text='Отключить «Зарезервированное хранилище» (~7 ГБ)' }
    @{ Key='OneDriveRemove';  Text='Удалить OneDrive полностью' }
    @{ Key='ExtraServices';   Text='Отключить доп. службы (SysMain, кошелёк, биометрия, смарт-карты)' }
    @{ Key='VisualEffects';   Text='Визуальные эффекты — на производительность' }
    @{ Key='SfcDism';         Text='Проверка и починка системных файлов (SFC + DISM, +5–15 мин)' }
    @{ Key='PrivacyHandover'; Text='Очистить историю (недавние, «Выполнить», буфер) — для передачи ПК' }
)
$script:optChecks = @{}
$oy = 12 + $optLbl.PreferredHeight + 12   # под фактической высотой (многострочного) заголовка
foreach ($o in $optDefsUI) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text=$o.Text; $c.AutoSize=$true
    $c.Location=New-Object Drawing.Point(16,$oy); $c.Checked=[bool]$OptDefaults[$o.Key]
    $c.Add_CheckedChanged({ Update-Preview })
    $tabOpt.Controls.Add($c); $script:optChecks[$o.Key]=$c; $oy += $c.PreferredSize.Height + 6
}
$oy += 6
$chkReset = New-Object Windows.Forms.CheckBox; $chkReset.Tag='danger'; $chkReset.AutoSize=$true
$chkReset.Text='⚠ Предельное сжатие WinSxS (ResetBase) — НЕОБРАТИМО: нельзя будет удалить обновления'
$chkReset.MaximumSize=New-Object Drawing.Size(590,0)
$chkReset.Location=New-Object Drawing.Point(16,$oy); $chkReset.Checked=[bool]$OptDefaults['ResetBase']
$chkReset.Add_CheckedChanged({ Update-Preview })
$tabOpt.Controls.Add($chkReset); $script:optChecks['ResetBase']=$chkReset

# ---- Вкладка «Что будет» ----
$prev = New-Object Windows.Forms.TextBox
$prev.Multiline=$true; $prev.ReadOnly=$true; $prev.ScrollBars='Vertical'; $prev.WordWrap=$true
$prev.BorderStyle='None'; $prev.Location=New-Object Drawing.Point(10,10); $prev.Size=New-Object Drawing.Size(588,400)
$tabPrev.Controls.Add($prev)

# -------- Кнопка СТАРТ и ссылка «офлайн» --------
$btnStart = New-Object Windows.Forms.Button
$btnStart.Text='СТАРТ'; $btnStart.Size=New-Object Drawing.Size(180,44)
$btnStart.Location=New-Object Drawing.Point(444,($tabs.Bottom+12))
$btnStart.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
$btnStart.FlatStyle='Flat'; $btnStart.FlatAppearance.BorderSize=0; $btnStart.Cursor='Hand'
$form.Controls.Add($btnStart); $form.AcceptButton=$btnStart

$lnk = New-Object Windows.Forms.LinkLabel
$lnk.Text='Собрать офлайн-папку (для установки без интернета)...'; $lnk.AutoSize=$true
$lnk.Location=New-Object Drawing.Point(16,($tabs.Bottom+62)); $form.Controls.Add($lnk)
$lnk.Add_LinkClicked({
    $m = "Будут скачаны программы, Office, FurMark, датчики температуры, драйвер NVIDIA и выгружены базовые драйверы этого ПК в папку:`n$OfflineDir`n`nНужен интернет, займёт 6–8 ГБ и 20–60 минут.`n`nНачать?"
    if ([Windows.Forms.MessageBox]::Show($form, $m, 'Офлайн-папка', 'OKCancel', 'Question') -eq 'OK') { $form.Tag='offline'; $form.Close() }
})

# Кнопка «Перенос данных» (слева) — открывает отдельный инструмент (data-transfer.ps1).
# Главное окно НЕ закрываем: после закрытия переноса оно остаётся на экране.
$btnTransfer = New-Object Windows.Forms.Button
$btnTransfer.Text='Перенос данных'; $btnTransfer.Size=New-Object Drawing.Size(180,44)
$btnTransfer.Location=New-Object Drawing.Point(20,($tabs.Bottom+12))
$btnTransfer.FlatStyle='Flat'; $btnTransfer.FlatAppearance.BorderSize=1; $btnTransfer.Cursor='Hand'
$btnTransfer.TextImageRelation='ImageBeforeText'; $btnTransfer.ImageAlign='MiddleLeft'; $btnTransfer.TextAlign='MiddleCenter'
try {
    $dbimg = Join-Path $PSScriptRoot 'icon-db.png'
    if (Test-Path $dbimg) {
        $src = New-Object System.Drawing.Bitmap($dbimg)
        $bmp = New-Object System.Drawing.Bitmap(22, 22)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
        $g.DrawImage($src, 0, 0, 22, 22); $g.Dispose()
        $btnTransfer.Image = $bmp
    }
} catch {}
$form.Controls.Add($btnTransfer)
$btnTransfer.Add_Click({
    $dt = Join-Path $PSScriptRoot 'data-transfer.ps1'
    if (-not (Test-Path $dt)) { [Windows.Forms.MessageBox]::Show($form, "Не найден файл переноса данных:`n$dt", 'Перенос данных', 'OK', 'Error') | Out-Null; return }
    # Прячем главное окно, запускаем перенос скрыто и ждём; когда перенос закроют — показываем окно снова
    $form.Hide()
    try { Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$dt`"" -Wait } catch {}
    $form.Show(); $form.Activate()
})

$form.ClientSize = New-Object Drawing.Size(640, ($tabs.Bottom+108))

# -------- Логика --------
# Какие шаги включены в выбранном режиме (с учётом настроек $Do... в начале файла)
function Get-ModeFlags([string]$Mode, [bool]$Stress) {
    $f = [ordered]@{
        RestorePoint = $DoRestorePoint;  DisableDefender = $DoDisableDefender; DisableServices = $DoDisableServices
        RemoveBloat  = $DoRemoveBloat;   InstallApps     = $DoInstallApps;     InstallOffice   = $DoInstallOffice
        UpdateDrivers = $DoUpdateDrivers; GpuDriver      = $DoGpuDriver;       MaxDisplay      = $DoMaxDisplay
        DisableUpdates = $DoDisableUpdates; StressTest   = $Stress
        GameTweaks = $DoGameTweaks; ComfortTweaks = $DoComfortTweaks; PowerPlan = $DoPowerPlan
        Region = $DoRegion; DefaultApps = $DoDefaultApps; OneDriveEdge = $DoOneDriveEdge; DisableAI = $DoDisableAI
        StartupCleanup = $DoStartupCleanup; Cleanup = $DoCleanup; Optimize = $DoOptimize
    }
    if ($Mode -eq 'apps') {
        foreach ($k in @($f.Keys)) { if ($k -notin 'StressTest', 'InstallApps', 'InstallOffice', 'DefaultApps') { $f[$k] = $false } }
    }
    elseif ($Mode -eq 'stress') {
        foreach ($k in @($f.Keys)) { if ($k -ne 'StressTest') { $f[$k] = $false } }
        $f.StressTest = $true
    }
    elseif ($Mode -eq 'optimize') {
        foreach ($k in @($f.Keys)) { if ($k -notin 'Optimize', 'DisableServices', 'RemoveBloat', 'StartupCleanup', 'Cleanup') { $f[$k] = $false } }
        $f.Optimize = $true; $f.StartupCleanup = $true; $f.Cleanup = $true
    }
    if (-not $f.Optimize) { $f.StartupCleanup = $false; $f.Cleanup = $false }
    return $f
}
function Get-SelectedMode { return $script:SelMode }

# Переносит отмеченные доп-опции в $OptOptions
function Sync-OptOptions {
    foreach ($k in @($OptOptions.Keys)) { if ($script:optChecks.ContainsKey($k)) { $OptOptions[$k] = [bool]$script:optChecks[$k].Checked } }
}

# Доступность галочек в зависимости от режима
function Update-Checks {
    $isStress   = $script:SelMode -eq 'stress'
    $isOptimize = $script:SelMode -eq 'optimize'
    $isAll      = $script:SelMode -eq 'all'
    $isApps     = $script:SelMode -eq 'apps'
    if ($isStress) { $chk.Checked = $true; $chk.Enabled = $false }
    else { if ($isOptimize) { $chk.Checked = $false }; $chk.Enabled = -not $isOptimize }
    # Доступна только при стресс-тесте; когда стресс выключен — возвращаем значение по умолчанию
    if ($chk.Checked) { $chkRemove.Enabled = $true }
    else { $chkRemove.Enabled = $false; $chkRemove.Checked = $RemoveTestToolsDefault }
    if ($isOptimize) { $chkOptimize.Checked = $true; $chkOptimize.Enabled = $false }
    else { $chkOptimize.Enabled = $isAll; if (-not $isAll) { $chkOptimize.Checked = $false } }
    $chkReinstall.Enabled = $isAll -or $isApps
    $chkClient.Enabled    = $isAll -or $isApps
}

# Список того, что будет сделано (для вкладки «Что будет» и окна подтверждения)
function Get-StepList {
    Sync-OptOptions
    $mode = $script:SelMode
    $f = Get-ModeFlags $mode $chk.Checked
    $steps = @()
    if ($DoSystemCheck) { $steps += '• Проверка системы: память (XMP), диски, активация, UEFI / TPM' }
    if ($f.RestorePoint)    { $steps += '• Точка восстановления (чтобы можно было откатить)' }
    if ($f.DisableDefender) { $steps += '• Отключение Защитника, SmartScreen и запросов UAC' }
    if ($f.DisableServices) { $steps += '• Отключение ненужных служб, телеметрии и рекламы' }
    if ($f.RemoveBloat)     { $steps += '• Удаление встроенного мусора (Clipchamp, Новости, Teams...)' }
    if ($f.InstallApps)     { $steps += '• Установка программ: ' + (($Apps | ForEach-Object { ($_.Name -split ' \(')[0] }) -join ', ') }
    if ($f.InstallOffice)   { $steps += '• Установка Microsoft Office: ' + ($OfficeApps -join ', ') }
    if ($f.UpdateDrivers)   { $steps += '• Обновление драйверов через Центр обновления' }
    if ($f.GpuDriver)       { $steps += '• Драйвер видеокарты с сайта NVIDIA / AMD / Intel' }
    if ($f.MaxDisplay)      { $steps += '• Максимальное разрешение и частота экрана' }
    if ($f.Region)          { $steps += "• Регион и время: часовой пояс, синхронизация, раскладки ($LayoutHotkey)" }
    if ($f.GameTweaks)      { $steps += '• Игровые настройки: игровой режим, планирование GPU, без Game DVR и ускорения мыши' }
    if ($f.ComfortTweaks)   { $steps += '• Удобство: меню как в Windows 10, расширения файлов, без рекламы в «Пуск», тёмная тема' }
    if ($f.PowerPlan)       { $steps += '• Электропитание: высокая производительность, без гибернации (ноутбук — сбалансированная)' }
    if ($f.OneDriveEdge)    { $steps += '• OneDrive и Edge: без автозапуска и навязчивых окон' }
    if ($f.DisableAI)       { $steps += '• Отключение ИИ-функций: Recall, Click to Do, ИИ в Paint и Блокноте' }
    if ($f.DefaultApps)     { $steps += '• Программы по умолчанию: ' + (($DefaultApps | ForEach-Object { $_.Name }) -join ', ') }
    if ($f.DisableUpdates)  { $steps += '• Отключение автоматических обновлений Windows' }
    if ($f.Optimize) {
        $steps += '• Очистка: временные файлы, кэш обновлений, логи, дампы, корзина, остатки обновлений ОС'
        $steps += '• Сеть: сброс кэша DNS, снятие мультимедийного троттлинга' + $(if (-not (Test-IsLaptop)) { ', сетевая карта не засыпает' } else { '' })
        $steps += '• Ускорение: фоновые приложения выкл., задержка автозагрузки убрана, Storage Sense вкл.'
        $extra = @()
        if ($OptOptions.BrowserCache)    { $extra += 'кэши браузеров' }
        if ($OptOptions.OldDrivers)      { $extra += 'старые драйверы' }
        if ($OptOptions.Hibernate)       { $extra += 'гибернация выкл.' }
        if ($OptOptions.ReservedStorage) { $extra += 'зарезервированное хранилище выкл.' }
        if ($OptOptions.OneDriveRemove)  { $extra += 'удалить OneDrive' }
        if ($OptOptions.ExtraServices)   { $extra += 'доп. службы' }
        if ($OptOptions.VisualEffects)   { $extra += 'эффекты на производительность' }
        if ($OptOptions.SfcDism)         { $extra += 'проверка и починка системных файлов' }
        if ($OptOptions.PrivacyHandover) { $extra += 'очистка истории' }
        if ($extra) { $steps += '• Дополнительно: ' + ($extra -join ', ') }
        if ($OptOptions.ResetBase) { $steps += '• ⚠ ПРЕДЕЛЬНОЕ сжатие WinSxS (ResetBase) — НЕОБРАТИМО: нельзя удалить обновления' }
    }
    if ($DoPassport) { $steps += '• Паспорт ПК на рабочем столе' }
    if ($chkClient.Enabled -and $chkClient.Checked) { $steps += '• Подготовка к передаче: после перезагрузки и входа ПК выключится, новый владелец сам создаст учётную запись' }
    return $steps
}

function Update-Preview {
    $steps = Get-StepList
    $prev.Text = "Сейчас произойдёт:`r`n`r`n" + ($steps -join "`r`n")
}

foreach ($b in $script:tiles) { } # плитки уже с обработчиками
$chk.Add_CheckedChanged({ Update-Checks; Update-Preview })
$chkOptimize.Add_CheckedChanged({ Update-Preview })
$chkClient.Add_CheckedChanged({ Update-Preview })

$btnStart.Add_Click({
    $steps = Get-StepList
    $mode  = $script:SelMode
    $warn = @('ВО ВРЕМЯ РАБОТЫ НЕ ПЕРЕЗАГРУЖАЙТЕ И НЕ ВЫКЛЮЧАЙТЕ КОМПЬЮТЕР.')
    switch ($mode) {
        'all'      { $warn += 'Обычно это занимает 20–60 минут. Нужен интернет.'; $warn += 'После настройки компьютер останется без антивируса и обновлений Windows.' }
        'apps'     { $warn += 'Обычно это занимает 10–30 минут. Нужен интернет.' }
        'stress'   { $warn += 'Это займёт около 10–15 минут. Нужен интернет, чтобы скачать тесты.' }
        'optimize' { $warn += 'Обычно это занимает 3–10 минут. Интернет не обязателен.'; if ($OptOptions.SfcDism) { $warn += 'Проверка системных файлов добавит ещё 5–15 минут.' } }
    }
    if ($chk.Checked -and ($mode -eq 'all' -or $mode -eq 'apps' -or $mode -eq 'stress')) {
        $warn += 'Стресс-тест даёт полную нагрузку: компьютер будет греться и шуметь. Ноутбук подключите к зарядке.'
    }
    if ($Offline) { $warn = @($warn | ForEach-Object { $_ -replace ' Нужен интернет[^.]*\.', ' Интернет не нужен.' }) }
    if (-not $IsWin11) { $warn += "Это не Windows 11 ($($os.Caption)). Вы запускаете скрипт на свой страх и риск." }
    $msg = "Сейчас произойдёт:`n`n" + ($steps -join "`n") + "`n`nВажно:`n" + (($warn | ForEach-Object { "• $_" }) -join "`n") + "`n`nНажмите «ОК», чтобы начать, или «Отмена», чтобы ничего не делать."
    if ([Windows.Forms.MessageBox]::Show($form, $msg, 'Перед запуском', 'OKCancel', 'Warning') -eq [Windows.Forms.DialogResult]::OK) {
        $form.Tag='start'; $form.Close()
    }
})

Update-Checks
Update-Preview
Apply-Theme
[void]$form.ShowDialog()

if ($form.Tag -eq 'offline') {
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-PrepareOffline'
    exit 0
}
if ($form.Tag -ne 'start') {
    Write-Host 'Отменено. Ничего не изменено.' -ForegroundColor Yellow
    exit 0
}
Sync-OptOptions
$Mode  = $script:SelMode
$DoOptimize = $chkOptimize.Checked
$flags = Get-ModeFlags $Mode $chk.Checked
$script:Reinstall = $chkReinstall.Enabled -and $chkReinstall.Checked
$RemoveTestTools  = $chkRemove.Enabled -and $chkRemove.Checked
$ClientMode       = $chkClient.Enabled -and $chkClient.Checked
$ShowConsole      = $chkConsole.Checked
$form.Dispose()

# Консоль уже скрыта; показываем обратно только если пользователь попросил подробный лог (5 = SW_SHOW)
if ($ShowConsole) { try { [void][ConHelper]::ShowWindow([ConHelper]::GetConsoleWindow(), 5) } catch {} }

$DoRestorePoint    = $flags.RestorePoint
$DoDisableDefender = $flags.DisableDefender
$DoDisableServices = $flags.DisableServices
$DoRemoveBloat     = $flags.RemoveBloat
$DoInstallApps     = $flags.InstallApps
$DoInstallOffice   = $flags.InstallOffice
$DoUpdateDrivers   = $flags.UpdateDrivers
$DoGpuDriver       = $flags.GpuDriver
$DoMaxDisplay      = $flags.MaxDisplay
$DoDisableUpdates  = $flags.DisableUpdates
$DoStressTest      = $flags.StressTest
$DoGameTweaks      = $flags.GameTweaks
$DoComfortTweaks   = $flags.ComfortTweaks
$DoPowerPlan       = $flags.PowerPlan
$DoRegion          = $flags.Region
$DoDefaultApps     = $flags.DefaultApps
$DoOneDriveEdge    = $flags.OneDriveEdge
$DoDisableAI       = $flags.DisableAI
$DoStartupCleanup  = $flags.StartupCleanup
$DoCleanup         = $flags.Cleanup
$DoOptimize        = $flags.Optimize
# Сколько шагов будет (для заголовка окна «шаг N из M») — те же условия, что у самих шагов ниже.
# Рядом — примерный «вес» шага в минутах: по нему процент считается честно (Office и стресс-тест
# идут долго, поэтому весят больше, чем, например, настройка экрана).
$stepPlan = @(
    @{ On = ($DoRestorePoint -or $DoGpuDriver -or $DoInstallOffice); W = 2 }   # Подготовка + скачивания
    @{ On = $DoSystemCheck;                    W = 1 }
    @{ On = $DoDisableDefender;                 W = 1 }
    @{ On = $DoDisableServices;                 W = 1 }
    @{ On = $DoRemoveBloat;                     W = 1 }
    @{ On = $DoInstallApps;                     W = 8 }   # программы + Office (Office ~8 мин)
    @{ On = $DoUpdateDrivers;                   W = 3 }
    @{ On = $DoGpuDriver;                        W = 9 }   # драйвер видеокарты качается и ставится долго
    @{ On = $DoMaxDisplay;                       W = 1 }
    @{ On = $DoRegion;                           W = 1 }
    @{ On = ($DoGameTweaks -or $DoComfortTweaks); W = 1 }
    @{ On = ($DoOneDriveEdge -or $DoDisableAI);  W = 1 }
    @{ On = $DoDefaultApps;                       W = 1 }
    @{ On = $DoPowerPlan;                         W = 1 }
    @{ On = $DoDisableUpdates;                    W = 1 }
    @{ On = $DoStressTest;                        W = 9 }   # 7-Zip + FurMark + WinSAT
    @{ On = $DoOptimize;                          W = 2 }
    @{ On = $DoPassport;                          W = 1 }
    @{ On = $ClientMode;                          W = 1 }
)
$TotalSteps  = @($stepPlan | Where-Object { $_.On }).Count
$script:StepWeights = @($stepPlan | Where-Object { $_.On } | ForEach-Object { $_.W })
$script:TotalWeight = ($script:StepWeights | Measure-Object -Sum).Sum
$script:DoneWeight  = 0
if (-not $script:TotalWeight) { $script:TotalWeight = 1 }

# -------- Окно прогресса (живой отчёт вместо консоли) --------
$script:ProgForm = New-Object Windows.Forms.Form
$script:ProgForm.Text='WinUP — идёт работа'; $script:ProgForm.StartPosition='CenterScreen'
$script:ProgForm.FormBorderStyle='FixedDialog'; $script:ProgForm.MaximizeBox=$false; $script:ProgForm.MinimizeBox=$false; $script:ProgForm.ControlBox=$false
$script:ProgForm.TopMost=$true; $script:ProgForm.Font=New-Object Drawing.Font('Segoe UI',10); $script:ProgForm.ClientSize=New-Object Drawing.Size(560,470)
try { $ip=Join-Path $PSScriptRoot 'icon.ico'; if (Test-Path $ip) { $script:ProgForm.Icon=New-Object System.Drawing.Icon($ip) } } catch {}
$pgHead=New-Object Windows.Forms.Label; $pgHead.Text='Идёт настройка — не выключайте компьютер'; $pgHead.AutoSize=$true
$pgHead.Location=New-Object Drawing.Point(16,14); $pgHead.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold); $script:ProgForm.Controls.Add($pgHead)
$script:ProgStep=New-Object Windows.Forms.Label; $script:ProgStep.Text='Подготовка...'; $script:ProgStep.AutoSize=$true
$script:ProgStep.Location=New-Object Drawing.Point(16,44); $script:ProgForm.Controls.Add($script:ProgStep)
$script:ProgBar=New-Object Windows.Forms.ProgressBar; $script:ProgBar.Location=New-Object Drawing.Point(16,72); $script:ProgBar.Size=New-Object Drawing.Size(528,20)
$script:ProgBar.Minimum=0; $script:ProgBar.Maximum=100; $script:ProgForm.Controls.Add($script:ProgBar)
$script:ProgLog=New-Object Windows.Forms.TextBox; $script:ProgLog.Multiline=$true; $script:ProgLog.ReadOnly=$true; $script:ProgLog.ScrollBars='Vertical'
$script:ProgLog.BorderStyle='FixedSingle'; $script:ProgLog.Location=New-Object Drawing.Point(16,104); $script:ProgLog.Size=New-Object Drawing.Size(528,350)
$script:ProgLog.Font=New-Object Drawing.Font('Consolas',9); $script:ProgForm.Controls.Add($script:ProgLog)
$pt=$script:Theme; $script:ProgForm.BackColor=$pt.Bg; $pgHead.BackColor=[Drawing.Color]::Transparent; $pgHead.ForeColor=$pt.Fg
$script:ProgStep.BackColor=[Drawing.Color]::Transparent; $script:ProgStep.ForeColor=$pt.SubFg; $script:ProgLog.BackColor=$pt.Panel; $script:ProgLog.ForeColor=$pt.Fg
$script:ProgForm.Show(); [Windows.Forms.Application]::DoEvents()

# Режим передачи ПК: настройки пользователя будут записываться и в профиль по умолчанию
if ($ClientMode -and -not (Mount-DefaultUserHive)) { Write-Log 'Профиль по умолчанию не загружен' }

# Максимальный приоритет для скрипта (High; Realtime не используем — он может подвесить Windows)
try { (Get-Process -Id $PID).PriorityClass = 'High' } catch {}

# ---------------------------------------------------------------------------
#  Предупреждение и запрет сна на время работы
# ---------------------------------------------------------------------------
$banner = @(
    ''
    '  ############################################################  '
    '  #                                                          #  '
    '  #     НЕ ПЕРЕЗАГРУЖАЙТЕ И НЕ ВЫКЛЮЧАЙТЕ КОМПЬЮТЕР          #  '
    '  #     И НЕ ЗАКРЫВАЙТЕ ЭТО ОКНО                             #  '
    '  #                                                          #  '
    '  #     Идёт настройка, обычно это 20-60 минут.              #  '
    '  #     Экран может мигать — это нормально.                  #  '
    '  #     Крутящийся значок внизу = всё работает.              #  '
    '  #     Когда закончится, появится надпись ИТОГ.             #  '
    '  #                                                          #  '
    '  ############################################################  '
    ''
)
foreach ($l in $banner) { Write-Host $l -ForegroundColor Black -BackgroundColor Yellow }
try { $Host.UI.RawUI.WindowTitle = 'Настройка ПК — НЕ ВЫКЛЮЧАЙТЕ КОМПЬЮТЕР' } catch {}

# Чтобы компьютер не уснул и экран не погас посреди установки
if (-not ('SleepBlock' -as [type])) {
    Add-Type -Namespace '' -Name 'SleepBlock' -MemberDefinition `
        '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
}
# CONTINUOUS | SYSTEM_REQUIRED | DISPLAY_REQUIRED = 0x80000003. Пишем десятичным [uint32]:
# в PowerShell 5.1 литерал 0x80000003 — отрицательный Int32 и не проходит в функцию.
try { [void][SleepBlock]::SetThreadExecutionState([uint32]2147483651) } catch { Write-Log "Запрет сна: $($_.Exception.Message)" }

Write-Host "Система: $($os.Caption) (сборка $($os.BuildNumber))"
Write-Host "Лог:     $LogFile"
Write-Log  "Система: $($os.Caption) (сборка $($os.BuildNumber))"
if (-not $IsWin11) {
    Report WARN 'Это не Windows 11 — скрипт сделан под Windows 11' 'вы запустили его на свой страх и риск'
}
if ((Get-Process -Id $PID).PriorityClass -eq 'High') { Report OK 'Скрипту выставлен высокий приоритет' }

# ---------------------------------------------------------------------------
#  Синхронизация времени — в самом начале.
#  Если часы ПК врут, все метки в логе врут тоже (и SSL-запросы могут падать).
# ---------------------------------------------------------------------------
if (-not $Offline) {
    try {
        Set-Service w32time -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service w32time -ErrorAction SilentlyContinue
        Invoke-Quiet "$env:SystemRoot\System32\w32tm.exe" /resync /force | Out-Null
        if ($LASTEXITCODE -eq 0) { Report OK 'Часы синхронизированы с интернетом' 'сделано в начале, чтобы время в логе было верным' }
        else { Write-Log "Ранняя синхронизация времени: w32tm вернул код $LASTEXITCODE" }
    } catch { Write-Log "Ранняя синхронизация времени: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Сводка железа: процессор, видеокарта(ы) и драйвер, память, ноутбук/ПК.
#  Сразу видно, например, что видеокарта работает без драйвера.
# ---------------------------------------------------------------------------
Write-HardwareSummary

# ---------------------------------------------------------------------------
#  Подготовка: точка восстановления + запуск фоновых задач
#     Большие скачивания (драйвер видеокарты, Office) стартуют сразу
#     и идут параллельно со следующими шагами — так всё заканчивается быстрее.
# ---------------------------------------------------------------------------
if ($DoRestorePoint -or $DoGpuDriver -or $DoInstallOffice) { Write-Step 'Подготовка' }

if ($DoRestorePoint) {
    try {
        $t = Start-ScriptTask 'Точка восстановления' 'Создаю точку восстановления' {
            Enable-ComputerRestore -Drive "$env:SystemDrive\"
            # Windows разрешает одну точку в сутки — снимаем ограничение
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
            New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
            Checkpoint-Computer -Description 'Перед win11-setup' -RestorePointType MODIFY_SETTINGS
        }
        Wait-Task $t | Out-Null
        Report OK 'Точка восстановления создана' 'откатить: Win+R -> rstrui'
    } catch {
        Report WARN 'Точку восстановления создать не удалось' $_
    }
}

# --- Видеокарта: определяем и сразу начинаем качать драйвер в фоне ---
$NvidiaExe = Join-Path $env:TEMP 'nvidia-driver.exe'
$AmdExe    = Join-Path $env:TEMP 'amd-adrenalin-setup.exe'
$script:GpuJobs = @()

if ($DoGpuDriver) {
    # Только реальные видеокарты NVIDIA / AMD / Intel (виртуальные адаптеры пропускаются)
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match 'VEN_(10DE|1002|8086)' })
    foreach ($gpu in $gpus) {
        $vendor = switch -Regex ($gpu.PNPDeviceID) { 'VEN_10DE' { 'NVIDIA' } 'VEN_1002' { 'AMD' } 'VEN_8086' { 'Intel' } }
        Write-Host "       Видеокарта: $($gpu.Name) (драйвер $($gpu.DriverVersion))" -ForegroundColor DarkGray
        $task = $null

        if ($Offline) {
            # без интернета драйвер берётся из офлайн-папки на шаге 6
        }
        elseif ($vendor -eq 'NVIDIA') {
            $task = Start-ScriptTask 'драйвер NVIDIA' 'Драйвер NVIDIA: ищу последнюю версию' $NvidiaDownloadScript @($gpu.Name, $gpu.DriverVersion, $NvidiaExe) $NvidiaExe
        }
        elseif ($vendor -eq 'AMD') {
            $task = Start-ScriptTask 'драйвер AMD' 'Драйвер AMD: скачивается установщик' {
                param($Out)
                # Официальная утилита AMD сама определяет модель и ставит подходящий драйвер.
                # 3 попытки: сайт AMD и его CDN иногда обрывают соединение или не отвечают по DNS.
                $h  = @{ Referer = 'https://www.amd.com/' }
                $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
                $last = $null
                for ($try = 1; $try -le 3; $try++) {
                    try {
                        $page = Invoke-WebRequest -UseBasicParsing -Headers $h -UserAgent $ua `
                            -Uri 'https://www.amd.com/en/support/download/drivers.html'
                        $url = [regex]::Matches($page.Content, 'https://drivers\.amd\.com/[^"''\s]*minimalsetup[^"''\s]*\.exe') |
                            Select-Object -First 1 -ExpandProperty Value
                        if (-not $url) { throw 'не найдена ссылка на установщик на сайте AMD' }
                        Invoke-WebRequest -Uri $url -OutFile $Out -Headers $h -UserAgent $ua -UseBasicParsing
                        return
                    } catch { $last = $_; if ($try -lt 3) { Start-Sleep -Seconds (4 * $try) } }
                }
                throw $last
            } @($AmdExe) $AmdExe
        }

        if ($task) { $script:BgTasks.Add($task) }
        $script:GpuJobs += [pscustomobject]@{ Gpu = $gpu; Vendor = $vendor; Task = $task }
    }
    if (-not $gpus) { Report SKIP 'Видеокарта NVIDIA/AMD/Intel не найдена' }
}

# --- Microsoft Office ---
# Раньше Office ставился в фоне параллельно с программами. Одновременная установка
# роняла его с ошибкой 1603, поэтому теперь он ставится ПОСЛЕ программ, по очереди.
# Здесь только заранее скачиваем установщик (это можно делать параллельно — сеть не мешает).
$script:OfficeReady = $false     # установщик готов, ставить будем после программ
$script:OfficeAgain = $false
$script:OfficeOdt   = $null
$script:OfficeCfg   = $null

if ($DoInstallOffice) {
    $script:OfficeAgain = (Test-OfficeInstalled) -and $script:Reinstall
    if ((Test-OfficeInstalled) -and -not $script:OfficeAgain) {
        Report SKIP 'Microsoft Office — уже установлен'
    } else {
        try {
            $odtDir = Join-Path $env:TEMP 'office-setup'
            New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
            if ($Offline) {
                # Офлайн: установщик и дистрибутив уже лежат в offline\office
                $source = Join-Path $OfflineDir 'office'
                $odt = Join-Path $source 'setup.exe'
                if (-not (Test-Path $odt)) { throw 'Office нет в офлайн-папке' }
            } else {
                $source = ''
                $odt = Join-Path $odtDir 'setup.exe'
                Invoke-WithRetry -What 'скачивание установщика Office' -Action {
                    Wait-Task (Start-ScriptTask 'Office' 'Microsoft Office: скачиваю установщик' {
                        param($Out) Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $Out -UseBasicParsing
                    } @($odt)) | Out-Null
                    if (-not (Test-Path $odt)) { throw 'установщик Office не скачался' }
                }
            }
            $xml = Get-OfficeConfig $source
            $cfg = Join-Path $odtDir 'config.xml'
            Set-Content -Path $cfg -Value $xml -Encoding UTF8
            $script:OfficeOdt = $odt; $script:OfficeCfg = $cfg; $script:OfficeReady = $true
        } catch {
            Report FAIL 'Microsoft Office — не установился' $_
            $script:FailedInstalls.Add(@{ Kind = 'office'; Name = 'Microsoft Office' })
        }
    }
}

if ($script:BgTasks.Count) {
    Report OK ('Запущено в фоне: ' + (($script:BgTasks | ForEach-Object { $_.Name }) -join ', ')) 'идёт параллельно со следующими шагами'
}

# ---------------------------------------------------------------------------
#  Проверка системы: память (XMP/EXPO), диски, активация, UEFI / Secure Boot / TPM, место
#  Только проверяет и пишет строки — ничего не меняет.
# ---------------------------------------------------------------------------
if ($DoSystemCheck) {
    Write-Step 'Проверка системы'
    try {
        Write-Host '       Собираю сведения о железе и системе...' -ForegroundColor DarkGray
        $info = [pscustomobject]@{ Ram = Get-RamInfo; Disks = Get-DiskInfo; Platform = Get-PlatformInfo }

        # --- Оперативная память ---
        $ram = @($info.Ram)
        if ($ram) {
            $total = ($ram | Measure-Object SizeGB -Sum).Sum
            $cfg   = ($ram | Measure-Object Configured -Minimum).Minimum
            $rated = ($ram | Measure-Object Rated -Maximum).Maximum
            $type  = ($ram | Select-Object -First 1).Type
            if ($rated -gt $cfg * 1.05) {
                Report WARN "Память работает на $cfg МГц, а рассчитана на $rated МГц" 'включите в BIOS профиль XMP (Intel) или EXPO/DOCP (AMD)'
                Add-Manual "Память работает на $cfg МГц вместо $rated МГц. Зайдите в BIOS (клавиша Del или F2 при включении) и включите профиль XMP (Intel) или EXPO/DOCP (AMD)."
            } else {
                Report OK "Память: $total ГБ $type, $cfg МГц — работает на заявленной частоте"
            }
            if ($ram.Count -eq 1 -and -not (Test-IsLaptop)) {
                Report WARN 'Установлена одна планка памяти — одноканальный режим' 'две одинаковые планки дают заметный прирост в играх'
            }
            if (@($ram | Select-Object -ExpandProperty SizeGB -Unique).Count -gt 1 -or @($ram | Select-Object -ExpandProperty Part -Unique).Count -gt 1) {
                Report WARN 'Планки памяти разные' ('установлены: ' + (($ram | ForEach-Object { "$($_.SizeGB) ГБ $($_.Part)" }) -join ', '))
            }
        }

        # --- Результат последней проверки памяти Windows (если была) ---
        $mem = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } `
            -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($mem) {
            $when = $mem.TimeCreated.ToString('dd.MM.yyyy')
            if ($mem.Id -eq 1201) { Report OK "Проверка памяти от $when — ошибок нет" }
            elseif ($mem.Id -eq 1202) { Report FAIL "Проверка памяти от $when нашла ОШИБКИ" 'замените или переставьте планки памяти' }
        }

        # --- Диски ---
        foreach ($d in @($info.Disks)) {
            # Флешки и карты памяти — не диски ПК, их не проверяем (и не пугаем «износом»)
            if ($d.Bus -in 'USB', 'SD', 'MMC') {
                Report SKIP "Съёмный носитель $($d.Model) ($($d.SizeGB) ГБ) — пропущен, это не диск ПК"
                continue
            }
            $det = @()
            if ($null -ne $d.Wear) { $det += "износ $($d.Wear)%" }
            if ($d.Temp)  { $det += "$($d.Temp) °C" }
            if ($d.Hours) { $det += ('наработка {0:N0} ч' -f $d.Hours) }
            $label = "Диск $($d.Model) ($($d.SizeGB) ГБ $($d.Media))"
            if ($d.Health -ne 'Healthy' -or $d.Errors -gt 0) {
                Report FAIL "$label — ПРОБЛЕМЫ: состояние «$(Get-HealthRu $d.Health)», ошибок чтения/записи: $($d.Errors)" 'сохраните данные и замените диск'
            } elseif ($d.Wear -ge 80) {
                Report WARN "$label — сильно изношен" ($det -join ', ')
            } elseif ($d.Temp -ge 65) {
                Report WARN "$label — высокая температура" ($det -join ', ')
            } else {
                Report OK "$label — исправен" ($det -join ', ')
            }
        }

        # --- Windows и платформа ---
        $p = $info.Platform
        if ($p.Activated -eq $true)      { Report OK 'Windows активирована' }
        elseif ($p.Activated -eq $false) { Report WARN 'Windows не активирована' 'Параметры -> Система -> Активация'; Add-Manual 'Windows не активирована. Активируйте её: Параметры -> Система -> Активация.' }
        if ($p.Uefi -eq $false)          { Report WARN 'Компьютер загружается в режиме Legacy BIOS' 'для Windows 11 нужен UEFI' }
        if ($p.SecureBoot -eq $true)     { Report OK 'UEFI и Secure Boot включены' }
        elseif ($p.Uefi)                 { Report WARN 'Secure Boot выключен' 'включается в BIOS; нужен некоторым играм с античитом' }
        if ($p.Tpm -match '^2')          { Report OK "TPM $($p.Tpm) есть" }
        elseif ($p.Tpm)                  { Report WARN "TPM версии $($p.Tpm)" 'для Windows 11 нужен TPM 2.0' }
        else                             { Report WARN 'TPM не найден или выключен в BIOS' 'для Windows 11 нужен TPM 2.0 (fTPM / PTT в BIOS)' }
        if ($null -ne $p.FreeGB) {
            if ($p.FreeGB -lt 20) { Report WARN "На диске $env:SystemDrive мало места: $($p.FreeGB) ГБ" 'нужно минимум 20 ГБ' }
            else { Report OK "На диске $env:SystemDrive свободно $($p.FreeGB) из $($p.SysGB) ГБ" }
        }
    } catch {
        Report FAIL 'Проверка системы не выполнена' $_
    }
}

# ---------------------------------------------------------------------------
#  Отключение защиты (первым — без антивируса всё ставится быстрее)
# ---------------------------------------------------------------------------
if ($DoDisableDefender) {
    Write-Step 'Отключение защиты'

    $mp = $null
    try { $mp = Get-MpComputerStatus } catch {}

    if (-not $mp) {
        Report SKIP 'Защитник Windows не найден (возможно, стоит другой антивирус)'
    } elseif ($mp.IsTamperProtected) {
        Report FAIL 'Защитник Windows НЕ отключён — включена «Защита от подделки»' `
            'выключите вручную: Безопасность Windows -> Защита от вирусов и угроз -> Управление настройками -> Защита от подделки, затем запустите скрипт ещё раз'
    } else {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true `
                -DisableIOAVProtection $true -DisableScriptScanning $true -DisableBlockAtFirstSeen $true `
                -MAPSReporting 0 -SubmitSamplesConsent 2
        } catch { Write-Log "Set-MpPreference: $($_.Exception.Message)" }

        # Политики — чтобы Защитник не включался обратно после перезагрузки
        Apply-RegSet 'Защитник: политики отключения' @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; Name = 'DisableAntiSpyware'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableRealtimeMonitoring'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableBehaviorMonitoring'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableOnAccessProtection'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; Name = 'DisableScanOnRealtimeEnable'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'; Name = 'SpynetReporting'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'; Name = 'SubmitSamplesConsent'; Value = 2 }
        )

        try {
            if ((Get-MpPreference).DisableRealtimeMonitoring) { Report OK 'Защитник Windows: защита в реальном времени отключена' }
            else { Report FAIL 'Защитник Windows: защита в реальном времени всё ещё включена' }
        } catch { Report WARN 'Защитник Windows: не удалось проверить состояние' $_.Exception.Message }
    }

    Apply-RegSet 'SmartScreen отключён (Windows и Edge)' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen'; Value = 0 }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled'; Value = 'Off'; Type = 'String' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'SmartScreenEnabled'; Value = 0 }
    )

    # UAC не выключаем полностью (EnableLUA=0 ломает приложения из Store) — только убираем запросы
    Apply-RegSet 'UAC: запросы «Разрешить изменения?» отключены' @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ConsentPromptBehaviorAdmin'; Value = 0 }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'PromptOnSecureDesktop'; Value = 0 }
    )

    Apply-RegSet 'Уведомления «Безопасности Windows» отключены' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications'; Name = 'DisableNotifications'; Value = 1 }
    )

    if ($DisableFirewall) {
        try {
            Set-NetFirewallProfile -All -Enabled False
            Report OK 'Брандмауэр отключён'
        } catch { Report FAIL 'Брандмауэр не отключён' $_.Exception.Message }
    } else {
        Report SKIP 'Брандмауэр оставлен включённым (настройка $DisableFirewall)'
    }
}

# ---------------------------------------------------------------------------
#  Ненужные службы, телеметрия, реклама
# ---------------------------------------------------------------------------
if ($DoDisableServices) {
    Write-Step 'Отключение ненужных служб'
    foreach ($s in $Services) { Disable-ServiceSafe $s.Name $s.Desc }

    Apply-RegSet 'Телеметрия: минимальный уровень' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 }
    )
    Apply-RegSet 'Рекламный идентификатор отключён' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name = 'DisabledByGroupPolicy'; Value = 1 }
    )
    Apply-RegSet 'Автоустановка «рекомендуемых» приложений отключена' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1 }
    )
    Apply-RegSet 'Реклама в поиске меню «Пуск» (Bing) отключена' @(
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
    )
    Apply-RegSet 'Copilot отключён' @(
        @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
    )
}

# ---------------------------------------------------------------------------
#  Удаление предустановленных приложений
# ---------------------------------------------------------------------------
if ($DoRemoveBloat) {
    Write-Step 'Удаление предустановленных приложений'
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    foreach ($b in $Bloatware) {
        $pkgs = @(Get-AppxPackage -AllUsers -Name $b.Name -ErrorAction SilentlyContinue)
        $prov = @($provisioned | Where-Object DisplayName -eq $b.Name)
        if (-not $pkgs -and -not $prov) { Report SKIP "$($b.Desc) — не установлено"; continue }
        try {
            # Для всех пользователей + из образа, чтобы не появилось у новых пользователей
            foreach ($p in $pkgs) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            foreach ($p in $prov) { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null }
            Report OK "$($b.Desc) — удалено"
        } catch {
            Report FAIL "$($b.Desc) — не удалено" $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
#  Установка программ (по одной: одновременная установка ломает установщики Windows)
# ---------------------------------------------------------------------------
if ($DoInstallApps) {
    Write-Step 'Установка программ'
    if ($Offline) { Report OK 'Установка из офлайн-папки (без интернета)' }
    elseif (Ensure-Winget) { Report OK 'winget готов' }
    foreach ($app in $Apps) { Install-WingetApp $app.Id $app.Name -AllowReinstall }
    # Office — последним, после всех программ (одновременная установка роняет его с ошибкой 1603)
    Invoke-OfficeInstall
}
elseif ($script:OfficeReady) {
    # Программы выключены, но Office нужен — ставим отдельно
    Invoke-OfficeInstall
}

# ---------------------------------------------------------------------------
#  Обновление драйверов (через Центр обновления Windows)
#     Делается ДО отключения обновлений, иначе служба будет выключена.
# ---------------------------------------------------------------------------
if ($DoUpdateDrivers -and $Offline) {
    Write-Step 'Драйверы из офлайн-папки'
    $drvRoot = Join-Path $OfflineDir 'drivers'
    if (-not (Get-ChildItem $drvRoot -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Report SKIP 'В офлайн-папке нет драйверов'
    } else {
        # pnputil ставит только те драйверы, которые подходят к устройствам этого ПК
        $out = Join-Path $env:TEMP 'pnputil.log'
        $code = Wait-Task (Start-ProcessTask 'драйверы' 'Ставлю подходящие драйверы из офлайн-папки' `
            "$env:SystemRoot\System32\pnputil.exe" @('/add-driver', "`"$drvRoot\*.inf`"", '/subdirs', '/install') $out)
        Get-Content $out -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "    $_" }
        switch ($code) {
            0       { Report OK 'Драйверы из офлайн-папки установлены' 'только подходящие к этому ПК' }
            3010    { Report OK 'Драйверы из офлайн-папки установлены' 'нужна перезагрузка'; $script:RebootNeeded = $true }
            259     { Report SKIP 'В офлайн-папке нет драйверов, подходящих к этому ПК' }
            default { Report WARN 'Драйверы из офлайн-папки установлены частично' "код $code, подробности в логе" }
        }
    }
}
elseif ($DoUpdateDrivers) {
    Write-Step 'Обновление драйверов'
    try {
        # Если скрипт запускают повторно — служба обновлений может быть уже выключена
        $wu = Get-Service wuauserv
        if ($wu.StartType -eq 'Disabled') {
            Set-Service wuauserv -StartupType Manual
            Write-Log 'wuauserv временно включена для поиска драйверов'
        }
        Start-Service wuauserv -ErrorAction SilentlyContinue

        $t = Start-ScriptTask 'драйверы' 'Ищу драйверы в Центре обновления (может занять несколько минут)' {
            $session = New-Object -ComObject Microsoft.Update.Session
            $found   = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0").Updates
            if ($found.Count -eq 0) {
                [void]$Status.Lines.Add(@{ Status = 'SKIP'; Text = 'Новых драйверов нет — всё актуально' })
                return
            }
            $n = 0
            foreach ($upd in $found) {
                $n++
                $title = $upd.Title
                try {
                    if (-not $upd.EulaAccepted) { $upd.AcceptEula() }
                    $one = New-Object -ComObject Microsoft.Update.UpdateColl
                    [void]$one.Add($upd)

                    $Status.Text = "Драйвер $n из $($found.Count): скачивается — $title"
                    $dl = $session.CreateUpdateDownloader()
                    $dl.Updates = $one
                    $dlRes = $dl.Download()
                    if ($dlRes.ResultCode -notin 2, 3) {
                        [void]$Status.Lines.Add(@{ Status = 'FAIL'; Text = "Драйвер: $title"; Details = "не скачался, код $($dlRes.ResultCode)" })
                        continue
                    }

                    $Status.Text = "Драйвер $n из $($found.Count): устанавливается — $title"
                    $inst = $session.CreateUpdateInstaller()
                    $inst.Updates = $one
                    $res = $inst.Install()
                    if ($res.ResultCode -in 2, 3) {
                        [void]$Status.Lines.Add(@{ Status = 'OK'; Text = "Драйвер: $title — обновлён"; Reboot = $res.RebootRequired })
                    } else {
                        [void]$Status.Lines.Add(@{ Status = 'FAIL'; Text = "Драйвер: $title"; Details = ('не установился, HRESULT 0x{0:X8}' -f $res.HResult) })
                    }
                } catch {
                    [void]$Status.Lines.Add(@{ Status = 'FAIL'; Text = "Драйвер: $title"; Details = $_.Exception.Message })
                }
            }
        }
        Wait-Task $t | Out-Null
    } catch {
        Report FAIL 'Поиск драйверов не удался' $_
    }
}

# ---------------------------------------------------------------------------
#  Драйвер видеокарты с официального сайта производителя
#     (скачивание уже шло в фоне с самого начала)
# ---------------------------------------------------------------------------
if ($DoGpuDriver) {
    Write-Step $(if ($Offline) { 'Драйвер видеокарты (из офлайн-папки)' } else { 'Драйвер видеокарты (с сайта производителя)' })
    if (-not $script:GpuJobs) { Report SKIP 'Видеокарта NVIDIA/AMD/Intel не найдена' }

    foreach ($job in $script:GpuJobs) {
        $gpu = $job.Gpu
        try {
            switch ($job.Vendor) {
                'NVIDIA' {
                    if ($Offline) {
                        $exe = Join-Path $OfflineDir 'gpu\nvidia\nvidia-driver.exe'
                        if (-not (Test-Path $exe)) { Report WARN "$($gpu.Name) — драйвера NVIDIA нет в офлайн-папке" 'остаётся драйвер Windows'; break }
                        $ver = (Get-Content (Join-Path $OfflineDir 'gpu\nvidia\version.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
                        $digits = "$($gpu.DriverVersion)" -replace '\.', ''
                        $cur = if ($digits.Length -ge 5) { $digits.Substring($digits.Length - 5).Insert(3, '.') } else { '' }
                        if ($ver -and $cur -eq $ver) { Report SKIP "$($gpu.Name) — драйвер $ver уже стоит"; break }
                        Install-NvidiaPackage $gpu $exe $ver $cur
                        break
                    }
                    $r = Wait-Task $job.Task | Select-Object -Last 1
                    if ($r.Skip) { Report SKIP "$($gpu.Name) — драйвер $($r.Latest) уже последний"; break }
                    Install-NvidiaPackage $gpu $NvidiaExe $r.Latest $r.Current
                    break
                }
                'AMD' {
                    # Драйвер мог уже поставиться на шаге «Обновление драйверов» (Центр обновления).
                    # Тогда качать установщик с amd.com не нужно (и незачем падать, если сеть подвела).
                    $now = Get-GpuState | Where-Object { $_.Vendor -eq 'AMD' } | Select-Object -First 1
                    if ($now -and $now.HasDriver) {
                        if ($job.Task) { try { Wait-Task $job.Task | Out-Null } catch { Write-Log "AMD (фон): $($_.Exception.Message)" } }
                        Report OK "$($now.Name) — драйвер AMD уже установлен" "версия $($now.DriverVersion) (например, через Центр обновления)"
                        break
                    }
                    if ($Offline) {
                        $AmdExe = Get-ChildItem (Join-Path $OfflineDir 'gpu\amd') -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                        if (-not $AmdExe) { Report WARN "$($gpu.Name) — драйвера AMD нет в офлайн-папке" 'остаётся драйвер Windows; можно положить пакет в offline\gpu\amd'; break }
                    } else {
                        # Ждём фоновое скачивание установщика; если оно сорвалось (обрыв сети/DNS) — не падаем
                        $dlOk = $true
                        if ($job.Task) { try { Wait-Task $job.Task | Out-Null } catch { $dlOk = $false; Write-Log "AMD: скачивание установщика не удалось — $($_.Exception.Message)" } }
                        if (-not $dlOk -or -not (Test-Path $AmdExe)) {
                            Report WARN "$($gpu.Name) — установщик AMD не скачался" 'обрыв сети; драйвер можно доставить через Центр обновления или вручную с amd.com'
                            Add-Manual "Драйвер видеокарты AMD не скачался (обрыв сети). Запустите скрипт ещё раз или скачайте драйвер с amd.com (модель: $($gpu.Name))."
                            $script:FailedInstalls.Add(@{ Kind = 'gpu-amd'; Name = "драйвер видеокарты AMD ($($gpu.Name))" })
                            break
                        }
                    }
                    Write-Host "       Открыт установщик AMD — нажмите в нём «Установить» и дождитесь конца" -ForegroundColor Yellow
                    $code = Wait-Task (Start-ProcessTask 'AMD' 'Ждём установщик AMD — нажмите в его окне «Установить»' $AmdExe -Visible)
                    # Не верим коду возврата: проверяем, встал ли драйвер на самом деле
                    Start-Sleep -Seconds 3
                    $now = Get-GpuState | Where-Object { $_.Vendor -eq 'AMD' } | Select-Object -First 1
                    if ($now -and $now.HasDriver) {
                        $script:RebootNeeded = $true
                        Report OK "$($now.Name) — драйвер AMD установлен" "версия $($now.DriverVersion)"
                    } else {
                        Report WARN "$($gpu.Name) — драйвер AMD не встал" 'видеокарта всё ещё работает как «Базовый видеоадаптер»'
                        Add-Manual "Драйвер видеокарты AMD не установился. Скачайте его вручную с amd.com (раздел Drivers & Support, ваша модель: $($gpu.Name)) и установите — без него не работают игры и стресс-тест видеокарты."
                        $script:FailedInstalls.Add(@{ Kind = 'gpu-amd'; Name = "драйвер видеокарты AMD ($($gpu.Name))" })
                    }
                }
                'Intel' {
                    if ($Offline) { Report OK "$($gpu.Name) — драйвер Windows или из офлайн-папки"; break }
                    # У Intel нет прямой ссылки на драйвер — ставим их официального помощника
                    Report OK "$($gpu.Name) — драйвер поставлен из Центра обновления"
                    Install-WingetApp 'Intel.IntelDriverAndSupportAssistant' 'Intel Driver & Support Assistant (предложит свежий драйвер)'
                }
            }
        } catch {
            # Если, несмотря на ошибку, драйвер по факту стоит (например, поставлен Центром обновления) — это не провал
            $chk = Get-GpuState | Where-Object { $_.Vendor -eq $job.Vendor } | Select-Object -First 1
            if ($chk -and $chk.HasDriver) {
                Report OK "$($chk.Name) — драйвер уже установлен" "версия $($chk.DriverVersion)"
                Write-Log "Драйвер $($job.Vendor): при установке была ошибка ($($_.Exception.Message)), но драйвер на месте"
            } else {
                Report FAIL "$($gpu.Name) — драйвер не установлен" $_
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  Экран: максимальное разрешение и частота
# ---------------------------------------------------------------------------
if ($DoMaxDisplay) {
    Write-Step 'Экран: максимальное разрешение и частота'
    try {
        if (-not ('DisplayApi' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DisplayApi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lParam);
}
'@
        }

        $found = 0
        for ($i = 0; ; $i++) {
            $dd = New-Object DisplayApi+DISPLAY_DEVICE
            $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
            if (-not [DisplayApi]::EnumDisplayDevices($null, $i, [ref]$dd, 0)) { break }
            if (-not ($dd.StateFlags -band 1)) { continue }   # не подключён к рабочему столу
            $found++

            # Название монитора
            $mon = New-Object DisplayApi+DISPLAY_DEVICE
            $mon.cb = [Runtime.InteropServices.Marshal]::SizeOf($mon)
            $label = if ([DisplayApi]::EnumDisplayDevices($dd.DeviceName, 0, [ref]$mon, 0)) { $mon.DeviceString } else { $dd.DeviceName }
            $label = "Экран $found ($label)"

            $cur = New-Object DisplayApi+DEVMODE
            $cur.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($cur)
            [void][DisplayApi]::EnumDisplaySettings($dd.DeviceName, -1, [ref]$cur)

            # Все режимы экрана: 32 бита, без чересстрочных
            $modes = New-Object System.Collections.Generic.List[object]
            for ($m = 0; ; $m++) {
                $dm = New-Object DisplayApi+DEVMODE
                $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
                if (-not [DisplayApi]::EnumDisplaySettings($dd.DeviceName, $m, [ref]$dm)) { break }
                if ($dm.dmBitsPerPel -eq 32 -and -not ($dm.dmDisplayFlags -band 2)) { $modes.Add($dm) }
            }
            if ($modes.Count -eq 0) { Report FAIL "$label — не удалось получить список режимов"; continue }

            # Сначала максимальное разрешение, затем максимальная частота при нём
            $best = $modes |
                Sort-Object { $_.dmPelsWidth * $_.dmPelsHeight }, { $_.dmDisplayFrequency } -Descending |
                Select-Object -First 1
            $was = "$($cur.dmPelsWidth)x$($cur.dmPelsHeight) $($cur.dmDisplayFrequency) Гц"
            $new = "$($best.dmPelsWidth)x$($best.dmPelsHeight) $($best.dmDisplayFrequency) Гц"

            if ($was -eq $new) { Report SKIP "$label — уже максимум: $new"; continue }

            $best.dmFields = 0x40000 -bor 0x80000 -bor 0x100000 -bor 0x400000  # глубина, ширина, высота, частота
            $r = [DisplayApi]::ChangeDisplaySettingsEx($dd.DeviceName, [ref]$best, [IntPtr]::Zero, 1, [IntPtr]::Zero)
            switch ($r) {
                0       { Report OK   "$label — $new" "было $was" }
                1       { Report OK   "$label — $new" 'применится после перезагрузки'; $script:RebootNeeded = $true }
                default { Report FAIL "$label — не удалось поставить $new" "код $r" }
            }
        }
        if ($found -eq 0) { Report SKIP 'Экраны не найдены' }
    } catch {
        Report FAIL 'Настройка экрана не удалась' $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
#  Регион и время
# ---------------------------------------------------------------------------
if ($DoRegion) {
    Write-Step 'Регион и время'
    try {
        Set-TimeZone -Id $TimeZone
        Report OK "Часовой пояс: $((Get-TimeZone).DisplayName)"
    } catch { Report FAIL "Часовой пояс «$TimeZone» не установлен" 'список поясов: команда tzutil /l' }
    try {
        Set-Service W32Time -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service W32Time -ErrorAction SilentlyContinue
        Invoke-Quiet "$env:SystemRoot\System32\w32tm.exe" /resync /force | Out-Null
        if ($LASTEXITCODE -eq 0) { Report OK 'Время синхронизировано с интернетом' }
        else { Report WARN 'Время не синхронизировано' 'нет интернета — синхронизируется позже само' }
    } catch { Report WARN 'Синхронизация времени не настроена' $_ }
    try {
        $list = New-WinUserLanguageList $Languages[0]
        foreach ($l in $Languages | Select-Object -Skip 1) { $list.Add($l) }
        Set-WinUserLanguageList $list -Force
        Report OK ('Раскладки клавиатуры: ' + ($Languages -join ', '))
    } catch { Report FAIL 'Раскладки клавиатуры не настроены' $_ }
    # 1 = Alt+Shift, 2 = Ctrl+Shift; смена раскладки внутри языка отключена (3)
    $hk = if ($LayoutHotkey -match 'Ctrl') { '2' } else { '1' }
    Apply-RegSet "Переключение раскладки: $LayoutHotkey" @(
        @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Hotkey';          Value = $hk;  Type = 'String' }
        @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Language Hotkey'; Value = $hk;  Type = 'String' }
        @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Layout Hotkey';   Value = '3';  Type = 'String' }
    )
    try {
        # Те же настройки — для экрана входа и новых пользователей
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        Report OK 'Язык и раскладки применены к экрану входа и новым пользователям'
    } catch { Report SKIP 'Копирование настроек языка для новых пользователей недоступно в этой версии Windows' }
}

# ---------------------------------------------------------------------------
#  Игровые настройки и удобство
# ---------------------------------------------------------------------------
if ($DoGameTweaks -or $DoComfortTweaks) {
    Write-Step 'Игровые настройки и удобство'
    if ($DoGameTweaks) {
        Apply-RegSet 'Игровой режим Windows включён' @(
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 1 }
            @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AllowAutoGameMode';   Value = 1 }
        )
        Apply-RegSet 'Аппаратное планирование GPU включено (после перезагрузки)' @(
            @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode'; Value = 2 }
        )
        Apply-RegSet 'Фоновая запись игр (Xbox Game Bar / Game DVR) отключена' @(
            @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR'; Value = 0 }
        )
        Apply-RegSet 'Ускорение мыши отключено (точное прицеливание)' @(
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
            @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
        )
        $script:RebootNeeded = $true
    }
    if ($DoComfortTweaks) {
        try {
            # Пустое значение по умолчанию у этого ключа возвращает меню правой кнопки как в Windows 10
            $k = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            Set-Item -Path $k -Value ''
            $d = Get-DefaultHivePath $k
            if ($d) { if (-not (Test-Path $d)) { New-Item -Path $d -Force | Out-Null }; Set-Item -Path $d -Value '' }
            Report OK 'Классическое меню правой кнопки мыши (как в Windows 10)'
        } catch { Report FAIL 'Классическое меню правой кнопки не включено' $_ }
        Apply-RegSet 'Показ расширений файлов включён' @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 }
        )
        Apply-RegSet 'Реклама, советы и веб-поиск Bing в меню «Пуск» отключены' @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Value = 0 }
        )
        Apply-RegSet 'Тёмная тема включена' @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme';   Value = 0 }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Value = 0 }
        )
        # Перезапуск Проводника, чтобы меню и расширения применились сразу
        try {
            Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Report OK 'Проводник перезапущен — изменения применены' 'панель задач на секунду пропадёт, это нормально'
        } catch { Report WARN 'Проводник не перезапущен' 'изменения применятся после перезагрузки' }
    }
}

# ---------------------------------------------------------------------------
#  OneDrive, Edge и ИИ-функции Windows
# ---------------------------------------------------------------------------
if ($DoOneDriveEdge -or $DoDisableAI) {
    Write-Step 'OneDrive, Edge и ИИ-функции'
    if ($DoOneDriveEdge) {
        Apply-RegSet 'OneDrive: без предложений «сохранить папки в облако»' @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'KFMBlockOptIn'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'DisableNewAccountDetection'; Value = 1 }
        )
        try {
            # OneDrive ставится каждому новому пользователю через «OneDriveSetup» в автозагрузке профиля по умолчанию
            $p = Get-DefaultHivePath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if ($p) { Remove-ItemProperty -Path $p -Name 'OneDriveSetup' -ErrorAction SilentlyContinue }
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
            Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Report OK 'OneDrive: автозапуск отключён' 'сам OneDrive не удалён — его можно запустить вручную'
        } catch { Report WARN 'Автозапуск OneDrive не отключён' $_ }
        Apply-RegSet 'Edge: без фоновой работы, окна первого запуска и навязывания' @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'StartupBoostEnabled';         Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'BackgroundModeEnabled';       Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HideFirstRunExperience';      Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'DefaultBrowserSettingEnabled'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'PromotionalTabsEnabled';      Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'ShowRecommendationsEnabled';  Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled';          Value = 0 }
        )
    }
    if ($DoDisableAI) {
        Apply-RegSet 'Recall (запись всего, что на экране) отключён' @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Value = 0 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
        )
        try {
            $f = Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction Stop
            if ($f.State -eq 'Enabled') {
                Wait-Task (Start-ScriptTask 'Recall' 'Удаляю компонент Recall' {
                    Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart | Out-Null
                }) | Out-Null
                Report OK 'Компонент Recall удалён из системы'
            }
        } catch {}
        Apply-RegSet '«Нажмите, чтобы сделать» (Click to Do) и ИИ-агент в Параметрах отключены' @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Value = 1 }
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableSettingsAgent'; Value = 1 }
        )
        Apply-RegSet 'ИИ в Paint и Блокноте отключён' @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableCocreator';      Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableGenerativeFill'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableImageCreator';   Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\WindowsNotepad'; Name = 'DisableAIFeatures'; Value = 1 }
        )
    }
}

# ---------------------------------------------------------------------------
#  Программы по умолчанию
#  Windows 11 не даёт программам менять это напрямую, поэтому используется официальный способ:
#  файл сопоставлений (для новых пользователей) + политика (для всех при следующем входе).
# ---------------------------------------------------------------------------
if ($DoDefaultApps) {
    Write-Step 'Программы по умолчанию'
    try {
        $assoc = @()
        foreach ($app in $DefaultApps) {
            $found = @(); $missing = @()
            foreach ($t in $app.Types) {
                $id = Find-ProgId $t $app.Match
                if ($id) { $assoc += "  <Association Identifier=`"$t`" ProgId=`"$id`" ApplicationName=`"$($app.Name)`" />"; $found += $t }
                else { $missing += $t }
            }
            if ($found -and -not $missing) { Report OK "$($app.Name) — по умолчанию для: $($found -join ' ')" }
            elseif ($found) { Report WARN "$($app.Name) — по умолчанию для: $($found -join ' ')" "не нашлись: $($missing -join ' ')" }
            else { Report SKIP "$($app.Name) — не установлен или не зарегистрировал свои типы файлов" }
        }
        if ($assoc) {
            $dir = Join-Path $env:ProgramData 'win11-setup'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $xmlFile = Join-Path $dir 'default-apps.xml'
            Set-Content -Path $xmlFile -Encoding UTF8 -Value (@('<?xml version="1.0" encoding="UTF-8"?>', '<DefaultAssociations>') + $assoc + '</DefaultAssociations>')
            Invoke-Quiet "$env:SystemRoot\System32\Dism.exe" /Online "/Import-DefaultAppAssociations:$xmlFile" | Out-Null
            $dismOk = ($LASTEXITCODE -eq 0)
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DefaultAssociationsConfiguration' $xmlFile 'String'
            if ($dismOk) { Report OK 'Сопоставления сохранены' 'применятся после следующего входа в систему' }
            else { Report WARN 'Сопоставления сохранены только политикой' 'применятся после следующего входа в систему' }
        }
    } catch { Report FAIL 'Программы по умолчанию не настроены' $_ }
}

# ---------------------------------------------------------------------------
#  Электропитание
# ---------------------------------------------------------------------------
if ($DoPowerPlan) {
    Write-Step 'Электропитание'
    $high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # «Высокая производительность»
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'   # «Сбалансированная»
    $powercfg = "$env:SystemRoot\System32\powercfg.exe"
    try {
        if (Test-IsLaptop) {
            Invoke-Quiet $powercfg /setactive $balanced | Out-Null
            if ($LASTEXITCODE -eq 0) { Report OK 'Ноутбук: схема «Сбалансированная»' 'бережёт батарею; гибернация оставлена' }
            else { Report FAIL 'Схема электропитания не изменена' "код $LASTEXITCODE" }
        } else {
            $list = (Invoke-Quiet $powercfg /list) -join "`n"
            $guid = $high
            if ($list -notmatch $high) {
                # На некоторых ПК схема скрыта — создаём её копию
                $dup = (Invoke-Quiet $powercfg -duplicatescheme $high) -join ' '
                if ($dup -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $guid = $Matches[1] }
            }
            Invoke-Quiet $powercfg /setactive $guid | Out-Null
            if ($LASTEXITCODE -eq 0) { Report OK 'Схема электропитания «Высокая производительность»' }
            else { Report FAIL 'Схема «Высокая производительность» не включена' "код $LASTEXITCODE" }

            Invoke-Quiet $powercfg /change standby-timeout-ac 0 | Out-Null
            Invoke-Quiet $powercfg /change monitor-timeout-ac $MonitorOffMinutes | Out-Null
            if ($LASTEXITCODE -eq 0) { Report OK "Сон отключён, экран гаснет через $MonitorOffMinutes мин." }
            else { Report WARN 'Настройки сна не изменены' "код $LASTEXITCODE" }

            $hib = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
            Invoke-Quiet $powercfg /hibernate off | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $freed = if ($hib) { ('освобождено {0:N1} ГБ' -f ($hib.Length / 1GB)) } else { '' }
                Report OK 'Гибернация отключена' $freed
            } else { Report WARN 'Гибернацию отключить не удалось' "код $LASTEXITCODE" }
        }
    } catch { Report FAIL 'Настройка электропитания не удалась' $_ }
}

# ---------------------------------------------------------------------------
#  Отключение обновлений Windows
# ---------------------------------------------------------------------------
if ($DoDisableUpdates) {
    Write-Step 'Отключение обновлений Windows'

    Apply-RegSet 'Политика: автообновление выключено' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'AUOptions';    Value = 1 }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoRebootWithLoggedOnUsers'; Value = 1 }
    )
    Apply-RegSet 'Политика: драйверы через обновления не ставятся' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1 }
    )
    Apply-RegSet 'Политика: переход на новую версию Windows запрещён' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'DisableOSUpgrade'; Value = 1 }
    )

    Disable-ServiceSafe 'wuauserv'     'Центр обновления Windows'
    Disable-ServiceSafe 'UsoSvc'       'Оркестратор обновлений'
    Disable-ServiceSafe 'WaaSMedicSvc' 'Служба восстановления обновлений'
    Disable-ServiceSafe 'DoSvc'        'Оптимизация доставки'

    foreach ($path in '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WaaSMedic\') {
        $tasks = Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue
        if (-not $tasks) { Report SKIP "Задачи $path — нет"; continue }
        $ok = 0; $fail = 0
        foreach ($t in $tasks) {
            try { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; $ok++ }
            catch { $fail++ }
        }
        if ($fail -eq 0)   { Report OK   "Задачи $path — отключены ($ok)" }
        elseif ($ok -gt 0) { Report WARN "Задачи $path — отключено $ok из $($ok + $fail)" 'остальные защищены системой' }
        else               { Report FAIL "Задачи $path — не отключены" 'защищены системой' }
    }
}

# ---------------------------------------------------------------------------
#  Стресс-тест и оценка ПК (только если выбран в стартовом окне)
# ---------------------------------------------------------------------------
function Get-GpuVramGB {
    $max = 0
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in (Get-ChildItem $class -ErrorAction SilentlyContinue)) {
        $v = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
        if ($v -and [double]$v -gt $max) { $max = [double]$v }
    }
    [Math]::Round($max / 1GB)
}

function Show-BenchWindow([string]$Text) {
    $f = New-Object Windows.Forms.Form
    $f.Text          = 'Итог стресс-теста'
    $f.StartPosition = 'CenterScreen'
    $f.Size          = New-Object Drawing.Size(760, 640)
    $f.TopMost       = $true
    $tb = New-Object Windows.Forms.TextBox
    $tb.Multiline  = $true
    $tb.ReadOnly   = $true
    $tb.ScrollBars = 'Vertical'
    $tb.Dock       = 'Fill'
    $tb.Font       = New-Object Drawing.Font('Consolas', 10)
    $tb.BackColor  = [Drawing.Color]::White
    $tb.Text       = $Text -replace "`r?`n", "`r`n"
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Закрыть'
    $ok.Dock = 'Bottom'
    $ok.Height = 40
    $ok.Add_Click({ $f.Close() })
    $f.Controls.Add($tb)
    $f.Controls.Add($ok)
    $f.Add_Shown({ $tb.SelectionLength = 0 })
    [void]$f.ShowDialog()
    $f.Dispose()
}

if ($DoStressTest) {
    Write-Step 'Стресс-тест и оценка ПК'
    try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $gpuName = (@(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match 'VEN_(10DE|1002|8086)' }) |
                Sort-Object { $_.PNPDeviceID -notmatch 'VEN_8086' } -Descending | Select-Object -First 1).Name
    $ramGB   = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $vramGB  = Get-GpuVramGB
    $rating  = 0
    $stable  = $null

    # --- Замер температур на всё время теста ---
    $mon = $null; $temps = $null
    try {
        $mon = Start-TempMonitor
        $script:TempStatus = $mon.Task.Status
    } catch { Report WARN 'Замер температур не запущен' $_ }

    # --- Процессор и память: встроенный тест 7-Zip, несколько проходов под полной нагрузкой ---
    $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe"
    if (-not (Test-Path $sevenZip)) { Install-WingetApp '7zip.7zip' '7-Zip (нужен для теста)' -ForTest }
    if (Test-Path $sevenZip) {
        try {
            $out  = Join-Path $env:TEMP '7z-bench.txt'
            if ($mon) { $mon.Task.Status.Phase = 'cpu' }
            $code = Wait-Task (Start-ProcessTask 'стресс-тест' "Стресс-тест процессора и памяти: $StressPasses проходов (компьютер может шуметь)" `
                        $sevenZip @('b', "$StressPasses") $out)
            $tot = Get-Content $out -ErrorAction SilentlyContinue | Where-Object { $_ -match '^Tot:' } | Select-Object -Last 1
            if ($tot) { $rating = [int](($tot -split '\s+' | Where-Object { $_ -match '^\d+$' }) | Select-Object -Last 1) }
            $stable = ($code -eq 0)
            if ($stable -and $rating) {
                Report OK ("Процессор и память: {0:N0} MIPS, ошибок нет — стабильно" -f $rating)
            } else {
                Report FAIL 'Процессор/память: ошибка под нагрузкой' "код $code — возможен перегрев, разгон или сбойная память"
            }
        } catch { Report FAIL 'Стресс-тест процессора не выполнен' $_ }
    }

    if ($mon) { $mon.Task.Status.Phase = 'gpu' }

    # --- Видеокарта: FurMark (официальный пакет Geeks3D.FurMark.2 из winget) ---
    $gpuScore = 0; $gpuFps = 0; $gpuStable = $null; $gpuCrashes = 0; $fmGpuTemp = $null
    # Без драйвера видеокарты FurMark открывается и сразу закрывается — тест бессмыслен.
    # Прямо говорим причину, а не «окно закрыли раньше времени».
    $gpuReal = @(Get-GpuState | Where-Object { $_.Vendor -in 'NVIDIA', 'AMD', 'Intel' })
    $noGpuDriver = $gpuReal.Count -and -not (@($gpuReal | Where-Object { $_.HasDriver }).Count)
    $fm = $null
    if ($noGpuDriver) {
        Report WARN 'Тест видеокарты пропущен — нет драйвера видеокарты' 'видеокарта работает как «Базовый видеоадаптер»; поставьте драйвер и запустите тест снова'
        Add-Manual 'Стресс-тест видеокарты пропущен, потому что не установлен драйвер видеокарты. Поставьте драйвер и запустите «Только стресс-тесты» ещё раз.'
    } else {
        $fm = Get-ChildItem "$env:ProgramFiles\Geeks3D" -Recurse -Filter 'furmark.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $fm) {
            Install-WingetApp 'Geeks3D.FurMark.2' 'FurMark (нужен для теста видеокарты)' @('--installer-type', 'inno', '--scope', 'machine') -ForTest
            $fm = Get-ChildItem "$env:ProgramFiles\Geeks3D" -Recurse -Filter 'furmark.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if ($fm) {
        try {
            $started = Get-Date
            $out = Join-Path $env:TEMP 'furmark-bench.txt'
            $t = Start-ProcessTask 'FurMark' "Стресс-тест видеокарты (FurMark): $GpuStressSeconds сек. Окно с «бубликом» закроется само — не закрывайте его" `
                    $fm.FullName @('--demo', 'furmark-gl', '--width', '1920', '--height', '1080', '--benchmark', '--max-time', "$GpuStressSeconds") $out
            # FurMark после теста сам не закрывается — закрываем его (со всеми окнами) через 10 секунд после конца теста
            $code = Wait-Task $t -TimeoutSec ($GpuStressSeconds + 10) -KillNames 'furmark', 'FurMark_GUI'
            $ranSec = [int]$t.Timer.Elapsed.TotalSeconds
            $closedEarly = (-not $t.TimedOut) -and $ranSec -lt ($GpuStressSeconds - 5)

            # Сбросы видеодрайвера во время теста (событие 4101 «драйвер перестал отвечать и был восстановлен»)
            $gpuCrashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = $started } -ErrorAction SilentlyContinue).Count

            $text = (Get-Content $out -Raw -ErrorAction SilentlyContinue) + "`n" +
                    ((Get-ChildItem $fm.DirectoryName -Filter '*.txt' -ErrorAction SilentlyContinue |
                      Where-Object { $_.LastWriteTime -gt $started } | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n")
            Write-Log "FurMark (код $code):"; Write-Log $text
            if ($text -match '(?i)score\D{0,20}(\d+)') { $gpuScore = [int]$Matches[1] }
            if ($text -match '(?i)avg\D{0,10}(\d+)')   { $gpuFps   = [int]$Matches[1] }
            # Температуру видеокарты FurMark знает сам (max temperature / core temperature) —
            # берём её как запасной вариант, если датчики LibreHardwareMonitor промолчали
            foreach ($m in [regex]::Matches($text, '(?i)(?:max |core )temperature[:\s]+(\d{2,3})')) {
                $v = [int]$m.Groups[1].Value
                if ($v -gt 0 -and $v -lt 130 -and ($null -eq $fmGpuTemp -or $v -gt $fmGpuTemp)) { $fmGpuTemp = $v }
            }

            $gpuStable = ($gpuCrashes -eq 0) -and -not $closedEarly
            $detail = @()
            if ($gpuScore) { $detail += "$gpuScore очков" }
            if ($gpuFps)   { $detail += "средний FPS $gpuFps" }
            if ($gpuStable) {
                Report OK 'Видеокарта: выдержала нагрузку, сбоев нет' ($detail -join ', ')
            } elseif ($closedEarly -and $gpuCrashes -eq 0) {
                Report WARN "Видеокарта: тест прерван через $ranSec сек. из $GpuStressSeconds" 'окно FurMark закрыли раньше времени — результат неполный'
            } else {
                Report FAIL "Видеокарта: драйвер сбрасывался под нагрузкой ($gpuCrashes раз)" 'возможен перегрев, разгон или слабый блок питания'
            }
        } catch { Report FAIL 'Стресс-тест видеокарты не выполнен' $_ }
    } elseif (-not $noGpuDriver) {
        Report FAIL 'FurMark не установлен — тест видеокарты пропущен'
        $script:FailedInstalls.Add(@{ Kind = 'winget'; Id = 'Geeks3D.FurMark.2'; Name = 'FurMark'; AllowReinstall = $false })
    }

    # --- Температуры и троттлинг ---
    # На ноутбуках пороги мягче: там снижение частоты под долгой нагрузкой — обычное
    # ограничение мощности и температуры, а не поломка. Тревога — от 95 °C и выше.
    $isLaptop = Test-IsLaptop
    if ($mon) {
        $temps = Stop-TempMonitor $mon
        $script:TempStatus = $null
        # Если датчики LibreHardwareMonitor не дали температуру видеокарты — берём её из отчёта FurMark
        $gpuTempFromFm = $false
        if ($null -eq $temps.GpuMax -and $null -ne $fmGpuTemp) { $temps.GpuMax = $fmGpuTemp; $gpuTempFromFm = $true }
        if ($null -ne $temps.CpuMax) {
            $c = [int]$temps.CpuMax
            $cpuHot  = if ($isLaptop) { 90 } else { 86 }
            if ($c -ge 95)         { Report FAIL "Процессор перегревается: до $c °C" 'проверьте кулер, термопасту и продувку корпуса' }
            elseif ($c -ge $cpuHot) { Report WARN "Процессор горячий под нагрузкой: до $c °C" $(if ($isLaptop) { 'для ноутбука под 100% нагрузкой это близко к норме; следите за пылью и вентиляцией' } else { 'охлаждение работает на пределе' }) }
            else                   { Report OK   "Температура процессора под нагрузкой: до $c °C — норма" }
        } else { Report WARN 'Температура процессора не измерена' 'датчики не ответили' }
        if ($null -ne $temps.GpuMax) {
            $g = [int]$temps.GpuMax
            $src = if ($gpuTempFromFm) { ' (по данным FurMark)' } else { '' }
            if ($g -ge 88)     { Report FAIL "Видеокарта перегревается: до $g °C$src" 'проверьте вентиляторы видеокарты и продувку корпуса' }
            elseif ($g -ge 81) { Report WARN "Видеокарта горячая под нагрузкой: до $g °C$src" 'охлаждение работает на пределе' }
            else               { Report OK   "Температура видеокарты под нагрузкой: до $g °C — норма$src" }
        } else { Report WARN 'Температура видеокарты не измерена' 'датчики не ответили' }
        if ($null -ne $temps.FreqDrop) {
            $c = [int]$temps.CpuMax
            if ($isLaptop -and $temps.FreqDrop -ge 15 -and $c -lt 95) {
                # Ноутбук: частота снижается, но перегрева нет — это штатное ограничение мощности
                Report OK "Частота процессора снижается под нагрузкой на $($temps.FreqDrop)% — обычно для ноутбука" 'перегрева нет; это ограничение мощности, а не поломка'
            }
            elseif ($temps.FreqDrop -ge 15) { Report WARN "Троттлинг: частота процессора упала на $($temps.FreqDrop)% под нагрузкой" 'процессор сбрасывает частоту — перегрев или слабое питание' }
            else { Report OK 'Троттлинга нет: частота процессора держится под нагрузкой' }
        }
    }

    # --- Оценка Windows (WinSAT): процессор, память, графика, диск ---
    $sat = $null
    try {
        $code = Wait-Task (Start-ProcessTask 'оценка' 'Оценка ПК (WinSAT): процессор, память, видеокарта, диск — 2–5 минут' `
                    "$env:SystemRoot\System32\winsat.exe" @('formal'))
        $sat = Get-CimInstance Win32_WinSAT | Select-Object -First 1
        if ($sat -and $sat.CPUScore) { Report OK 'Оценка ПК (WinSAT) выполнена' }
        else { Report WARN 'Оценка ПК (WinSAT) не дала результатов' "код $code" }
    } catch { Report WARN 'Оценка ПК (WinSAT) не выполнена' $_ }

    # --- Отчёт ---
    $bar = { param($v, $max) ('█' * [Math]::Max(1, [Math]::Round(30 * $v / $max))) }
    $r = New-Object System.Collections.Generic.List[string]
    $r.Add('ИТОГ СТРЕСС-ТЕСТА'); $r.Add('=' * 70); $r.Add('')
    $r.Add("Процессор:   $cpuName")
    $r.Add("Видеокарта:  $gpuName" + $(if ($vramGB) { ", $vramGB ГБ видеопамяти" } else { '' }))
    $r.Add("Оперативная память: $ramGB ГБ")
    $r.Add('')
    if ($rating) {
        $r.Add(("Результат процессора (7-Zip): {0:N0} MIPS" -f $rating))
        $r.Add('Стабильность под нагрузкой:   ' + $(if ($stable) { 'ОК, ошибок нет' } else { 'ЕСТЬ ОШИБКИ — проверьте охлаждение и память' }))
        $r.Add('')
    }
    if ($null -ne $gpuStable) {
        $g = "Видеокарта (FurMark, 1920x1080, $GpuStressSeconds сек.): "
        $g += if ($gpuScore) { "$gpuScore очков" } else { 'счёт не прочитан' }
        if ($gpuFps) { $g += ", средний FPS $gpuFps" }
        $r.Add($g)
        $r.Add('Стабильность видеокарты:      ' + $(if ($gpuStable) { 'ОК, сбоев драйвера нет' }
                                                   elseif ($gpuCrashes) { "СБОИ ДРАЙВЕРА ($gpuCrashes) — проверьте охлаждение и питание" }
                                                   else { 'тест прерван раньше времени' }))
        $r.Add('')
    }
    if ($temps -and ($null -ne $temps.CpuMax -or $null -ne $temps.GpuMax)) {
        $r.Add('Температуры под нагрузкой (максимум):')
        if ($null -ne $temps.CpuMax) { $r.Add("  Процессор:  $([int]$temps.CpuMax) °C   (норма до 85, выше 95 — перегрев)") }
        if ($null -ne $temps.GpuMax) { $r.Add("  Видеокарта: $([int]$temps.GpuMax) °C   (норма до 80, выше 88 — перегрев)") }
        if ($null -ne $temps.FreqDrop) {
            $r.Add('  Троттлинг процессора: ' + $(if ($temps.FreqDrop -ge 15) { "ДА, частота упала на $($temps.FreqDrop)%" } else { 'нет' }))
        }
        $r.Add('')
    }
    if ($sat -and $sat.CPUScore) {
        $r.Add('Оценки Windows (от 1.0 до 9.9, чем больше — тем лучше):')
        $r.Add(('  Процессор {0,4}   Память {1,4}   Графика {2,4}   Игровая графика {3,4}   Диск {4,4}' -f
            $sat.CPUScore, $sat.MemoryScore, $sat.GraphicsScore, $sat.D3DScore, $sat.DiskScore))
        $r.Add('')
    }

    if ($rating) {
        $r.Add('Сравнение с другими процессорами (7-Zip, примерные значения):')
        $rows = @($CpuReference | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Score = $_.Score; Mine = $false } })
        $rows += [pscustomobject]@{ Name = 'ВАШ ПК'; Score = $rating; Mine = $true }
        $max = ($rows | Measure-Object Score -Maximum).Maximum
        foreach ($row in ($rows | Sort-Object Score)) {
            $mark = if ($row.Mine) { '  <<<' } else { '' }
            $r.Add(('  {0,-28} {1,9:N0}  {2}{3}' -f $row.Name, $row.Score, (& $bar $row.Score $max), $mark))
        }
        $r.Add('')

        $r.Add('Игры (очень приблизительно, по процессору и видеопамяти):')
        foreach ($g in $GameTiers) {
            $cpuOk  = $rating -ge $g.Cpu
            $vramOk = (-not $vramGB) -or $vramGB -ge $g.Vram
            $verdict = if ($cpuOk -and $vramOk) { 'пойдут' }
                       elseif ($rating -ge $g.Cpu * 0.7 -and ((-not $vramGB) -or $vramGB -ge $g.Vram / 2)) { 'на низких настройках' }
                       else { 'скорее не пойдут' }
            $r.Add(('  {0,-44} {1}' -f $g.Games, $verdict))
        }
        $r.Add('')
        $r.Add('Сравнение — ориентир, а не точный прогноз: многое зависит от видеокарты и настроек игры.')
    }

    $text = $r -join "`n"
    $benchFile = Join-Path $LogDir ("stress-test_{0:yyyy-MM-dd_HH-mm}.txt" -f (Get-Date))
    try { Set-Content -Path $benchFile -Value $text -Encoding UTF8; Report OK "Итог стресс-теста сохранён" $benchFile } catch {}
    # --- Проверка памяти Windows при следующей перезагрузке ---
    if ($DoMemTest) {
        Invoke-Quiet "$env:SystemRoot\System32\bcdedit.exe" /bootsequence '{memdiag}' | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Report OK 'Проверка памяти назначена на следующую перезагрузку' 'займёт 10–20 минут; результат покажет «Проверка системы» при следующем запуске скрипта'
        } else { Report WARN 'Проверку памяти назначить не удалось' "код $LASTEXITCODE; можно вручную: Win+R -> mdsched" }
    }

    $script:StressData = [pscustomobject]@{
        Rating = $rating; Stable = $stable; GpuScore = $gpuScore; GpuStable = $gpuStable
        CpuMax = $temps.CpuMax; GpuMax = $temps.GpuMax; FreqDrop = $temps.FreqDrop; Sat = $sat
    }
    if ($RemoveTestTools) {
        $items = @($script:TestInstalled)
        if ($items.Count) {
            # Удаляем в обратном порядке (по индексу, без [array]::Reverse — он падал на PowerShell 5.1):
            # сначала программы, потом драйвер датчиков, от которого они зависят.
            # Каждая программа — в своём try, чтобы сбой на одной не мешал удалить остальные.
            for ($i = $items.Count - 1; $i -ge 0; $i--) {
                $p = $items[$i]
                try {
                    if ($Offline) { Uninstall-OfflineApp $p } else { Uninstall-WingetApp $p.Id $p.Name }
                } catch {
                    Write-Log "Удаление $($p.Name): $($_ | Out-String)"
                    Report WARN "$($p.Name) — удалить не удалось" 'осталась на ПК; можно удалить вручную'
                }
            }
        } else {
            Report SKIP 'Удалять нечего — программы для тестов уже были на ПК до запуска'
        }
    }
    Clear-Spinner
    try { Show-BenchWindow $text } catch { Write-Log "Окно с итогом: $($_.Exception.Message)" }
    } catch {
        # Одна ошибка в стресс-тесте не должна ронять весь скрипт — очистка и паспорт впереди
        Report FAIL 'Стресс-тест прерван из-за ошибки' $_
        Write-Log "Стресс-тест: $($_ | Out-String)"
    }
}

# ---------------------------------------------------------------------------
#  Оптимизация и очистка
# ---------------------------------------------------------------------------
if ($DoOptimize) {
    Write-Step 'Оптимизация и очистка'
    $before   = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
    $isLaptop = Test-IsLaptop

    # --- Автозагрузка ---
    if ($DoStartupCleanup) {
        # Отключаем так же, как «Диспетчер задач -> Автозагрузка -> Отключить»: программа не может
        # включить себя обратно, а включить её можно там же одной кнопкой
        $disabled = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        $runKeys = @(
            @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
            @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
            @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        )
        $done = @()
        foreach ($k in $runKeys) {
            $names = @((Get-Item $k.Run -ErrorAction SilentlyContinue).Property)
            foreach ($n in $names) {
                if (-not ($StartupBlock | Where-Object { $n -like $_ })) { continue }
                try { Set-Reg $k.Approved $n $disabled 'Binary'; $done += $n } catch {}
            }
        }
        # Steam и Discord добавляют себя в автозагрузку при первом запуске — отключаем заранее
        foreach ($n in 'Steam', 'Discord') {
            if ($n -notin $done -and ($StartupBlock | Where-Object { $n -like $_ })) {
                try { Set-Reg $runKeys[0].Approved $n $disabled 'Binary' } catch {}
            }
        }
        if ($done) { Report OK ('Убрано из автозагрузки: ' + (($done | Select-Object -Unique) -join ', ')) 'включить обратно: Диспетчер задач -> Автозагрузка' }
        else { Report OK 'Автозагрузка: лишнего нет' 'Steam и Discord отключены заранее' }
    }

    # --- Сеть (безопасно, VPN не трогаем: DNS-серверы не прописываем) ---
    try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null; Report OK 'Кэш DNS очищен' }
    catch { Report FAIL 'Не удалось очистить кэш DNS' $_.Exception.Message }
    Apply-RegSet 'Мультимедийный троттлинг сети снят' @(
        # -1 как DWord даёт в реестре 0xFFFFFFFF (отключение троттлинга) без переполнения Int32
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = -1 }
    )
    if (-not $isLaptop) {
        try {
            $n = 0
            foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop)) {
                try { Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; $n++ } catch {}
            }
            if ($n) { Report OK "Сетевая карта не будет засыпать ($n шт.)" } else { Report SKIP 'Управление питанием сетевой карты недоступно' }
        } catch { Report SKIP 'Сетевые адаптеры для настройки питания не найдены' }
    }

    # --- Ускорение и поведение системы ---
    Apply-RegSet 'Фоновые приложения отключены' @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Value = 2 }
    )
    Apply-RegSet 'Задержка запуска автозагрузки убрана' @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec'; Value = 0 }
    )
    try {
        $ssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        if (-not (Test-Path $ssRoot)) { New-Item -Path $ssRoot -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-Reg $ssRoot '01' 1       # включить Storage Sense
        Set-Reg $ssRoot '2048' 1     # очищать корзину
        Set-Reg $ssRoot '256' 30     # ...файлы старше 30 дней
        Report OK 'Storage Sense включён (ПК будет сам убирать мусор дальше)'
    } catch { Report FAIL 'Не удалось включить Storage Sense' $_.Exception.Message }

    # --- Опция: визуальные эффекты на производительность ---
    if ($OptOptions.VisualEffects) {
        Apply-RegSet 'Визуальные эффекты — на производительность (сглаживание шрифтов оставлено)' @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Value = 2 }
            @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'FontSmoothing'; Value = '2'; Type = 'String' }
        )
    }

    # --- Опция: дополнительные службы ---
    if ($OptOptions.ExtraServices) { foreach ($s in $ExtraServices) { Disable-ServiceSafe $s.Name $s.Desc } }

    # --- Опция: гибернация (только десктоп) ---
    if ($OptOptions.Hibernate) {
        if ($isLaptop) { Report SKIP 'Гибернацию на ноутбуке не трогаем (ломает быстрый старт)' }
        else {
            try { & "$env:SystemRoot\System32\powercfg.exe" /hibernate off | Out-Null; Report OK 'Гибернация отключена, hiberfil.sys удалён' }
            catch { Report FAIL 'Не удалось отключить гибернацию' $_.Exception.Message }
        }
    }

    # --- Опция: зарезервированное хранилище ---
    if ($OptOptions.ReservedStorage) {
        $log  = Join-Path $env:TEMP 'reserved.log'
        $code = Wait-Task (Start-ProcessTask 'reserved' 'Отключаю зарезервированное хранилище' "$env:SystemRoot\System32\Dism.exe" @('/Online', '/Set-ReservedStorageState', '/State:Disabled') $log)
        if ($code -eq 0) { Report OK 'Зарезервированное хранилище отключено (освобождает ~7 ГБ)' }
        else { Report WARN 'Зарезервированное хранилище отключить не удалось' 'иногда мешают ожидающие обновления' }
    }

    # --- Опция: удалить OneDrive полностью ---
    if ($OptOptions.OneDriveRemove) {
        try {
            Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            foreach ($ex in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
                if (Test-Path $ex) { Start-Process $ex -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
            }
            Report OK 'OneDrive удалён'
        } catch { Report FAIL 'OneDrive удалить не удалось' $_.Exception.Message }
    }

    # --- Опция: приватность при передаче (очистка истории) ---
    if ($OptOptions.PrivacyHandover) {
        try {
            Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'    -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths' -Recurse -Force -ErrorAction SilentlyContinue
            try { Set-Clipboard -Value ' ' -ErrorAction SilentlyContinue } catch {}
            Report OK 'История очищена (недавние файлы, «Выполнить», адреса, буфер обмена)'
        } catch { Report FAIL 'Не всю историю удалось очистить' $_.Exception.Message }
    }

    # --- Опция: старые драйверы в DriverStore (активные оставляем) ---
    if ($OptOptions.OldDrivers) {
        $t = Start-ScriptTask 'драйверы' 'Удаляю старые версии драйверов (активные оставляю)' {
            # Get-WindowsDriver -Online — объекты CIM, не зависят от языка системы. Текстовый
            # вывод pnputil /enum-drivers на русской Windows локализован («Имя опубликованного…»),
            # английские шаблоны ничего не находили → «удалено 0» при реально существующих дублях.
            try { $drivers = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { return -1 }
            $removed = 0
            # Группируем по имени исходного inf (leaf OriginalFileName одинаков у разных версий);
            # в каждой группе оставляем самую свежую версию, остальные удаляем по oemNN.inf (.Driver).
            foreach ($g in ($drivers | Where-Object { $_.OriginalFileName } |
                            Group-Object { Split-Path $_.OriginalFileName -Leaf } |
                            Where-Object { $_.Count -gt 1 })) {
                $sorted = $g.Group | Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending
                foreach ($old in ($sorted | Select-Object -Skip 1)) {
                    & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $old.Driver 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) { $removed++ }
                }
            }
            $removed
        }
        $n = Wait-Task $t | Select-Object -Last 1
        if ([int]$n -lt 0) { Report WARN 'Старые драйверы: не удалось перечислить (ограничение системы)' }
        else { Report OK "Старые драйверы удалены: $([int]$n) шт." 'активные версии оставлены' }
    }

    # --- Очистка файлов (в фоне: мусор, корзина, сжатие WinSxS) ---
    if ($DoCleanup) {
        $userTemp = [Environment]::ExpandEnvironmentVariables([Environment]::GetEnvironmentVariable('TEMP', 'User'))
        $paths    = @($userTemp) + @($CleanTargets | ForEach-Object { $_.Path }) + @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db")
        $argList  = New-Object object[] 3
        $argList[0] = $paths
        $argList[1] = $OptOptions
        $argList[2] = $WorkDir   # собственную рабочую папку скрипта чистить нельзя (см. ниже)
        $t = Start-ScriptTask 'очистка' 'Удаляю временные и ненужные файлы' {
            param($Paths, $Opt, $WorkDir)
            foreach ($p in $Paths) {
                if (-not $p) { continue }
                if ($p -match '\*') { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
                elseif (Test-Path $p) {
                    # Не трогаем собственную рабочую папку (C:\Windows\Temp\win11-setup) — она лежит
                    # внутри C:\Windows\Temp. В ней логи winget, распакованный драйвер и пр., и в неё же
                    # пишут логи последующие шаги (SFC/DISM): удаление роняло весь прогон.
                    Get-ChildItem $p -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -ne $WorkDir } |
                        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            # Temp всех пользователей
            Get-ChildItem "$env:SystemDrive\Users\*\AppData\Local\Temp" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            # Windows.old и большой дамп памяти
            if (Test-Path "$env:SystemDrive\Windows.old") { & "$env:SystemRoot\System32\cmd.exe" /c "rd /s /q `"$env:SystemDrive\Windows.old`"" 2>$null | Out-Null }
            Remove-Item "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue
            # Кэши браузеров (по выбору; пароли/закладки не трогаем)
            if ($Opt.BrowserCache) {
                foreach ($b in @(
                    "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache",
                    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache",
                    "$env:APPDATA\Mozilla\Firefox\Profiles\*\cache2"
                )) { Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue }
            }
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue } catch {}
            try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
            $Status.Text = 'Сжимаю хранилище компонентов Windows (несколько минут)'
            $dism = @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet')
            if ($Opt.ResetBase) { $dism = @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Quiet') }
            & "$env:SystemRoot\System32\Dism.exe" @dism 2>&1 | Out-Null
            # DISM с /Quiet молчит, но код возврата есть — сохраняем для отчёта
            $Status.DismCode = $LASTEXITCODE
        } $argList
        $dismCode = $null
        try { Wait-Task $t | Out-Null; $dismCode = $t.Status.DismCode } catch {}
        if ($null -ne $dismCode -and $dismCode -notin 0, 3010) {
            Report WARN 'Сжатие WinSxS завершилось с замечаниями' "код $dismCode; очистка файлов всё равно выполнена"
        }
        $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
        # int64 до вычитания: FreeSpace — UInt64, в Int32 не влезает и может «обернуться»
        $freed = [int64]$after - [int64]$before
        if ($freed -lt 0) { $freed = 0 }
        Report OK ('Очистка завершена, освобождено {0:N1} ГБ' -f ($freed / 1GB))
    }

    # --- Опция: проверка и починка системных файлов ---
    if ($OptOptions.SfcDism) {
        # Весь блок в try/catch: один шаг (например, недоступная папка под лог) не должен
        # ронять весь прогон через глобальный trap — тогда не будет ни паспорта, ни итога.
        try {
            $Host.UI.RawUI.WindowTitle = 'Проверка системных файлов — это долго, не выключайте'
            $log  = Join-Path $env:TEMP 'dism-restore.log'
            $code = Wait-Task (Start-ProcessTask 'dism' 'Проверяю и чиню образ Windows (DISM /RestoreHealth)' "$env:SystemRoot\System32\Dism.exe" @('/Online', '/Cleanup-Image', '/RestoreHealth') $log)
            if ($code -eq 0) { Report OK 'Образ Windows проверен и исправлен (DISM)' } else { Report WARN 'DISM завершился с замечаниями' "код $code, подробности в логе" }
            $code2 = Wait-Task (Start-ProcessTask 'sfc' 'Проверяю системные файлы (sfc /scannow)' "$env:SystemRoot\System32\sfc.exe" @('/scannow') (Join-Path $env:TEMP 'sfc.log'))
            if ($code2 -eq 0) { Report OK 'Системные файлы проверены (sfc)' } else { Report WARN 'sfc нашёл проблемы или не смог всё починить' "код $code2" }
        } catch { Report WARN 'Проверка системных файлов не выполнена' $_ }
    }
}

# ---------------------------------------------------------------------------
#  Паспорт ПК
# ---------------------------------------------------------------------------
$script:PassportFile = $null
if ($DoPassport) {
    Write-Step 'Паспорт ПК'
    try {
        $script:PassportFile = Write-Passport
        Report OK 'Паспорт ПК сохранён на рабочем столе' (Split-Path $script:PassportFile -Leaf)
    } catch { Report FAIL 'Паспорт ПК не создан' $_ }
}

# ---------------------------------------------------------------------------
#  Подготовка к передаче другому человеку
#  После перезагрузки и вашего входа Windows сама запустит «Первый запуск» (sysprep /oobe)
#  и выключится. Новый владелец при включении сам выберет язык, создаст учётную запись и пароль.
# ---------------------------------------------------------------------------
$script:ClientReady = $false
if ($ClientMode) {
    Write-Step 'Подготовка к передаче другому человеку'
    try {
        $bl = $null
        try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch {}
        if ($bl -and $bl.ProtectionStatus -eq 'On') {
            Report FAIL 'Диск зашифрован BitLocker — подготовка к передаче невозможна' 'отключите шифрование: Параметры -> Конфиденциальность и защита -> Шифрование устройства'
        } else {
            $dir = Join-Path $env:ProgramData 'win11-setup'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            # 1) При следующем входе: запустить sysprep (первый запуск Windows) и выключить ПК
            $prep = Join-Path $dir 'client-prep.ps1'
            Set-Content -Path $prep -Encoding UTF8 -Value @'
$sp = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
$p = Start-Process $sp -ArgumentList '/oobe', '/shutdown', '/quiet' -Wait -PassThru
# При успехе sysprep выходит с кодом 0 и сам выключает ПК. Окно об ошибке показываем
# только при ненулевом коде — иначе пользователь видел пугающую ложную «ошибку»
# (а то и во время выключения).
if ($p.ExitCode -ne 0) {
    Start-Sleep -Seconds 20
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show("Не удалось подготовить компьютер к передаче (код $($p.ExitCode)).`n`nПодробности: $env:SystemRoot\System32\Sysprep\Panther\setuperr.log",
        'Подготовка к передаче', 'OK', 'Error') | Out-Null
}
'@
            Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'W11SetupClientPrep' `
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$prep`"" 'String'
            Report OK 'Первый запуск Windows назначен' 'после перезагрузки войдите — ПК подготовится и выключится сам'

            # 2) После первого входа нового владельца — удалить вашу учётную запись
            $me = [Security.Principal.WindowsIdentity]::GetCurrent()
            $tech = ($me.Name -split '\\')[-1]
            if ($ClientRemoveTechUser -and $me.User.Value -notmatch '-500$') {
                $rm = Join-Path $dir 'remove-tech-user.ps1'
                Set-Content -Path $rm -Encoding UTF8 -Value @"
`$tech = '$tech'
`$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not `$user -or (`$user -split '\\')[-1] -eq `$tech) { exit }
Remove-LocalUser -Name `$tech -ErrorAction SilentlyContinue
Get-CimInstance Win32_UserProfile | Where-Object { `$_.LocalPath -like "*\`$tech" } | Remove-CimInstance -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'W11SetupRemoveTechUser' -Confirm:`$false
Remove-Item '$dir' -Recurse -Force -ErrorAction SilentlyContinue
"@
                $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rm`""
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $trigger.Delay = 'PT1M'
                Register-ScheduledTask -TaskName 'W11SetupRemoveTechUser' -Action $action -Trigger $trigger `
                    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
                Report OK "Ваша учётная запись «$tech» будет удалена после первого входа нового владельца"
            }
            $script:ClientReady = $true
        }
    } catch { Report FAIL 'Подготовка к передаче не выполнена' $_ }
}

# ---------------------------------------------------------------------------
#  Итог
# ---------------------------------------------------------------------------
$ok   = @($Results | Where-Object Status -eq 'OK').Count
$skip = @($Results | Where-Object Status -eq 'SKIP').Count
$warn = @($Results | Where-Object Status -eq 'WARN')
$fail = @($Results | Where-Object Status -eq 'FAIL')

Write-Step 'ИТОГ'
try { [void][SleepBlock]::SetThreadExecutionState([uint32]2147483648) } catch {}   # снова можно спать (0x80000000)
try { $Host.UI.RawUI.WindowTitle = 'Настройка ПК — ГОТОВО' } catch {}
$elapsed = (Get-Date) - $script:StartTime
Write-Host ("Заняло времени:     {0:hh\:mm\:ss}" -f $elapsed)
Write-Host "Успешно:            $ok"          -ForegroundColor Green
Write-Host "Не требовалось:     $skip"        -ForegroundColor DarkGray
Write-Host "Частично:           $($warn.Count)" -ForegroundColor Yellow
Write-Host "Не получилось:      $($fail.Count)" -ForegroundColor Red
Write-Log  "Итог: OK=$ok SKIP=$skip WARN=$($warn.Count) FAIL=$($fail.Count)"

if ($warn.Count -or $fail.Count) {
    Write-Host ''
    Write-Host 'Что не получилось:' -ForegroundColor Red
    foreach ($r in @($fail) + @($warn)) {
        $line = " - $($r.Text)"
        if ($r.Details) { $line += "  ($($r.Details))" }
        Write-Host $line -ForegroundColor $(if ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' })
    }
}

# --- Что сделать руками (понятные действия для пользователя) ---
if ($script:ManualActions.Count) {
    Write-Host ''
    Write-Host 'ЧТО СДЕЛАТЬ РУКАМИ:' -ForegroundColor Cyan
    $mi = 0
    foreach ($m in $script:ManualActions) { $mi++; Write-Host ("  $mi. $m") -ForegroundColor Yellow }
    Write-Log 'Что сделать руками:'
    $mi = 0; foreach ($m in $script:ManualActions) { $mi++; Write-Log "  $mi. $m" }
}

# --- Повторить только неудачные установки ---
$retryable = @($script:FailedInstalls | Where-Object { $_.Kind -in 'winget', 'office' })
if ($retryable.Count -and -not $Offline) {
    Write-Host ''
    Write-Host 'Не установились:' -ForegroundColor Red
    foreach ($f in $retryable) { Write-Host "  - $($f.Name)" -ForegroundColor Yellow }
    $failList = ($retryable | ForEach-Object { " - $($_.Name)" }) -join "`n"
    $ansRetry = [Windows.Forms.MessageBox]::Show("Не установились:`n$failList`n`nПовторить установку только этих программ?", 'WinUP', 'YesNo', 'Warning')
    if ($ansRetry -eq [Windows.Forms.DialogResult]::Yes) {
        # Свежая синхронизация времени и снимок списка (Install-* снова добавит туда неудачи)
        $todo = @($retryable); $script:FailedInstalls.Clear()
        foreach ($f in $todo) {
            if ($f.Kind -eq 'office') { $script:OfficeReady = $true; Invoke-OfficeInstall }
            else { Install-WingetApp $f.Id $f.Name -AllowReinstall:([bool]$f.AllowReinstall) }
        }
        # Пересчёт итога
        $ok   = @($Results | Where-Object Status -eq 'OK').Count
        $skip = @($Results | Where-Object Status -eq 'SKIP').Count
        $warn = @($Results | Where-Object Status -eq 'WARN')
        $fail = @($Results | Where-Object Status -eq 'FAIL')
    }
}

# --- Уборка: скачанные установщики больше не нужны (драйвер NVIDIA ~700 МБ,
#     AMD и офисный установщик лежат в C:\Windows\Temp\win11-setup и копятся между запусками).
#     Файлы офлайн-папки (если работали без интернета) не трогаем.
foreach ($f in @($NvidiaExe, $AmdExe)) {
    if ($f -and (Test-Path $f) -and ($f -notlike "$OfflineDir*")) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
$officeTmp = Join-Path $env:TEMP 'office-setup'
if (Test-Path $officeTmp) { Remove-Item $officeTmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($script:PassportFile) {
    Write-Host ''
    Write-Host "Паспорт ПК: $script:PassportFile" -ForegroundColor Green
    Open-InBrowser $script:PassportFile
}

# --- Отчёт для разбора: лог + стресс-тест + паспорт + сведения о системе одним архивом ---
$bundle = New-ReportBundle
if ($bundle) {
    Write-Host ''
    Write-Host "Отчёт для разбора (один файл, удобно отправить): $bundle" -ForegroundColor Green
}

Write-Host ''
Write-Host "Подробный лог: $LogFile"
Dismount-DefaultUserHive
# Звук окончания — чтобы было слышно, даже если отошли от компьютера
try { (New-Object Media.SoundPlayer "$env:SystemRoot\Media\tada.wav").PlaySync() } catch { try { [console]::Beep(880, 400) } catch {} }

# Закрываем окно прогресса и показываем итог/вопрос про перезагрузку кнопками (а не в консоли)
if ($script:ProgForm) { try { $script:ProgForm.Close(); $script:ProgForm.Dispose() } catch {}; $script:ProgForm = $null }
$sum = "Готово!`n`nУспешно: $ok`nНе требовалось: $skip`nЧастично: $($warn.Count)`nНе получилось: $($fail.Count)"
if ($script:ManualActions.Count) { $sum += "`n`nЧто сделать руками:`n - " + (($script:ManualActions) -join "`n - ") }

if ($script:ClientReady) {
    $m = "$sum`n`nПОДГОТОВКА К ПЕРЕДАЧЕ: после перезагрузки войдите в Windows ещё раз — компьютер сам запустит «Первый запуск» и выключится, после этого его можно отдавать.`n`nПерезагрузить сейчас?"
    if ([Windows.Forms.MessageBox]::Show($m, 'WinUP — готово', 'YesNo', 'Information') -eq 'Yes') { Restart-Computer -Force }
} elseif ($Mode -eq 'stress') {
    [Windows.Forms.MessageBox]::Show($sum, 'WinUP — готово', 'OK', 'Information') | Out-Null
} else {
    $m = "$sum`n`nПерезагрузите компьютер, чтобы все изменения вступили в силу.`n`nПерезагрузить сейчас?"
    if ([Windows.Forms.MessageBox]::Show($m, 'WinUP — готово', 'YesNo', 'Information') -eq 'Yes') { Restart-Computer -Force }
}
