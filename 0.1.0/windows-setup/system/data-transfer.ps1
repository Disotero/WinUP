#Requires -Version 5.1
<#
    Перенос данных — отдельная программа (запуск: «Перенос данных.bat»).

    Вкладки:
      1. Сохранить      — личные файлы, закладки браузеров, сохранения игр, Telegram, Wi-Fi,
                          сетевые диски и принтеры и т.д. Копия проверяется, пишется отчёт;
                          можно докопировать только новое в прошлую копию.
                          на флешку или другой диск. Структура:
                          <папка>\Перенос данных\<Имя пользователя>\<дата_время>\<Категория>\...
      2. Восстановить   — вернуть сохранённое на этот (например, переустановленный) компьютер.
      3. Игры Steam     — найти библиотеки Steam на других дисках и подключить их к Steam,
                          чтобы после переустановки ничего не перекачивать.
      4. Папки на другой диск — перенести Рабочий стол, Документы, Загрузки и т.д. на D:\,
                          чтобы при следующей переустановке ничего не терялось.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
#  Права администратора (нужны для Wi-Fi-профилей и копирования системных папок)
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    } catch {
        Write-Host 'Нужны права администратора: в окне Windows нажмите «Да».' -ForegroundColor Red
        Read-Host 'Нажмите Enter, чтобы закрыть' | Out-Null
    }
    exit
}

# Прячем консольное окно — это графическая программа, консоль пользователю не нужна
if (-not ('ConHideDT' -as [type])) {
    Add-Type -Namespace '' -Name 'ConHideDT' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
}
try { [void][ConHideDT]::ShowWindow([ConHideDT]::GetConsoleWindow(), 0) } catch {}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
#  Операции. Этот код выполняется в фоновом потоке (чтобы окно не зависало),
#  поэтому он оформлен текстом и подключается туда целиком.
#  Сообщения в окно: Say 'OK'|'SKIP'|'WARN'|'FAIL'|'INFO' 'текст'
# ---------------------------------------------------------------------------
$OpsCode = {
    # =======================================================================
    #  НАСТРОЙКИ — меняйте здесь
    # =======================================================================
    # Сохранения игр вне «Документов». Base: USERPROFILE, APPDATA (Roaming), LOCALAPPDATA (Local),
    # LOCALLOW (AppData\LocalLow), DOCUMENTS, PROGRAMFILESX86. Копируется только то, что есть на ПК.
    # Многие игры Steam, Epic и др. и так хранят сохранения в облаке.
    $GameSaves = @(
        @{ Game = 'Все игры с папкой Saved Games';      Base = 'USERPROFILE';  Rel = 'Saved Games' }
        @{ Game = 'Игры в Документах\My Games';        Base = 'DOCUMENTS';    Rel = 'My Games' }
        @{ Game = 'Игры в Документах\Saved Games';     Base = 'DOCUMENTS';    Rel = 'Saved Games' }
        @{ Game = 'GTA V';                              Base = 'DOCUMENTS';    Rel = 'Rockstar Games\GTA V\Profiles' }
        @{ Game = 'Red Dead Redemption 2';              Base = 'DOCUMENTS';    Rel = 'Rockstar Games\Red Dead Redemption 2\Profiles' }
        @{ Game = 'The Witcher 3';                      Base = 'DOCUMENTS';    Rel = 'The Witcher 3\gamesaves' }
        @{ Game = 'Paradox (EU4, HoI4, CK3, Stellaris)'; Base = 'DOCUMENTS';   Rel = 'Paradox Interactive' }
        @{ Game = 'Elden Ring';                         Base = 'APPDATA';      Rel = 'EldenRing' }
        @{ Game = 'Dark Souls III';                     Base = 'APPDATA';      Rel = 'DarkSoulsIII' }
        @{ Game = 'Sekiro';                             Base = 'APPDATA';      Rel = 'Sekiro' }
        @{ Game = 'Stardew Valley';                     Base = 'APPDATA';      Rel = 'StardewValley\Saves' }
        @{ Game = 'Minecraft (миры)';                   Base = 'APPDATA';      Rel = '.minecraft\saves' }
        @{ Game = 'Factorio';                           Base = 'APPDATA';      Rel = 'Factorio\saves' }
        @{ Game = "Baldur's Gate 3";                    Base = 'LOCALAPPDATA'; Rel = 'Larian Studios' }
        @{ Game = 'Satisfactory';                       Base = 'LOCALAPPDATA'; Rel = 'FactoryGame\Saved\SaveGames' }
        @{ Game = 'Palworld';                           Base = 'LOCALAPPDATA'; Rel = 'Pal\Saved\SaveGames' }
        @{ Game = 'Hollow Knight';                      Base = 'LOCALLOW';     Rel = 'Team Cherry' }
        @{ Game = 'Valheim';                            Base = 'LOCALLOW';     Rel = 'IronGate' }
        @{ Game = 'Subnautica';                         Base = 'LOCALLOW';     Rel = 'Unknown Worlds' }
        @{ Game = 'Игры Ubisoft Connect';               Base = 'PROGRAMFILESX86'; Rel = 'Ubisoft\Ubisoft Game Launcher\savegames' }
    )

    # Что не копировать при сохранении: кэши, временные и восстановимые папки (по имени, на любой глубине)
    $ExcludeDirs  = @('node_modules', '__pycache__', '.cache', 'Cache', 'Code Cache', 'GPUCache', 'cache2',
                      'Temp', 'tmp', '.venv', 'venv', '$RECYCLE.BIN', 'System Volume Information')
    $ExcludeFiles = @('*.tmp', '~$*', 'Thumbs.db', '*.crdownload', '*.part', '*.partial')
    # =======================================================================

    function Say([string]$Status, [string]$Text) { [void]$Shared.Log.Add("$Status|$Text") }
    # Внешняя программа без исключений из-за вывода в stderr (особенность PowerShell 5.1)
    function Invoke-Native([string]$Exe) { $ErrorActionPreference = 'Continue'; & $Exe @args 2>&1 | Out-Null }
    function Set-State([string]$Text) { $Shared.State = $Text }

    # Что сохраняем. Kind: Folder — папка целиком; Items — отдельные файлы/папки; Special — своя логика.
    function Get-Categories {
        $home_ = $env:USERPROFILE
        $docs  = [Environment]::GetFolderPath('MyDocuments')
        @(
            [pscustomobject]@{ Key = 'Desktop';   Name = 'Рабочий стол'; Kind = 'Folder'; Path = [Environment]::GetFolderPath('Desktop'); Default = $true }
            [pscustomobject]@{ Key = 'Documents'; Name = 'Документы';    Kind = 'Folder'; Path = $docs; Default = $true }
            [pscustomobject]@{ Key = 'Pictures';  Name = 'Изображения';  Kind = 'Folder'; Path = [Environment]::GetFolderPath('MyPictures'); Default = $true }
            [pscustomobject]@{ Key = 'Videos';    Name = 'Видео';        Kind = 'Folder'; Path = [Environment]::GetFolderPath('MyVideos'); Default = $true }
            [pscustomobject]@{ Key = 'Music';     Name = 'Музыка';       Kind = 'Folder'; Path = [Environment]::GetFolderPath('MyMusic'); Default = $true }
            [pscustomobject]@{ Key = 'Downloads'; Name = 'Загрузки';     Kind = 'Folder'; Path = (Get-DownloadsPath); Default = $false }
            [pscustomobject]@{ Key = 'Browsers';  Name = 'Закладки браузеров (Chrome, Edge, Яндекс, Opera) и Firefox целиком'; Kind = 'Items'; Items = (Get-BrowserItems); Default = $true }
            [pscustomobject]@{ Key = 'Games';     Name = 'Сохранения игр'; Kind = 'Items'; Default = $true; Items = $GameSaves }
            [pscustomobject]@{ Key = 'Telegram';  Name = 'Telegram (вход без кода, без кэша)'; Kind = 'Items'; Default = $true; Items = @(
                @{ Base = 'APPDATA'; Rel = 'Telegram Desktop\tdata'; Exclude = @('user_data', 'user_data#*', 'emoji', 'dumps', 'temp') }
            ) }
            [pscustomobject]@{ Key = 'Ssh';       Name = 'Ключи SSH (.ssh)'; Kind = 'Items'; Default = $true; Items = @(@{ Base = 'USERPROFILE'; Rel = '.ssh' }) }
            [pscustomobject]@{ Key = 'Wifi';      Name = 'Сети Wi-Fi с паролями'; Kind = 'Special'; Default = $true }
            [pscustomobject]@{ Key = 'Network';   Name = 'Сетевые диски и принтеры'; Kind = 'Special'; Default = $true }
            [pscustomobject]@{ Key = 'Apps';      Name = 'Список установленных программ'; Kind = 'Special'; Default = $true }
        )
    }

    function Get-DownloadsPath {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($p) { [Environment]::ExpandEnvironmentVariables($p) } else { Join-Path $env:USERPROFILE 'Downloads' }
    }

    function Resolve-Base([string]$Base) {
        switch ($Base) {
            'USERPROFILE'  { $env:USERPROFILE }
            'APPDATA'      { $env:APPDATA }
            'LOCALAPPDATA' { $env:LOCALAPPDATA }
            'DOCUMENTS'    { [Environment]::GetFolderPath('MyDocuments') }
            'LOCALLOW'     { Join-Path $env:USERPROFILE 'AppData\LocalLow' }
            'PROGRAMFILESX86' { ${env:ProgramFiles(x86)} }
        }
    }

    # Закладки Chromium-браузеров (каждый профиль) и профиль Firefox целиком.
    # Пароли Chrome/Edge/Яндекса привязаны к Windows и на новой системе не расшифруются —
    # их переносят через синхронизацию аккаунта браузера или экспорт паролей в самом браузере.
    function Get-BrowserItems {
        $items = @()
        $chromium = @(
            @{ Base = 'LOCALAPPDATA'; Rel = 'Google\Chrome\User Data' }
            @{ Base = 'LOCALAPPDATA'; Rel = 'Microsoft\Edge\User Data' }
            @{ Base = 'LOCALAPPDATA'; Rel = 'Yandex\YandexBrowser\User Data' }
        )
        foreach ($b in $chromium) {
            $root = Join-Path (Resolve-Base $b.Base) $b.Rel
            foreach ($bm in Get-ChildItem $root -Filter 'Bookmarks' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue) {
                $items += @{ Base = $b.Base; Rel = $bm.FullName.Substring((Resolve-Base $b.Base).Length + 1) }
            }
        }
        $opera = Join-Path $env:APPDATA 'Opera Software\Opera Stable\Bookmarks'
        if (Test-Path $opera) { $items += @{ Base = 'APPDATA'; Rel = 'Opera Software\Opera Stable\Bookmarks' } }
        if (Test-Path (Join-Path $env:APPDATA 'Mozilla\Firefox')) {
            $items += @{ Base = 'APPDATA'; Rel = 'Mozilla\Firefox' }
        }
        return $items
    }

    function Get-SizeBytes([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        $i = Get-Item -LiteralPath $Path -Force
        if (-not $i.PSIsContainer) { return $i.Length }
        $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($s) { $s } else { 0 }
    }

    # Полный путь элемента или $null, если базовой папки на этом ПК нет
    function Resolve-Item($It) {
        $b = Resolve-Base $It.Base
        if ($b) { Join-Path $b $It.Rel }
    }

    function Get-CategorySize($c) {
        switch ($c.Kind) {
            'Folder' { if ($c.Path) { Get-SizeBytes $c.Path } else { 0 } }
            'Items'  { ($c.Items | ForEach-Object { $p = Resolve-Item $_; if ($p) { Get-SizeBytes $p } } | Measure-Object -Sum).Sum }
            default  { 0 }
        }
    }

    # Аргументы robocopy с исключениями: $Skip — дополнительные папки (например, кэш Telegram).
    # $UseExcludes — применять общие исключения (при сохранении — да, при восстановлении не нужно)
    # $Quote: $true — пути в кавычках, для Start-Process -ArgumentList (Copy-Tree);
    #         $false — сырые строки, для прямого вызова & robocopy. PS 5.1 закавычивает
    #         аргументы со пробелами сам (ровно один раз); если передать уже закавыченные,
    #         получается ""путь"" — robocopy разбирает его в мусорный путь + маску, и пробный
    #         прогон проверки копии (Test-TreeCopy) ничего не находит → ложное «всё проверено».
    function Get-RoboArgs([string]$From, [string]$To, [string[]]$Skip, [bool]$UseExcludes, [bool]$Quote = $true) {
        $a = if ($Quote) { @("`"$From`"", "`"$To`"") } else { @($From, $To) }
        $a += @('/E', '/R:1', '/W:1', '/XJ', '/NP', '/NJH', '/NJS')
        $dirs = @($Skip | Where-Object { $_ })
        if ($UseExcludes) { $dirs += $ExcludeDirs }
        if ($dirs) { $a += '/XD'; $a += $dirs | ForEach-Object { if ($Quote) { "`"$_`"" } else { $_ } } }
        if ($UseExcludes -and $ExcludeFiles) { $a += '/XF'; $a += $ExcludeFiles | ForEach-Object { if ($Quote) { "`"$_`"" } else { $_ } } }
        return $a
    }

    # Копирование папки через встроенный robocopy (быстро, надёжно, с повтором при ошибках).
    # Уже скопированные и не изменившиеся файлы пропускаются — так работает докопирование.
    function Copy-Tree([string]$From, [string]$To, [string[]]$Skip = @(), [switch]$KeepNewer, [switch]$NoExcludes) {
        $a = (Get-RoboArgs $From $To $Skip (-not $NoExcludes)) + @('/MT:8', '/NFL', '/NDL', '/COPY:DAT', '/DCOPY:T')
        if ($KeepNewer) { $a += '/XO' }
        $p = Start-Process "$env:SystemRoot\System32\robocopy.exe" -ArgumentList $a -WindowStyle Hidden -Wait -PassThru
        return ($p.ExitCode -lt 8)   # robocopy: 0-7 — успех, 8 и выше — ошибки
    }

    # Проверка копии: сколько файлов из источника отсутствует в копии или отличается от неё
    # (пробный прогон robocopy без копирования). Возвращает список таких файлов.
    function Test-TreeCopy([string]$From, [string]$To, [string[]]$Skip = @()) {
        # /XX — не учитывать файлы, которые есть только в копии (например, удалённые с ПК после прошлого сохранения)
        # Сырые пути ($Quote=$false): при прямом вызове & robocopy кавычит сам
        $a = (Get-RoboArgs $From $To $Skip $true $false) + @('/L', '/XX', '/NDL', '/NC', '/NS', '/FP')
        $ErrorActionPreference = 'Continue'
        @(& "$env:SystemRoot\System32\robocopy.exe" @a 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    }

    function Get-FileCount([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return 0 }
        if (-not (Get-Item -LiteralPath $Path -Force).PSIsContainer) { return 1 }
        @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }

    function Copy-Item1([string]$From, [string]$To, [string[]]$Skip = @(), [switch]$KeepNewer, [switch]$NoExcludes) {
        if ((Get-Item -LiteralPath $From -Force).PSIsContainer) { return (Copy-Tree $From $To $Skip -KeepNewer:$KeepNewer -NoExcludes:$NoExcludes) }
        New-Item -ItemType Directory -Path (Split-Path $To) -Force | Out-Null
        if ($KeepNewer -and (Test-Path -LiteralPath $To) -and (Get-Item -LiteralPath $To).LastWriteTime -gt (Get-Item -LiteralPath $From).LastWriteTime) { return $true }
        Copy-Item -LiteralPath $From -Destination $To -Force
        return $true
    }

    # Удаление содержимого папки БЕЗ захода внутрь junction/символических ссылок.
    # PS 5.1 Remove-Item -Recurse рекурсирует сквозь reparse point (исправлено только в PS 6.1)
    # и стирает содержимое ЦЕЛИ ссылки — вне переносимой папки. Здесь точки соединения удаляются
    # как ссылки (цель не трогаем), в обычные папки заходим рекурсией. Саму $Path не удаляем.
    function Remove-TreeNoJunction([string]$Path) {
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) }
                    else { [IO.File]::Delete($item.FullName) }
                } elseif ($item.PSIsContainer) {
                    Remove-TreeNoJunction $item.FullName
                    [IO.Directory]::Delete($item.FullName, $false)
                } else {
                    if ($item.IsReadOnly) { $item.IsReadOnly = $false }
                    [IO.File]::Delete($item.FullName)
                }
            } catch { }   # остатки в старой папке некритичны: перенос уже состоялся (SHSetKnownFolderPath)
        }
    }

    function Format-Size($b) { if ($b -ge 1GB) { '{0:N1} ГБ' -f ($b / 1GB) } else { '{0:N0} МБ' -f ($b / 1MB) } }

    # ---------------- Сохранение ----------------
    # $Update — докопировать в последнюю копию этого пользователя (только новое и изменённое)
    function Invoke-Backup([string]$Target, [string[]]$Keys, [bool]$Update) {
        $stamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm'
        $userDir = Join-Path $Target "Перенос данных\$env:USERNAME"
        $root = Join-Path $userDir $stamp
        $old = $null
        if ($Update) {
            $old = Get-ChildItem $userDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending | Select-Object -First 1
        }
        if ($old) {
            # Папку прошлой копии переименовываем в текущую дату и докопируем в неё
            if ($old.Name -ne $stamp) { Rename-Item $old.FullName $stamp }
            Say 'INFO' "Докопирую в прошлую копию от $($old.Name) — только новое и изменённое"
        } else {
            if ($Update) { Say 'INFO' 'Прошлой копии нет — делаю полную' }
            New-Item -ItemType Directory -Path $root -Force | Out-Null
        }
        Say 'INFO' "Сохраняю в: $root"
        $manifest = [ordered]@{ User = $env:USERNAME; Computer = $env:COMPUTERNAME; Date = (Get-Date -Format 's'); Categories = @() }
        $prevCats = @()
        if ($old) {
            try { $prevCats = @((Get-Content (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Categories) } catch {}
        }
        $report = New-Object System.Collections.Generic.List[string]
        $report.Add("Сохранение: $env:USERNAME, компьютер $env:COMPUTERNAME, $(Get-Date -Format 'dd.MM.yyyy HH:mm')")
        $report.Add("Папка: $root"); $report.Add('')

        $cats = Get-Categories | Where-Object { $_.Key -in $Keys }
        $i = 0
        foreach ($c in $cats) {
            $i++
            Set-State "Сохраняю ($i из $($cats.Count)): $($c.Name)"
            $dest = Join-Path $root $c.Name.Split('(')[0].Trim()
            $entry = [ordered]@{ Key = $c.Key; Folder = (Split-Path $dest -Leaf); Items = @() }
            try {
                $missing = @()
                $saved = $true
                if ($c.Kind -eq 'Folder') {
                    if (-not $c.Path -or -not (Test-Path -LiteralPath $c.Path)) { Say 'SKIP' "$($c.Name) — папки нет"; continue }
                    # Папка перенаправлена в OneDrive: /COPY:DAT читает каждый «только в облаке»
                    # placeholder и тянет его на (обычно маленькую) флешку — часы «зависания» и
                    # переполнение. Эти файлы и так в облаке — пропускаем (как в Move-UserFolders).
                    if ($c.Path -match 'OneDrive') { Say 'SKIP' "$($c.Name) — папка в OneDrive, файлы уже в облаке (на флешку не копирую)"; continue }
                    [void](Copy-Tree $c.Path $dest)
                    Set-State "Проверяю копию: $($c.Name)"
                    $missing = Test-TreeCopy $c.Path $dest
                } elseif ($c.Kind -eq 'Items') {
                    $n = 0
                    foreach ($it in $c.Items) {
                        $src = Resolve-Item $it
                        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
                        $to = Join-Path $dest (Join-Path $it.Base $it.Rel)
                        [void](Copy-Item1 $src $to $it.Exclude)
                        $n++; $entry.Items += @{ Base = $it.Base; Rel = $it.Rel }
                        if ((Get-Item -LiteralPath $src -Force).PSIsContainer) { $missing += Test-TreeCopy $src $to $it.Exclude }
                        elseif (-not (Test-Path -LiteralPath $to)) { $missing += $src }
                    }
                    if (-not $n) { Say 'SKIP' "$($c.Name) — нечего сохранять"; $saved = $false }
                } else {
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null
                    switch ($c.Key) {
                        'Wifi' {
                            Invoke-Native "$env:SystemRoot\System32\netsh.exe" wlan export profile key=clear "folder=$dest"
                            $cnt = @(Get-ChildItem $dest -Filter '*.xml' -ErrorAction SilentlyContinue).Count
                            if ($cnt) { Say 'OK' "Сети Wi-Fi — сохранено $cnt (пароли внутри открытым текстом — храните копию бережно)"; $report.Add("[ OK ] Сети Wi-Fi: $cnt") }
                            else { Say 'SKIP' 'Сети Wi-Fi — сохранённых сетей нет'; $saved = $false }
                        }
                        'Network' {
                            # Сетевые диски пользователя (постоянные подключения) и сетевые принтеры
                            $drives = @(Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue | ForEach-Object {
                                [pscustomobject]@{ Letter = $_.PSChildName; Path = (Get-ItemProperty $_.PSPath).RemotePath }
                            } | Where-Object { $_.Path })
                            $printers = @()
                            try { $printers = @(Get-Printer -ErrorAction Stop | Select-Object Name, Type, DriverName, PortName) } catch {}
                            [pscustomobject]@{ Drives = $drives; Printers = $printers } | ConvertTo-Json -Depth 4 |
                                Set-Content (Join-Path $dest 'сеть.json') -Encoding UTF8
                            $net = @($printers | Where-Object { $_.Type -eq 'Connection' })
                            $loc = @($printers | Where-Object { $_.Type -ne 'Connection' -and $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS' })
                            if ($drives -or $net -or $loc) {
                                Say 'OK' "Сетевые диски: $($drives.Count), сетевые принтеры: $($net.Count), локальные принтеры (только список): $($loc.Count)"
                                $report.Add("[ OK ] Сетевые диски: $(($drives | ForEach-Object { "$($_.Letter): $($_.Path)" }) -join ', ')")
                                $report.Add("[ OK ] Принтеры: $(($printers | ForEach-Object { $_.Name }) -join ', ')")
                            } else { Say 'SKIP' 'Сетевых дисков и принтеров нет'; $saved = $false }
                        }
                        'Apps' {
                            $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                            Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                                Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
                                Sort-Object DisplayName -Unique |
                                ForEach-Object { "$($_.DisplayName)`t$($_.DisplayVersion)`t$($_.Publisher)" } |
                                Set-Content (Join-Path $dest 'программы.txt') -Encoding UTF8
                            if (Get-Command winget -ErrorAction SilentlyContinue) {
                                Invoke-Native 'winget' export -o (Join-Path $dest 'winget.json') --accept-source-agreements
                            }
                            Say 'OK' 'Список программ сохранён (программы.txt; winget.json — для установки одной командой)'
                            $report.Add('[ OK ] Список программ')
                        }
                    }
                }
                if ($c.Kind -in 'Folder', 'Items' -and $saved) {
                    $files = Get-FileCount $dest; $size = Format-Size (Get-SizeBytes $dest)
                    if ($missing) {
                        Say 'WARN' "$($c.Name) — сохранено $files файлов ($size), но $($missing.Count) не скопировано (заняты другой программой?) — список в отчёте"
                        $report.Add("[ !! ] $($c.Name): $files файлов, $size; НЕ скопировано: $($missing.Count)")
                        $missing | Select-Object -First 200 | ForEach-Object { $report.Add("         $_") }
                    } else {
                        Say 'OK' "$($c.Name) — сохранено и проверено: $files файлов, $size"
                        $report.Add("[ OK ] $($c.Name): $files файлов, $size — проверено")
                    }
                }
                if ($saved) { $manifest.Categories += $entry }
            } catch { Say 'FAIL' "$($c.Name) — ошибка: $($_.Exception.Message)"; $report.Add("[FAIL] $($c.Name): $($_.Exception.Message)") }
        }
        # Категории из прошлой копии, которые в этот раз не выбирали, остаются в ней
        foreach ($pc in $prevCats) {
            if ($pc.Key -notin @($manifest.Categories | ForEach-Object { $_.Key })) { $manifest.Categories += $pc }
        }
        $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'manifest.json') -Encoding UTF8
        $report.Add(''); $report.Add("Всего в копии: $(Format-Size (Get-SizeBytes $root))")
        $report | Set-Content (Join-Path $root 'отчёт.txt') -Encoding UTF8
        Say 'OK' "Готово. Всего в копии: $(Format-Size (Get-SizeBytes $root)). Отчёт: отчёт.txt в папке копии"
        Set-State 'Сохранение завершено'
    }

    # ---------------- Восстановление ----------------
    function Invoke-Restore([string]$Root, [string[]]$Keys) {
        $m = Get-Content (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $cats = Get-Categories
        # Браузеры и Telegram перезапишут свои файлы при закрытии — закрываем их
        foreach ($p in 'chrome', 'msedge', 'browser', 'opera', 'firefox', 'Telegram') {
            Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        $sel = @($m.Categories | Where-Object { $_.Key -in $Keys })
        $i = 0
        foreach ($e in $sel) {
            $i++
            $c = $cats | Where-Object { $_.Key -eq $e.Key } | Select-Object -First 1
            $name = if ($c) { $c.Name } else { $e.Key }
            Set-State "Восстанавливаю ($i из $($sel.Count)): $name"
            $src = Join-Path $Root $e.Folder
            try {
                if (-not (Test-Path -LiteralPath $src)) { Say 'SKIP' "$name — в копии нет"; continue }
                if ($c.Kind -eq 'Folder') {
                    $ok = Copy-Tree $src $c.Path -KeepNewer -NoExcludes
                    if ($ok) { Say 'OK' "$name — восстановлено в $($c.Path)" } else { Say 'WARN' "$name — часть файлов не восстановлена" }
                } elseif ($e.Key -eq 'Wifi') {
                    $n = 0
                    foreach ($x in Get-ChildItem $src -Filter '*.xml') {
                        Invoke-Native "$env:SystemRoot\System32\netsh.exe" wlan add profile "filename=$($x.FullName)" user=all
                        if ($LASTEXITCODE -eq 0) { $n++ }
                    }
                    if ($n) { Say 'OK' "Сети Wi-Fi — добавлено $n" } else { Say 'WARN' 'Сети Wi-Fi не добавлены (нет Wi-Fi-адаптера?)' }
                } elseif ($e.Key -eq 'Network') {
                    $net = Get-Content (Join-Path $src 'сеть.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($d in @($net.Drives)) {
                        # Постоянное подключение пользователя: Windows подключит диск при следующем входе
                        $k = "HKCU:\Network\$($d.Letter)"
                        if (Test-Path $k) { Say 'SKIP' "Диск $($d.Letter): уже подключён"; continue }
                        New-Item $k -Force | Out-Null
                        New-ItemProperty $k -Name RemotePath     -Value $d.Path -PropertyType String -Force | Out-Null
                        New-ItemProperty $k -Name UserName       -Value 0 -PropertyType DWord -Force | Out-Null
                        New-ItemProperty $k -Name ProviderName   -Value 'Microsoft Windows Network' -PropertyType String -Force | Out-Null
                        New-ItemProperty $k -Name ProviderType   -Value 0x20000 -PropertyType DWord -Force | Out-Null
                        New-ItemProperty $k -Name ConnectionType -Value 1 -PropertyType DWord -Force | Out-Null
                        New-ItemProperty $k -Name DeferFlags     -Value 4 -PropertyType DWord -Force | Out-Null
                        Say 'OK' "Сетевой диск $($d.Letter): $($d.Path) — подключится при следующем входе в Windows"
                    }
                    foreach ($pr in @($net.Printers | Where-Object { $_.Type -eq 'Connection' })) {
                        try { Add-Printer -ConnectionName $pr.Name -ErrorAction Stop; Say 'OK' "Принтер $($pr.Name) подключён" }
                        catch { Say 'WARN' "Принтер $($pr.Name) не подключён (сервер недоступен?)" }
                    }
                    $loc = @($net.Printers | Where-Object { $_.Type -ne 'Connection' -and $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS' })
                    if ($loc) { Say 'INFO' ('Локальные принтеры (подключите и поставьте драйвер вручную): ' + (($loc | ForEach-Object { $_.Name }) -join ', ')) }
                } elseif ($e.Key -eq 'Apps') {
                    Say 'INFO' "Список программ: $(Join-Path $src 'программы.txt')"
                    if ((Test-Path (Join-Path $src 'winget.json')) -and $Shared.InstallApps) {
                        Set-State 'Устанавливаю программы из списка (winget), это может быть долго'
                        Invoke-Native 'winget' import -i (Join-Path $src 'winget.json') --accept-package-agreements --accept-source-agreements --ignore-unavailable
                        Say 'OK' 'Программы из списка установлены (те, что нашлись в winget)'
                    }
                } else {
                    $n = 0
                    foreach ($it in $e.Items) {
                        $from = Join-Path $src (Join-Path $it.Base $it.Rel)
                        $to   = Resolve-Item $it
                        if ($to -and (Test-Path -LiteralPath $from)) { if (Copy-Item1 $from $to -KeepNewer -NoExcludes) { $n++ } }
                    }
                    if ($n) { Say 'OK' "$name — восстановлено" } else { Say 'SKIP' "$name — нечего восстанавливать" }
                    if ($e.Key -eq 'Browsers') { Say 'INFO' 'Пароли Chrome/Edge/Яндекса переносятся через вход в аккаунт браузера или его экспорт паролей' }
                }
            } catch { Say 'FAIL' "$name — ошибка: $($_.Exception.Message)" }
        }
        Say 'OK' 'Восстановление завершено'
        Set-State 'Восстановление завершено'
    }

    # ---------------- Игры Steam ----------------
    function Get-SteamPath {
        $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        if ($p) { return ($p -replace '/', '\') }
        foreach ($c in "${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam") { if (Test-Path $c) { return $c } }
    }

    # Ищет на всех дисках папки с играми Steam (в корне диска и на уровень глубже)
    function Find-SteamLibraries {
        $steam = Get-SteamPath
        $found = @()
        foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
            $roots = @("$($d.DeviceID)\") + @(Get-ChildItem "$($d.DeviceID)\" -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin 'Windows', '$Recycle.Bin', 'System Volume Information', 'Users', 'ProgramData', 'Recovery' } |
                ForEach-Object { $_.FullName })
            foreach ($r in $roots) {
                foreach ($cand in @($r) + @(Get-ChildItem $r -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
                    $apps = Join-Path $cand 'steamapps'
                    if ((Test-Path $apps) -and (Get-ChildItem $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                        $full = (Resolve-Path $cand).Path.TrimEnd('\')
                        if ($steam -and $full -eq $steam.TrimEnd('\')) { continue }
                        $found += $full
                    }
                }
            }
        }
        $found | Select-Object -Unique
    }

    function Add-SteamLibraries {
        $steam = Get-SteamPath
        if (-not $steam) { Say 'FAIL' 'Steam не установлен'; return }
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path $vdf)) { Say 'FAIL' 'Steam ещё ни разу не запускался: запустите его, войдите в аккаунт, закройте и повторите'; return }
        Set-State 'Ищу игры Steam на дисках'
        $libs = @(Find-SteamLibraries)
        if (-not $libs) { Say 'SKIP' 'Папок с играми Steam на других дисках не найдено'; return }

        $text = Get-Content $vdf -Raw -Encoding UTF8
        $known = @([regex]::Matches($text, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
        $new = @($libs | Where-Object { $_ -notin $known })
        foreach ($l in $libs | Where-Object { $_ -in $known }) { Say 'SKIP' "$l — уже подключена" }
        if (-not $new) { return }

        Get-Process steam -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Copy-Item $vdf "$vdf.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
        $idx = @([regex]::Matches($text, '(?m)^\t"(\d+)"\s*$') | ForEach-Object { [int]$_.Groups[1].Value })
        $next = if ($idx) { ($idx | Measure-Object -Maximum).Maximum + 1 } else { 1 }
        $blocks = ''
        foreach ($l in $new) {
            $apps = Get-ChildItem (Join-Path $l 'steamapps') -Filter 'appmanifest_*.acf'
            $appLines = ($apps | ForEach-Object {
                $id = $_.BaseName -replace '^appmanifest_', ''
                $size = if ((Get-Content $_.FullName -Raw) -match '"SizeOnDisk"\s+"(\d+)"') { $Matches[1] } else { '0' }
                "`t`t`t`"$id`"`t`t`"$size`""
            }) -join "`n"
            $cid = '0'
            $own = Join-Path $l 'libraryfolder.vdf'
            if ((Test-Path $own) -and ((Get-Content $own -Raw) -match '"contentid"\s+"(\d+)"')) { $cid = $Matches[1] }
            $blocks += "`t`"$next`"`n`t{`n`t`t`"path`"`t`t`"$($l -replace '\\', '\\')`"`n`t`t`"label`"`t`t`"`"`n" +
                       "`t`t`"contentid`"`t`t`"$cid`"`n`t`t`"totalsize`"`t`t`"0`"`n`t`t`"update_clean_bytes_tally`"`t`t`"0`"`n" +
                       "`t`t`"time_last_update_verified`"`t`t`"0`"`n`t`t`"apps`"`n`t`t{`n$appLines`n`t`t}`n`t}`n"
            Say 'OK' "$l — подключена ($(@($apps).Count) игр)"
            $next++
        }
        # Вставляем новые библиотеки перед последней закрывающей скобкой файла
        $pos = $text.LastIndexOf('}')
        $text = $text.Substring(0, $pos) + $blocks + $text.Substring($pos)
        [IO.File]::WriteAllText($vdf, $text, (New-Object Text.UTF8Encoding $false))
        Say 'INFO' 'Запустите Steam: игры появятся в библиотеке, Steam только проверит файлы, без скачивания'
        Set-State 'Игры Steam подключены'
    }

    # ---------------- Папки пользователя на другой диск ----------------
    function Move-UserFolders([string]$Drive, [string[]]$Keys) {
        $ids = @{
            Desktop   = 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641'
            Documents = 'FDD39AD0-238F-46AF-ADB4-6C85480369C7'
            Downloads = '374DE290-123F-4565-9164-39C4925E467B'
            Pictures  = '33E28130-4E1E-4676-835A-98395C3BC3BB'
            Videos    = '18989B1D-99B5-455B-841C-AB7C74E4DDFC'
            Music     = '4BD8D571-6D19-48D3-BE97-422220080E43'
        }
        if (-not ('KnownFolders' -as [type])) {
            Add-Type -Namespace '' -Name 'KnownFolders' -MemberDefinition @'
[DllImport("shell32.dll")] public static extern int SHSetKnownFolderPath(ref Guid rfid, uint dwFlags, IntPtr hToken, [MarshalAs(UnmanagedType.LPWStr)] string pszPath);
'@
        }
        $cats = Get-Categories | Where-Object { $_.Key -in $Keys }
        $i = 0
        foreach ($c in $cats) {
            $i++
            Set-State "Переношу ($i из $($cats.Count)): $($c.Name)"
            $leaf = Split-Path $c.Path -Leaf
            $to = Join-Path "$($Drive.TrimEnd('\'))\" "Users\$env:USERNAME\$leaf"
            try {
                if ($c.Path -like "$($Drive.TrimEnd('\'))*") { Say 'SKIP' "$($c.Name) — уже на диске $Drive"; continue }
                if ($c.Path -match 'OneDrive') { Say 'SKIP' "$($c.Name) — в OneDrive, не трогаю"; continue }
                New-Item -ItemType Directory -Path $to -Force | Out-Null
                # -NoExcludes: перенос обязан быть полным. С общими исключениями (Cache, Temp,
                # node_modules, *.tmp…) часть файлов не копировалась, а старая папка ниже удаляется
                # целиком — так пропущенные копией файлы терялись безвозвратно.
                if (-not (Copy-Tree $c.Path $to -NoExcludes)) { Say 'FAIL' "$($c.Name) — не все файлы скопировались, папка не перенесена"; continue }
                $g = [Guid]$ids[$c.Key]
                $hr = [KnownFolders]::SHSetKnownFolderPath([ref]$g, 0, [IntPtr]::Zero, $to)
                if ($hr -ne 0) { Say 'FAIL' ("$($c.Name) — Windows не приняла новый путь (0x{0:X8}), файлы скопированы в $to" -f $hr); continue }
                # Старую папку чистим только после успешного копирования и переключения.
                # Через Remove-TreeNoJunction — чтобы Remove-Item не прошёл сквозь junction и
                # не стёр содержимое цели вне переносимой папки.
                Remove-TreeNoJunction $c.Path
                Say 'OK' "$($c.Name) — теперь в $to"
            } catch { Say 'FAIL' "$($c.Name) — ошибка: $($_.Exception.Message)" }
        }
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        Say 'INFO' 'Проводник перезапущен. Если что-то не обновилось — выйдите из системы и войдите снова.'
        Set-State 'Перенос папок завершён'
    }
}
. $OpsCode

# ---------------------------------------------------------------------------
#  Фоновое выполнение с выводом в окно
# ---------------------------------------------------------------------------
$Shared = [hashtable]::Synchronized(@{ Log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList)); State = ''; Busy = $false; InstallApps = $false })

# $Command использует аргументы как $A и $B
function Start-Op([string]$Command, [object[]]$ArgumentList = @()) {
    if ($Shared.Busy) { return }
    $Shared.Busy = $true
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Shared', $Shared)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript("param(`$A, `$B)`n. { $OpsCode }`n`$ErrorActionPreference = 'Stop'`n$Command")
    foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
    $script:Op = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

# ---------------------------------------------------------------------------
#  Окно
# ---------------------------------------------------------------------------
$font = New-Object Drawing.Font('Segoe UI', 10)
$form = New-Object Windows.Forms.Form
$form.Text = 'Перенос данных'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(760, 720)
$form.MinimumSize = New-Object Drawing.Size(640, 600)
$form.Font = $font
try {
    $dbIcon = Join-Path $PSScriptRoot 'icon-db.ico'
    if (Test-Path $dbIcon) { $form.Icon = New-Object System.Drawing.Icon($dbIcon) }
} catch {}

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Top'; $tabs.Height = 410
$form.Controls.Add($tabs)

$logBox = New-Object Windows.Forms.RichTextBox
$logBox.Dock = 'Fill'; $logBox.ReadOnly = $true; $logBox.Font = New-Object Drawing.Font('Consolas', 10); $logBox.BackColor = [Drawing.Color]::White
$state = New-Object Windows.Forms.Label
$state.Dock = 'Bottom'; $state.Height = 28; $state.TextAlign = 'MiddleLeft'; $state.Text = 'Готово к работе'
$bar = New-Object Windows.Forms.ProgressBar
$bar.Dock = 'Bottom'; $bar.Height = 14; $bar.Style = 'Continuous'
$form.Controls.Add($logBox); $form.Controls.Add($state); $form.Controls.Add($bar)
$logBox.BringToFront()

function New-Tab([string]$Title) { $t = New-Object Windows.Forms.TabPage; $t.Text = $Title; $t.Padding = '10,10,10,10'; $tabs.TabPages.Add($t); $t }
function New-Button($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 200) {
    $b = New-Object Windows.Forms.Button; $b.Text = $Text; $b.Location = "$X,$Y"; $b.Size = "$W,36"; $Parent.Controls.Add($b); $b
}
function New-Label($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 700) {
    $l = New-Object Windows.Forms.Label; $l.Text = $Text; $l.Location = "$X,$Y"; $l.AutoSize = $true; $l.MaximumSize = "$W,0"; $Parent.Controls.Add($l); $l
}
function Pick-Folder([string]$Desc) {
    $d = New-Object Windows.Forms.FolderBrowserDialog; $d.Description = $Desc; $d.ShowNewFolderButton = $true
    if ($d.ShowDialog($form) -eq 'OK') { $d.SelectedPath }
}
function Get-DefaultTarget {
    $d = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -ne $env:SystemDrive -and $_.DriveType -in 2, 3 -and $_.FreeSpace } |
        Sort-Object @{ E = { $_.DriveType -ne 2 } }, DeviceID | Select-Object -First 1
    if ($d) { "$($d.DeviceID)\" } else { '' }
}

# --- 1. Сохранить ---
$tSave = New-Tab 'Сохранить'
New-Label $tSave 'Что сохранить (размеры считаются в фоне):' 10 10 | Out-Null
$saveList = New-Object Windows.Forms.CheckedListBox
$saveList.Location = '10,36'; $saveList.Size = '710,200'; $saveList.CheckOnClick = $true
$tSave.Controls.Add($saveList)
$Cats = Get-Categories
foreach ($c in $Cats) { [void]$saveList.Items.Add($c.Name, $c.Default) }
New-Label $tSave 'Куда:' 10 250 | Out-Null
$saveTarget = New-Object Windows.Forms.TextBox; $saveTarget.Location = '60,247'; $saveTarget.Size = '460,26'; $saveTarget.Text = (Get-DefaultTarget)
$tSave.Controls.Add($saveTarget)
$bBrowse = New-Button $tSave 'Выбрать...' 530 244 120
$bBrowse.Add_Click({ $p = Pick-Folder 'Куда сохранить (флешка или другой диск)'; if ($p) { $saveTarget.Text = $p } })
$chkUpdate = New-Object Windows.Forms.CheckBox
$chkUpdate.Text = 'Докопировать в прошлую копию (только новое и изменённое — быстрее)'
$chkUpdate.Location = '10,290'; $chkUpdate.AutoSize = $true; $chkUpdate.Checked = $true
$tSave.Controls.Add($chkUpdate)
$bSave = New-Button $tSave 'Сохранить' 10 320 200
$bSave.Add_Click({
    $keys = @(for ($i = 0; $i -lt $saveList.Items.Count; $i++) { if ($saveList.GetItemChecked($i)) { $Cats[$i].Key } })
    if (-not $keys) { return }
    if (-not $saveTarget.Text -or -not (Test-Path $saveTarget.Text)) { [Windows.Forms.MessageBox]::Show($form, 'Выберите, куда сохранить.', 'Перенос данных') | Out-Null; return }
    if ($saveTarget.Text.StartsWith($env:SystemDrive, 'OrdinalIgnoreCase')) {
        if ([Windows.Forms.MessageBox]::Show($form, "Вы сохраняете на системный диск $env:SystemDrive. При переустановке Windows он обычно форматируется. Всё равно продолжить?", 'Перенос данных', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $Shared.Update = $chkUpdate.Checked
    Start-Op 'Invoke-Backup $A $B $Shared.Update' @($saveTarget.Text, $keys)
})

# --- 2. Восстановить ---
$tRest = New-Tab 'Восстановить'
New-Label $tRest 'Выберите папку сохранения: «Перенос данных\<Имя>\<дата>» (или папку с именем — возьмётся последняя дата).' 10 10 | Out-Null
$restPath = New-Object Windows.Forms.TextBox; $restPath.Location = '10,56'; $restPath.Size = '510,26'
$tRest.Controls.Add($restPath)
$bPick = New-Button $tRest 'Выбрать...' 530 53 120
$restList = New-Object Windows.Forms.CheckedListBox
$restList.Location = '10,94'; $restList.Size = '710,150'; $restList.CheckOnClick = $true
$tRest.Controls.Add($restList)
$chkApps = New-Object Windows.Forms.CheckBox; $chkApps.Text = 'Также установить программы из сохранённого списка (нужен интернет, долго)'
$chkApps.Location = '10,252'; $chkApps.AutoSize = $true; $tRest.Controls.Add($chkApps)
$script:RestRoot = $null; $script:RestKeys = @()
function Load-Backup([string]$Path) {
    $restList.Items.Clear(); $script:RestRoot = $null; $script:RestKeys = @()
    if (-not (Test-Path (Join-Path $Path 'manifest.json'))) {
        $latest = Get-ChildItem $Path -Recurse -Filter 'manifest.json' -Depth 3 -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name } -Descending | Select-Object -First 1
        if (-not $latest) { [Windows.Forms.MessageBox]::Show($form, 'В этой папке нет сохранённых данных.', 'Перенос данных') | Out-Null; return }
        $Path = $latest.DirectoryName
    }
    $restPath.Text = $Path
    $m = Get-Content (Join-Path $Path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in $m.Categories) {
        $c = $Cats | Where-Object { $_.Key -eq $e.Key } | Select-Object -First 1
        [void]$restList.Items.Add($(if ($c) { $c.Name } else { $e.Key }), $true)
        $script:RestKeys += $e.Key
    }
    $script:RestRoot = $Path
    Write-LogLine 'INFO' "Сохранение: пользователь $($m.User), компьютер $($m.Computer), дата $($m.Date)"
}
$bPick.Add_Click({ $p = Pick-Folder 'Папка «Перенос данных» на флешке или диске'; if ($p) { Load-Backup $p } })
$bRestore = New-Button $tRest 'Восстановить' 10 290 200
$bRestore.Add_Click({
    if (-not $script:RestRoot) { return }
    $keys = @(for ($i = 0; $i -lt $restList.Items.Count; $i++) { if ($restList.GetItemChecked($i)) { $script:RestKeys[$i] } })
    if (-not $keys) { return }
    if ([Windows.Forms.MessageBox]::Show($form, 'Браузеры и Telegram будут закрыты. Файлы, которые на этом компьютере новее сохранённых, не заменяются. Продолжить?', 'Перенос данных', 'YesNo', 'Question') -ne 'Yes') { return }
    $Shared.InstallApps = $chkApps.Checked
    Start-Op 'Invoke-Restore $A $B' @($script:RestRoot, $keys)
})

# --- 3. Игры Steam ---
$tSteam = New-Tab 'Игры Steam'
New-Label $tSteam ("После переустановки Windows игры Steam на других дисках (например, D:\SteamLibrary) остаются на месте, " +
    "но Steam о них не знает. Здесь можно найти их и подключить обратно — ничего не придётся перекачивать.`n`n" +
    "Перед этим Steam должен быть установлен и хотя бы раз запущен с входом в аккаунт. Steam будет закрыт.") 10 10 | Out-Null
$bSteam = New-Button $tSteam 'Найти и подключить игры' 10 130 260
$bSteam.Add_Click({ Start-Op 'Add-SteamLibraries' })

# --- 4. Папки на другой диск ---
$tMove = New-Tab 'Папки на другой диск'
New-Label $tMove ("Рабочий стол, Документы, Загрузки и т.д. переедут на другой диск (например, D:\Users\$env:USERNAME\...). " +
    'Windows будет открывать их там же, где обычно, а при переустановке системы они не пропадут.') 10 10 | Out-Null
$moveList = New-Object Windows.Forms.CheckedListBox
$moveList.Location = '10,70'; $moveList.Size = '300,140'; $moveList.CheckOnClick = $true
$tMove.Controls.Add($moveList)
$MoveCats = @($Cats | Where-Object { $_.Kind -eq 'Folder' })
foreach ($c in $MoveCats) { [void]$moveList.Items.Add($c.Name, $true) }
New-Label $tMove 'На диск:' 330 72 | Out-Null
$driveBox = New-Object Windows.Forms.ComboBox; $driveBox.DropDownStyle = 'DropDownList'; $driveBox.Location = '400,68'; $driveBox.Size = '200,26'
foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -ne $env:SystemDrive }) {
    [void]$driveBox.Items.Add(('{0}  (свободно {1:N0} ГБ)' -f $d.DeviceID, ($d.FreeSpace / 1GB)))
}
if ($driveBox.Items.Count) { $driveBox.SelectedIndex = 0 }
$tMove.Controls.Add($driveBox)
$bMove = New-Button $tMove 'Перенести' 10 225 200
$bMove.Add_Click({
    if (-not $driveBox.SelectedItem) { [Windows.Forms.MessageBox]::Show($form, 'Второго диска нет.', 'Перенос данных') | Out-Null; return }
    $drive = ("$($driveBox.SelectedItem)" -split '\s+')[0]
    $keys = @(for ($i = 0; $i -lt $moveList.Items.Count; $i++) { if ($moveList.GetItemChecked($i)) { $MoveCats[$i].Key } })
    if (-not $keys) { return }
    if ([Windows.Forms.MessageBox]::Show($form, "Перенести выбранные папки на диск $drive? Закройте открытые файлы из этих папок.", 'Перенос данных', 'YesNo', 'Question') -ne 'Yes') { return }
    Start-Op 'Move-UserFolders $A $B' @($drive, $keys)
})

# --- Вывод в окно ---
function Write-LogLine([string]$Status, [string]$Text) {
    $tag, $color = switch ($Status) {
        'OK'   { '[ OK ]', [Drawing.Color]::ForestGreen }
        'SKIP' { '[ -- ]', [Drawing.Color]::Gray }
        'WARN' { '[ !! ]', [Drawing.Color]::DarkOrange }
        'FAIL' { '[FAIL]', [Drawing.Color]::Firebrick }
        default { '      ', [Drawing.Color]::Black }
    }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionColor = $color
    $logBox.AppendText("$tag $Text`r`n")
    $logBox.ScrollToCaret()
}

# Размеры категорий — в фоне, чтобы окно открылось сразу
$Sizes = [hashtable]::Synchronized(@{})
$sizeRs = [runspacefactory]::CreateRunspace(); $sizeRs.Open(); $sizeRs.SessionStateProxy.SetVariable('Sizes', $Sizes)
$sizePs = [powershell]::Create(); $sizePs.Runspace = $sizeRs
[void]$sizePs.AddScript(". { $OpsCode }`nforeach (`$c in Get-Categories) { try { `$Sizes[`$c.Key] = Get-CategorySize `$c } catch { `$Sizes[`$c.Key] = -1 } }")
[void]$sizePs.BeginInvoke()

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    while ($Shared.Log.Count) {
        $l = $Shared.Log[0]; $Shared.Log.RemoveAt(0)
        $st, $tx = $l -split '\|', 2
        Write-LogLine $st $tx
    }
    for ($i = 0; $i -lt $Cats.Count; $i++) {
        $c = $Cats[$i]
        if ($Sizes.ContainsKey($c.Key) -and $Sizes[$c.Key] -gt 0 -and $saveList.Items[$i] -eq $c.Name) {
            $was = $saveList.GetItemChecked($i)
            $saveList.Items[$i] = "$($c.Name)  —  $(Format-Size $Sizes[$c.Key])"
            $saveList.SetItemChecked($i, $was)
        }
    }
    if ($Shared.Busy) {
        $bar.Style = 'Marquee'; $state.Text = $Shared.State
        foreach ($b in $bSave, $bRestore, $bSteam, $bMove) { $b.Enabled = $false }
        if ($script:Op -and $script:Op.Handle.IsCompleted) {
            try { $script:Op.PS.EndInvoke($script:Op.Handle) | Out-Null } catch { Write-LogLine 'FAIL' $_.Exception.InnerException.Message }
            foreach ($e in $script:Op.PS.Streams.Error) { Write-LogLine 'FAIL' $e.Exception.Message }
            $script:Op.PS.Runspace.Dispose(); $script:Op.PS.Dispose(); $script:Op = $null
            $Shared.Busy = $false
            $bar.Style = 'Continuous'; $bar.Value = 0; $state.Text = $Shared.State
            foreach ($b in $bSave, $bRestore, $bSteam, $bMove) { $b.Enabled = $true }
            try { (New-Object Media.SoundPlayer "$env:SystemRoot\Media\tada.wav").Play() } catch {}
        }
    }
})
$timer.Start()
$form.Add_FormClosing({
    if ($Shared.Busy -and [Windows.Forms.MessageBox]::Show($form, 'Операция ещё идёт. Закрыть всё равно?', 'Перенос данных', 'YesNo', 'Warning') -ne 'Yes') { $_.Cancel = $true }
})
Write-LogLine 'INFO' "Пользователь: $env:USERNAME, компьютер: $env:COMPUTERNAME"
[void]$form.ShowDialog()
$timer.Stop()
