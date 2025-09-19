# Run-Backup.ps1
#requires -Version 5.1
chcp 65001 > $null

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    return (Get-Location).Path
}

$scriptRoot = Get-ScriptRoot

$pipelinePath = Join-Path -Path $scriptRoot -ChildPath 'core\Pipeline.psm1'
if (-not $pipelinePath -or -not (Test-Path -LiteralPath $pipelinePath)) {
    Write-Error "Не найден Pipeline.psm1: $pipelinePath"
    exit 1
}

$modulesRoot    = Join-Path -Path $scriptRoot -ChildPath 'modules'
$telegramModule = if ($modulesRoot) { Join-Path -Path $modulesRoot -ChildPath 'Common.Telegram.psm1' } else { $null }
$cryptoModule   = if ($modulesRoot) { Join-Path -Path $modulesRoot -ChildPath 'Common.Crypto.psm1' } else { $null }

if ($telegramModule -and (Test-Path -LiteralPath $telegramModule)) {
    Import-Module -Force -DisableNameChecking $telegramModule -ErrorAction Stop
}
if ($cryptoModule -and (Test-Path -LiteralPath $cryptoModule)) {
    Import-Module -Force -DisableNameChecking $cryptoModule -ErrorAction Stop
}

Import-Module -Force -DisableNameChecking $pipelinePath -ErrorAction Stop

$preLogMessages = New-Object System.Collections.Generic.List[string]

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

$configRoot  = if ($scriptRoot) { Join-Path -Path $scriptRoot -ChildPath 'config' } else { $null }
$basesDir    = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'bases' } else { $null }
$keyPath     = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'key.bin' } else { $null }
$secretsPath = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'secrets.json.enc' } else { $null }
$logDir      = if ($scriptRoot) { Join-Path -Path $scriptRoot -ChildPath 'logs' } else { $null }
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

if (-not $configRoot) {
    Write-Error "Не удалось определить каталог конфигурации."
    exit 1
}

$settingsFile = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'settings.json' } else { $null }
$settings = @{}
if ($settingsFile -and (Test-Path -LiteralPath $settingsFile)) {
    try { $settings = ConvertTo-Hashtable (Get-Content $settingsFile -Raw | ConvertFrom-Json) } catch { $settings = @{} }
}

$after = if ($settings.ContainsKey('AfterBackup')) { [int]$settings['AfterBackup'] } else { 3 }
if ($after -notin 1,2) { $after = 3 }

$telegramSettings = if ($settings.ContainsKey('Telegram')) { ConvertTo-Hashtable $settings['Telegram'] } else { @{} }
$script:telegramChatId = if ($telegramSettings.ContainsKey('ChatId')) { '' + $telegramSettings['ChatId'] } else { '' }
$telegramEnabled = [bool]($telegramSettings['Enabled'])

$allSecrets = @{}
$canLoadSecrets = $false
if ($secretsPath -and (Test-Path -LiteralPath $secretsPath)) {
    if ($keyPath -and (Test-Path -LiteralPath $keyPath)) {
        $canLoadSecrets = $true
    } else {
        $msg = "Не найден ключ шифрования (ожидался: $keyPath). Секреты не будут загружены."
        Write-Warning $msg
        $preLogMessages.Add("[WARN] $msg") | Out-Null
    }
} elseif ($secretsPath) {
    $msg = "Файл секретов не найден (ожидался: $secretsPath)."
    Write-Warning $msg
    $preLogMessages.Add("[WARN] $msg") | Out-Null
}
if ($canLoadSecrets) {
    try {
        $allSecrets = ConvertTo-Hashtable (Decrypt-Secrets -InFile $secretsPath -KeyPath $keyPath)
    } catch {
        $msg = "Не удалось прочитать secrets.json.enc: $($_.Exception.Message)"
        Write-Warning $msg
        $preLogMessages.Add("[WARN] $msg") | Out-Null
        $allSecrets = @{}
    }
}

$telegramTokenKey = '__GLOBAL__TelegramBotToken'
$script:telegramToken = if ($allSecrets.ContainsKey($telegramTokenKey)) { '' + $allSecrets[$telegramTokenKey] } else { '' }

$telegramReady = $false
if ($telegramEnabled) {
    if ([string]::IsNullOrWhiteSpace($script:telegramChatId) -or [string]::IsNullOrWhiteSpace($script:telegramToken)) {
        $msg = "Telegram включён, но ChatId или токен не заданы. Отправка логов отключена."
        Write-Warning $msg
        $preLogMessages.Add("[WARN] $msg") | Out-Null
    } else {
        $telegramReady = $true
    }
}
if ($telegramReady -and -not (Get-Command Send-TelegramMessage -ErrorAction SilentlyContinue)) {
    $msg = "Команда Send-TelegramMessage недоступна. Отправка логов в Telegram отключена."
    Write-Warning $msg
    $preLogMessages.Add("[WARN] $msg") | Out-Null
    $telegramReady = $false
}

$bases = @()
if (-not $basesDir -or -not (Test-Path -LiteralPath $basesDir)) {
    Write-Error "Не найдена папка конфигов баз: $basesDir"
    exit 1
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
                $warn = "Не удалось отправить сообщение в Telegram: $($_.Exception.Message)"
                Write-Warning $warn
                $warnLine = "[WARN] $warn"
                $warnLine | Out-File -FilePath $sessionLog -Append -Encoding UTF8
                $script:telegramErrorShown = $true
            }
        }
    }
}

Write-Log "[INFO] Запуск процесса резервного копирования..."
if ($telegramReady) {
    Write-Log ("[INFO] Telegram: логирование включено для чата {0}" -f $script:telegramChatId)
}
foreach ($msg in $preLogMessages) { Write-Log $msg }

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
