# Run-Backup.ps1
#requires -Version 5.1
chcp 65001 > $null

Write-Host "[INFO] Запуск процесса резервного копирования..." -ForegroundColor Yellow

$pipelinePath = Join-Path $PSScriptRoot 'core\Pipeline.psm1'
if (!(Test-Path $pipelinePath)) {
    Write-Error "Не найден Pipeline.psm1: $pipelinePath"
    exit 1
}

$modulesRoot    = Join-Path $PSScriptRoot 'modules'
$telegramModule = Join-Path $modulesRoot 'Common.Telegram.psm1'
$cryptoModule   = Join-Path $modulesRoot 'Common.Crypto.psm1'

if (Test-Path $telegramModule) {
    Import-Module -Force -DisableNameChecking $telegramModule -ErrorAction Stop
}
if (Test-Path $cryptoModule) {
    Import-Module -Force -DisableNameChecking $cryptoModule -ErrorAction Stop
}

Import-Module -Force -DisableNameChecking $pipelinePath -ErrorAction Stop

function ConvertTo-Hashtable {
    param([Parameter(Mandatory)]$Object)
    if ($Object -is [hashtable]) { return $Object }
    $ht = @{}
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { $ht[$k] = $Object[$k] }
    }
    elseif ($Object -and $Object.PSObject) {
        foreach ($p in $Object.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    }
    return $ht
}

$configRoot = Join-Path $PSScriptRoot 'config'
$basesDir   = Join-Path $configRoot 'bases'
$keyPath    = Join-Path $configRoot 'key.bin'
$secretsPath= Join-Path $configRoot 'secrets.json.enc'
$logDir     = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$settingsFile = Join-Path $configRoot 'settings.json'
$settings = @{}
if (Test-Path $settingsFile) {
    try { $settings = ConvertTo-Hashtable (Get-Content $settingsFile -Raw | ConvertFrom-Json) } catch { $settings = @{} }
}

$after = if ($settings.ContainsKey('AfterBackup')) { [int]$settings['AfterBackup'] } else { 3 }
if ($after -notin 1,2) { $after = 3 }

$telegramSettings = if ($settings.ContainsKey('Telegram')) { ConvertTo-Hashtable $settings['Telegram'] } else { @{} }
$script:telegramChatId = if ($telegramSettings.ContainsKey('ChatId')) { '' + $telegramSettings['ChatId'] } else { '' }
$telegramEnabled = [bool]($telegramSettings['Enabled'])

$allSecrets = @{}
if (Test-Path $secretsPath -and Test-Path $keyPath) {
    try {
        $allSecrets = ConvertTo-Hashtable (Decrypt-Secrets -InFile $secretsPath -KeyPath $keyPath)
    } catch {
        Write-Warning "Не удалось прочитать secrets.json.enc: $($_.Exception.Message)"
        $allSecrets = @{}
    }
}

$telegramTokenKey = '__GLOBAL__TelegramBotToken'
$script:telegramToken = if ($allSecrets.ContainsKey($telegramTokenKey)) { '' + $allSecrets[$telegramTokenKey] } else { '' }

$telegramReady = $false
if ($telegramEnabled) {
    if ([string]::IsNullOrWhiteSpace($script:telegramChatId) -or [string]::IsNullOrWhiteSpace($script:telegramToken)) {
        Write-Warning "Telegram включён, но ChatId или токен не заданы. Отправка логов отключена."
    } else {
        $telegramReady = $true
    }
}
if ($telegramReady -and -not (Get-Command Send-TelegramMessage -ErrorAction SilentlyContinue)) {
    Write-Warning "Команда Send-TelegramMessage недоступна. Отправка логов в Telegram отключена."
    $telegramReady = $false
}

$bases = Get-ChildItem -Path $basesDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
if (-not $bases -or $bases.Count -eq 0) {
    Write-Error "Не найдено ни одной базы в $basesDir"
    exit 1
}

$sessionLog = Join-Path $logDir ("backup_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$script:telegramErrorShown = $false
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    $line | Out-File -FilePath $sessionLog -Append -Encoding UTF8
    Write-Host $line

    if ($telegramReady) {
        try {
            Send-TelegramMessage -Token $script:telegramToken -ChatId $script:telegramChatId -Text $line -DisableNotification | Out-Null
        } catch {
            if (-not $script:telegramErrorShown) {
                Write-Warning "Не удалось отправить сообщение в Telegram: $($_.Exception.Message)"
                $script:telegramErrorShown = $true
            }
        }
    }
}

foreach ($tag in $bases) {
    try {
        $ctx = @{
            Tag        = $tag
            ConfigRoot = $configRoot
            ConfigDir  = $basesDir
            Secrets    = $allSecrets
            Log        = { param($msg) Write-Log ("[{0}] {1}" -f $tag, $msg) }
        }
        Invoke-Pipeline -Ctx $ctx
    }
    catch {
        Write-Log ("[ОШИБКА][{0}] {1}" -f $tag, $_.Exception.Message)
    }
}

switch ($after) {
    1 { Write-Log "[INFO] Выключаем ПК";  Stop-Computer -Force }
    2 { Write-Log "[INFO] Перезагружаем ПК"; Restart-Computer -Force }
    default { Write-Log "[INFO] Завершено. Действий с ПК нет." }
}