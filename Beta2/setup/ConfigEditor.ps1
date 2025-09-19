#requires -Version 5.1
# encoding: UTF-8
$ErrorActionPreference = 'Stop'

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    return (Get-Location).Path
}

$scriptRoot = Get-ScriptRoot

$cryptoPath = Join-Path -Path $scriptRoot -ChildPath '..\modules\Common.Crypto.psm1'
Import-Module -Force -DisableNameChecking $cryptoPath
$telegramModule = Join-Path -Path $scriptRoot -ChildPath '..\modules\Common.Telegram.psm1'
if ($telegramModule -and (Test-Path -LiteralPath $telegramModule)) {
    try { Import-Module -Force -DisableNameChecking $telegramModule -ErrorAction Stop } catch { Write-Warning "Не удалось загрузить модуль Telegram: $($_.Exception.Message)" }
}

# ---- Пути ---------------------------------------------------------
$ConfigRoot  = if ($scriptRoot) { Join-Path -Path $scriptRoot -ChildPath '..\config' } else { $null }
$BasesDir    = if ($ConfigRoot) { Join-Path -Path $ConfigRoot  -ChildPath 'bases' } else { $null }
$SettingsFile= if ($ConfigRoot) { Join-Path -Path $ConfigRoot  -ChildPath 'settings.json' } else { $null }
$KeyPath     = if ($ConfigRoot) { Join-Path -Path $ConfigRoot  -ChildPath 'key.bin' } else { $null }
$SecretsFile = if ($ConfigRoot) { Join-Path -Path $ConfigRoot  -ChildPath 'secrets.json.enc' } else { $null }
if ($BasesDir -and -not (Test-Path -LiteralPath $BasesDir)) { New-Item -ItemType Directory -Path $BasesDir | Out-Null }

# ---- Утилиты ------------------------------------------------------
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

function Read-Choice([string]$Prompt,[string[]]$Choices){
    Write-Host ''
    Write-Host $Prompt
    for($i=0;$i -lt $Choices.Count;$i++){
        Write-Host ("{0} - {1}" -f ($i+1), $Choices[$i])
    }
    do { $x = Read-Host ("Ваш выбор (1/{0})" -f $Choices.Count) }
    while(-not ($x -match '^\d+$') -or [int]$x -lt 1 -or [int]$x -gt $Choices.Count)
    return [int]$x
}

function Load-Settings(){
    if ($SettingsFile -and (Test-Path -LiteralPath $SettingsFile)) {
        try { return ConvertTo-Hashtable (Get-Content $SettingsFile -Raw | ConvertFrom-Json) } catch { return @{} }
    }
    return @{}
}

function Save-Settings($settings){
    if ($SettingsFile) {
        $settings | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $SettingsFile
    } else {
        Write-Warning "Не удалось сохранить settings.json — путь не определён"
    }
}

function Load-Secrets(){
    if ($SecretsFile -and $KeyPath -and (Test-Path -LiteralPath $SecretsFile) -and (Test-Path -LiteralPath $KeyPath)) {
        try {
            $raw = Decrypt-Secrets -InFile $SecretsFile -KeyPath $KeyPath
            return ConvertTo-Hashtable $raw
        } catch { return @{} }
    }
    return @{}
}

function Save-Secrets($secrets){
    if ($KeyPath -and $SecretsFile) {
        $hash = ConvertTo-Hashtable $secrets
        Encrypt-Secrets -Secrets $hash -KeyPath $KeyPath -OutFile $SecretsFile
    } else {
        Write-Warning "Не удалось сохранить secrets.json.enc — путь не определён"
    }
}

function Get-BaseList(){
    if (-not $BasesDir -or -not (Test-Path -LiteralPath $BasesDir)) { return @() }
    Get-ChildItem -Path $BasesDir -Filter *.json -File |
        Select-Object -ExpandProperty BaseName |
        Sort-Object
}

function Choose-Base([string[]]$List){
    if(-not $List -or $List.Count -eq 0){
        $dir = if ($BasesDir) { $BasesDir } else { '<не определена>' }
        throw "В папке '$dir' нет конфигов *.json"
    }
    Write-Host "`nТекущие базы:`n"
    for($i=0;$i -lt $List.Count;$i++){
        Write-Host ("{0}) {1}" -f ($i+1), $List[$i])
    }
    do { $n = Read-Host ("Выберите номер (1-{0})" -f $List.Count) }
    while(-not ($n -match '^\d+$') -or [int]$n -lt 1 -or [int]$n -gt $List.Count)
    return $List[[int]$n-1]
}

function Load-Config([string]$Tag){
    if (-not $BasesDir) { throw "Не определён каталог баз" }
    $path = Join-Path $BasesDir ("{0}.json" -f $Tag)
    if(-not (Test-Path -LiteralPath $path)){ throw "Конфиг не найден: $path" }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Save-Config([string]$Tag,$Obj){
    if (-not $BasesDir) { throw "Не определён каталог баз" }
    $path = Join-Path $BasesDir ("{0}.json" -f $Tag)
    $Obj | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $path
}

function Prompt-Int([string]$Label, $Current){
    $inp = Read-Host ("{0} (текущее: {1})" -f $Label, $Current)
    if([string]::IsNullOrWhiteSpace($inp)){ return $Current }
    $n = 0
    if([int]::TryParse($inp, [ref]$n)){ return $n }
    Write-Host "Некорректное число, оставляю: $Current"
    return $Current
}

# ---- Действия -----------------------------------------------------
function Action-Edit{
    $list = Get-BaseList
    $tag  = Choose-Base $list
    $cfg  = Load-Config $tag

    Write-Host ("`nРедактирование [{0}]. Пустое значение — оставить как есть." -f $tag)

    if($cfg.PSObject.Properties.Name -contains 'BackupType'){
        $cur = $cfg.BackupType
        $val = Read-Host ("BackupType (текущее: {0})" -f $cur)
        if($val -ne ''){ $cfg.BackupType = $val }
    }
    if($cfg.PSObject.Properties.Name -contains 'SourcePath'){
        $cur = $cfg.SourcePath
        $val = Read-Host ("SourcePath (текущее: {0})" -f $cur)
        if($val -ne ''){ $cfg.SourcePath = $val }
    }
    if($cfg.PSObject.Properties.Name -contains 'DestinationPath'){
        $cur = $cfg.DestinationPath
        $val = Read-Host ("DestinationPath (текущее: {0})" -f $cur)
        if($val -ne ''){ $cfg.DestinationPath = $val }
    }
    if($cfg.PSObject.Properties.Name -contains 'Keep'){
        $cfg.Keep = Prompt-Int 'Keep (сколько копий хранить)' $cfg.Keep
    }
    if($cfg.PSObject.Properties.Name -contains 'CloudType'){
        $cur = $cfg.CloudType
        $val = Read-Host ("CloudType (текущее: {0})" -f $cur)
        if($val -ne ''){ $cfg.CloudType = $val }
    }
    $curCleanup = if ($cfg.PSObject.Properties.Name -contains 'CloudCleanup') { if([bool]$cfg.CloudCleanup){'Да'} else {'Нет'} } else {'Нет'}
    $valCleanup = Read-Host ("CloudCleanup (очищать облако? Да/Нет, текущее: {0})" -f $curCleanup)
    if($valCleanup -ne ''){
        $cfg.CloudCleanup = ($valCleanup.Trim() -match '^(?i)(1|y|yes|да|true)$')
    }

    if(($cfg.PSObject.Properties.Name -contains 'BackupType') -and ($cfg.BackupType -eq 'DT')){
        if($cfg.PSObject.Properties.Name -contains 'ExePath'){
            $cur = $cfg.ExePath
            $val = Read-Host ("ExePath (текущее: {0})" -f $cur)
            if($val -ne ''){ $cfg.ExePath = $val }
        }

        $curSS = '<пусто>'
        if($cfg.PSObject.Properties.Name -contains 'StopServices'){
            if($cfg.StopServices){
                $curSS = ($cfg.StopServices -join ', ')
            }
        }
        $val = Read-Host ("StopServices через запятую (текущее: {0})" -f $curSS)
        if($val -ne ''){
            $cfg.StopServices = ($val -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }

        if($cfg.PSObject.Properties.Name -contains 'DumpTimeoutMin'){
            $cfg.DumpTimeoutMin = Prompt-Int 'DumpTimeoutMin (минут)' $cfg.DumpTimeoutMin
        }
    }

    Save-Config $tag $cfg
    Write-Host "Сохранено."
}

function Action-Toggle{
    $list = Get-BaseList
    $tag  = Choose-Base $list
    $cfg  = Load-Config $tag

    $enabled = $true
    if($cfg.PSObject.Properties.Name -contains 'Disabled'){
        $enabled = -not [bool]$cfg.Disabled
    }

    $state = if($enabled){'ВКЛЮЧЕНО'} else {'ОТКЛЮЧЕНО'}
    $ch = Read-Choice ("Сейчас: $state. Что сделать?") @('Включить','Отключить','Отмена')
    switch($ch){
        1 { $cfg.Disabled = $false; Save-Config $tag $cfg; Write-Host "База [$tag] включена." }
        2 { $cfg.Disabled = $true;  Save-Config $tag $cfg; Write-Host "База [$tag] отключена." }
        default { Write-Host "Без изменений." }
    }
}

function Action-Delete{
    $list = Get-BaseList
    $tag  = Choose-Base $list
    $path = Join-Path $BasesDir ("{0}.json" -f $tag)
    $ch   = Read-Choice ("Удалить конфиг [$tag]?") @('Да','Нет')
    if($ch -eq 1){
        Remove-Item -LiteralPath $path -Force
        Write-Host "Удалено: $path"
    }
}

function Action-Settings{
    $settings = Load-Settings
    $secrets  = Load-Secrets

    $afterDescriptions = @('Выключить ПК','Перезагрузить ПК','Ничего не делать')
    $afterCurrent = if ($settings.ContainsKey('AfterBackup')) { [int]$settings['AfterBackup'] } else { 3 }
    $afterIdx = switch ($afterCurrent) { 1 {1} 2 {2} default {3} }
    Write-Host ("Текущее действие после бэкапа: {0}" -f $afterDescriptions[$afterIdx-1]) -ForegroundColor Cyan
    $act = Read-Choice "Выберите новое действие после завершения бэкапа" $afterDescriptions
    $settings['AfterBackup'] = $act

    $telegramSettings = if ($settings.ContainsKey('Telegram')) { ConvertTo-Hashtable $settings['Telegram'] } else { @{} }
    $enabled = [bool]$telegramSettings['Enabled']
    $chatId  = if ($telegramSettings.ContainsKey('ChatId')) { '' + $telegramSettings['ChatId'] } else { '' }
    $tokenKey = '__GLOBAL__TelegramBotToken'
    $token  = if ($secrets.ContainsKey($tokenKey)) { '' + $secrets[$tokenKey] } else { '' }

    $status = if ($enabled) { 'включено' } else { 'отключено' }
    Write-Host ("Поддержка Telegram сейчас: $status") -ForegroundColor Cyan
    $tgChoice = Read-Choice "Включить отправку логов в Telegram?" @('Да','Нет')
    if ($tgChoice -eq 1) {
        $enabled = $true
        $chatPrompt = Read-Host ("Chat ID получателя (текущее: {0})" -f (if ($chatId) { $chatId } else { '<пусто>' }))
        if ($chatPrompt -ne '') { $chatId = $chatPrompt }
        $tokenPrompt = Read-Host "Токен бота (оставьте пустым, чтобы не менять)"
        if ($tokenPrompt -ne '') { $token = $tokenPrompt }
        if ($chatId -and $token) {
            $secrets[$tokenKey] = $token
            if (Get-Command Send-TelegramMessage -ErrorAction SilentlyContinue) {
                $test = Read-Choice "Отправить тестовое сообщение?" @('Да','Нет')
                if ($test -eq 1) {
                    try {
                        Send-TelegramMessage -Token $token -ChatId $chatId -Text "[TEST] Проверка настроек редактором конфигурации" -DisableNotification | Out-Null
                        Write-Host "[INFO] Тестовое сообщение отправлено." -ForegroundColor Green
                    } catch {
                        Write-Host ("[WARN] Не удалось отправить тестовое сообщение: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    }
                }
            } else {
                Write-Host "[WARN] Модуль Telegram недоступен, тест не выполнен." -ForegroundColor Yellow
            }
        } else {
            Write-Host "[WARN] Chat ID или токен не заданы — тест не выполнен." -ForegroundColor Yellow
        }
    } else {
        $enabled = $false
    }

    $settings['Telegram'] = @{ Enabled = $enabled; ChatId = $chatId }
    Save-Settings $settings
    Save-Secrets  $secrets
    Write-Host "[INFO] Настройки сохранены." -ForegroundColor Green
}

# ---- Меню ---------------------------------------------------------
try {
    while($true){
        $a = Read-Choice "Выберите действие" @(
            'Редактировать базу',
            'Включить/Отключить базу',
            'Удалить базу',
            'Настройки (AfterBackup, Telegram)',
            'Выход'
        )
        switch($a){
            1 { Action-Edit }
            2 { Action-Toggle }
            3 { Action-Delete }
            4 { Action-Settings }
            default { break }
        }
    }
}
catch {
    Write-Host ("ОШИБКА: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $host.SetShouldExit(1)
}
