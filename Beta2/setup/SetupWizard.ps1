#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms

Import-Module -Force -DisableNameChecking (Join-Path $PSScriptRoot '..\modules\Common.Crypto.psm1')
$telegramModule = Join-Path $PSScriptRoot '..\modules\Common.Telegram.psm1'
if (Test-Path $telegramModule) {
    try { Import-Module -Force -DisableNameChecking $telegramModule -ErrorAction Stop } catch { Write-Warning "Не удалось загрузить модуль Telegram: $($_.Exception.Message)" }
}

# ---------- helpers ----------
function Select-FolderDialog($description) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $description
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath } else { throw 'Отменено' }
}
function Select-FileDialog($filter, $title, $initialDir = $null) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $filter
    $dlg.Title  = $title
    if ($initialDir -and (Test-Path $initialDir)) { $dlg.InitialDirectory = $initialDir }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName } else { throw 'Отменено' }
}
function Read-Choice($prompt, $choices) {
    Write-Host $prompt
    for ($i=0; $i -lt $choices.Count; $i++){ Write-Host ("{0} - {1}" -f ($i+1), $choices[$i]) }
    do { $x = Read-Host ("Ваш выбор (1/{0})" -f $choices.Count) }
    while (-not ($x -match '^\d+$') -or [int]$x -lt 1 -or [int]$x -gt $choices.Count)
    [int]$x
}
# Преобразуем PSCustomObject -> Hashtable (на случай, если дешифратор вернул не Hashtable)
function ConvertTo-Hashtable($obj){
    if ($obj -is [hashtable]) { return $obj }
    $ht = @{}
    if ($obj -is [System.Collections.IDictionary]) {
        foreach($k in $obj.Keys){ $ht[$k] = $obj[$k] }
    } elseif ($obj -and $obj.PSObject) {
        foreach($p in $obj.PSObject.Properties){ $ht[$p.Name] = $p.Value }
    }
    return $ht
}

# Только веб-службы (Apache/IIS)
function Get-WebServices {
    $masks = @('Apache2.4','Apache*','httpd*','W3SVC','WAS')  # IIS: W3SVC (WWW), WAS
    $all = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $n = $_.Name
        $masks | Where-Object { $n -like $_ } | Select-Object -First 1
    }
    $all | Sort-Object @{Expression='Status';Descending=$true},
                     @{Expression='DisplayName';Descending=$false}
}

# Поиск 1cestart.exe (x64/x86)
function Get-1CEStartCandidates {
    $list = @()
    $pf   = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf)   { $list += (Join-Path $pf   '1cv8\common\1cestart.exe') }
    if ($pf86) { $list += (Join-Path $pf86 '1cv8\common\1cestart.exe') }
    $list | Where-Object { $_ -and (Test-Path $_) }
}
function Select-1CEStart {
    $cands = Get-1CEStartCandidates
    $init  = if ($cands -and $cands[0]) { Split-Path $cands[0] -Parent } else { "$env:ProgramFiles\1cv8\common" }
    Select-FileDialog "1cestart.exe|1cestart.exe" "Выберите 1cestart.exe (обычно C:\Program Files\1cv8\common)" $init
}

# ---------- paths ----------
$configRoot   = Join-Path $PSScriptRoot '..\config'
$basesDir     = Join-Path $configRoot  'bases'
$settingsFile = Join-Path $configRoot  'settings.json'
$keyPath      = Join-Path $configRoot  'key.bin'
$secretsFile  = Join-Path $configRoot  'secrets.json.enc'

if (-not (Test-Path $configRoot)) { New-Item -ItemType Directory -Path $configRoot | Out-Null }
if (-not (Test-Path $basesDir  )) { New-Item -ItemType Directory -Path $basesDir   | Out-Null }

# ---------- load & merge secrets ----------
[hashtable]$allSecrets = @{}
if ((Test-Path $secretsFile) -and (Test-Path $keyPath)) {
    try {
        $raw = Decrypt-Secrets -InFile $secretsFile -KeyPath $keyPath
        $allSecrets = ConvertTo-Hashtable $raw
        if (-not ($allSecrets -is [hashtable])) { $allSecrets = @{} }
    } catch { $allSecrets = @{} }
}

# ---------- load settings ----------
$settings = @{}
if (Test-Path $settingsFile) {
    try { $settings = ConvertTo-Hashtable (Get-Content $settingsFile -Raw | ConvertFrom-Json) } catch { $settings = @{} }
}
$afterCurrent = if ($settings.ContainsKey('AfterBackup')) { [int]$settings['AfterBackup'] } else { 3 }
$telegramSettings = if ($settings.ContainsKey('Telegram')) { ConvertTo-Hashtable $settings['Telegram'] } else { @{} }
$telegramEnabledCurrent = [bool]($telegramSettings['Enabled'])
$telegramChatIdCurrent  = if ($telegramSettings.ContainsKey('ChatId')) { '' + $telegramSettings['ChatId'] } else { '' }
$telegramTokenKey = '__GLOBAL__TelegramBotToken'
$telegramTokenCurrent = if ($allSecrets.ContainsKey($telegramTokenKey)) { '' + $allSecrets[$telegramTokenKey] } else { '' }

$allConfigs = @()

# ---------- wizard ----------
while ($true) {
    $cfg = @{}
    $cfg.Tag = Read-Host "Введите уникальное имя базы (например, ShopDB)"

    $t = Read-Choice "Выберите тип бэкапа:" @('Копия файла .1CD','Выгрузка .dt через конфигуратор')
    $cfg.BackupType = if ($t -eq 1) { '1CD' } else { 'DT' }

    if ($cfg.BackupType -eq '1CD') {
        $cfg.SourcePath = Select-FileDialog "Файл 1Cv8.1CD|1Cv8.1CD" "Выберите файл 1Cv8.1CD (где ХРАНИТСЯ база)"
    } else {
        $cfg.SourcePath = Select-FolderDialog "Выберите каталог, в котором лежит база 1С"

        # 1cestart.exe (приоритет)
        try { $cfg.ExePath = Select-1CEStart } catch { $cfg.ExePath = $null }

        # Выбор веб-служб: Авто / Ручной / Нет
        $stopMode = Read-Choice "Останавливать веб-службы при выгрузке .dt?" @(
            'Авто (Apache2.4; при отсутствии — все найденные веб-службы)',
            'Выбрать вручную',
            'Нет'
        )
        switch ($stopMode) {
            1 {
                $web = Get-WebServices
                if (-not $web) {
                    Write-Host "Веб-службы не найдены" -ForegroundColor Yellow
                }
                elseif ($web.Name -contains 'Apache2.4') {
                    $cfg.StopServices = @('Apache2.4')
                    Write-Host "Будет остановлена служба: Apache2.4" -ForegroundColor DarkCyan
                }
                else {
                    $cfg.StopServices = $web | Select-Object -ExpandProperty Name
                    if ($cfg.StopServices) {
                        Write-Host ("Будут остановлены: {0}" -f ($cfg.StopServices -join ', ')) -ForegroundColor DarkCyan
                    }
                }
            }
            2 {
                $web = Get-WebServices
                if (-not $web) {
                    Write-Host "Веб-службы не найдены" -ForegroundColor Yellow
                }
                else {
                    Write-Host "`nДоступные веб-службы:" -ForegroundColor Cyan
                    $i = 1
                    foreach ($s in $web) {
                        Write-Host ("{0}) {1} [{2}] — {3}" -f $i, $s.DisplayName, $s.Name, $s.Status)
                        $i++
                    }
                    $raw = Read-Host "Введите номера через запятую (например, 1,3)"
                    $idx = $raw -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object {[int]$_}
                    $sel = @()
                    for ($j=0; $j -lt $web.Count; $j++) { if ($idx -contains ($j+1)) { $sel += $web[$j].Name } }
                    if ($sel.Count -gt 0) {
                        $cfg.StopServices = $sel
                        Write-Host ("Будут остановлены: {0}" -f ($sel -join ', ')) -ForegroundColor DarkCyan
                    } else {
                        Write-Host "Ничего не выбрано — службы останавливаться не будут" -ForegroundColor Yellow
                    }
                }
            }
            default { $cfg.StopServices = @() }  # "Нет"
        }

        # Логин/пароль для .DT (не затираем чужие базы)
        $lg = Read-Host "Логин 1С (если не требуется — пусто)"
        $pw = Read-Host "Пароль 1С (если не требуется — пусто)"
        if ($lg) { $allSecrets["$($cfg.Tag)__DT_Login"]    = $lg }
        if ($pw) { $allSecrets["$($cfg.Tag)__DT_Password"] = $pw }

        $cfg.DumpTimeoutMin = [int](Read-Host "Таймаут выгрузки, минут (по умолчанию 60)")
        if ($cfg.DumpTimeoutMin -le 0) { $cfg.DumpTimeoutMin = 60 }
    }

    $cfg.DestinationPath = Select-FolderDialog "Папка, куда сохранять резервные копии"
    $cfg.Keep = [int](Read-Host "Сколько последних копий хранить (число)")

    # Яндекс.Диск (токен в секреты конкретной базы)
    $useCloud = Read-Choice "Отправлять копии в Яндекс.Диск?" @('Да','Нет')
    if ($useCloud -eq 1) {
        $cfg.CloudType = 'Yandex.Disk'
        $token = Read-Host "Введите OAuth токен Яндекс.Диска"
        if ($token) { $allSecrets["$($cfg.Tag)__YADiskToken"] = $token }
        $cleanCloud = Read-Choice "Очищать старые копии в Яндекс.Диске? (будет храниться столько же, сколько локально)" @('Да','Нет')
        $cfg.CloudCleanup = ($cleanCloud -eq 1)
    } else {
        $cfg.CloudType = ''
        $cfg.CloudCleanup = $false
    }

    $allConfigs += $cfg
    $more = Read-Choice "Добавить ещё одну базу?" @('Да','Нет')
    if ($more -ne 1) { break }
}

# ---------- общие настройки ----------
$afterDescriptions = @('Выключить ПК','Перезагрузить ПК','Ничего не делать')
$afterIdx = switch ($afterCurrent) { 1 { 1 } 2 { 2 } default { 3 } }
Write-Host ("Текущее действие после бэкапа: {0}" -f $afterDescriptions[$afterIdx-1]) -ForegroundColor Cyan
$act = Read-Choice "Что делать после завершения бэкапа?" $afterDescriptions

$telegramEnabledNew = $telegramEnabledCurrent
$telegramChatIdNew  = $telegramChatIdCurrent
$telegramTokenNew   = $telegramTokenCurrent
$tgStatus = if ($telegramEnabledCurrent) { 'включено' } else { 'отключено' }
Write-Host ("Поддержка Telegram сейчас: $tgStatus") -ForegroundColor Cyan
$tgChoice = Read-Choice "Отправлять логи в Telegram?" @('Да','Нет')
if ($tgChoice -eq 1) {
    $telegramEnabledNew = $true
    $chatPrompt = Read-Host ("Chat ID получателя (текущее: {0})" -f (if ($telegramChatIdNew) { $telegramChatIdNew } else { '<пусто>' }))
    if ($chatPrompt -ne '') { $telegramChatIdNew = $chatPrompt }
    $tokenPrompt = Read-Host "Токен бота (оставьте пустым, чтобы не менять)"
    if ($tokenPrompt -ne '') {
        $telegramTokenNew = $tokenPrompt
        $allSecrets[$telegramTokenKey] = $tokenPrompt
    } elseif ($telegramTokenNew) {
        $allSecrets[$telegramTokenKey] = $telegramTokenNew
    }

    if ($telegramChatIdNew -and $telegramTokenNew) {
        if (Get-Command Send-TelegramMessage -ErrorAction SilentlyContinue) {
            try {
                Send-TelegramMessage -Token $telegramTokenNew -ChatId $telegramChatIdNew -Text "[TEST] Проверка подключения резервного копирования 1С" -DisableNotification | Out-Null
                Write-Host "[INFO] Тестовое сообщение отправлено в Telegram." -ForegroundColor Green
            } catch {
                Write-Host ("[WARN] Не удалось отправить тестовое сообщение: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        } else {
            Write-Host "[WARN] Модуль Send-TelegramMessage недоступен, тест не выполнен." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[WARN] Chat ID или токен не заданы — тест не выполнен." -ForegroundColor Yellow
    }
} else {
    $telegramEnabledNew = $false
}

# ---------- save ----------
foreach ($cfg in $allConfigs) {
    $cfgPath = Join-Path $basesDir ("{0}.json" -f $cfg.Tag)
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -Path $cfgPath -Encoding UTF8
    Write-Host ("Готово. База [{0}] добавлена." -f $cfg.Tag) -ForegroundColor Green
}

Encrypt-Secrets -Secrets $allSecrets -KeyPath $keyPath -OutFile $secretsFile
Write-Host "Секреты сохранены и зашифрованы." -ForegroundColor Green

$settingsOut = [ordered]@{
    AfterBackup = $act
    Telegram    = [ordered]@{
        Enabled = [bool]$telegramEnabledNew
        ChatId  = $telegramChatIdNew
    }
}
$settingsOut | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsFile -Encoding UTF8

Write-Host "[INFO] Настройка баз завершена." -ForegroundColor Green