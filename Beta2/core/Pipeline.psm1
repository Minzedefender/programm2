# core/Pipeline.psm1
#requires -Version 5.1

$ModulesRoot = Join-Path $PSScriptRoot '..\modules'
Import-Module -Force -DisableNameChecking (Join-Path $ModulesRoot 'Common.Crypto.psm1') -ErrorAction Stop
if (Test-Path (Join-Path $ModulesRoot 'Cloud.YandexDisk.psm1')) {
    Import-Module -Force -DisableNameChecking (Join-Path $ModulesRoot 'Cloud.YandexDisk.psm1') -ErrorAction SilentlyContinue
}

function ConvertTo-Hashtable {
    param([Parameter(Mandatory)]$Object)
    if ($Object -is [hashtable]) { return $Object }
    $ht = @{}
    $Object.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

function Wait-FileStable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSec = 3600,
        [int]$PollSec    = 2,
        [int]$StableTicks= 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = -1L; $stable = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $len = (Get-Item -LiteralPath $Path).Length
            if ($len -gt 0 -and $len -eq $last) {
                $stable++
                if ($stable -ge $StableTicks) { return $true }
            } else {
                $stable = 0
                $last = $len
            }
        }
        Start-Sleep -Seconds $PollSec
    }
    return $false
}

function Get-ShortPath([string]$Path){
    $sig = @'
using System;
using System.Runtime.InteropServices;
public static class SP {
 [DllImport("kernel32.dll", CharSet=CharSet.Auto)]
 public static extern int GetShortPathName(string l, System.Text.StringBuilder s, int b);
}
'@
    if (-not ([System.Management.Automation.PSTypeName]'SP').Type) { Add-Type $sig -ErrorAction SilentlyContinue | Out-Null }
    try {
        $sb = New-Object System.Text.StringBuilder 260
        [void][SP]::GetShortPathName($Path, $sb, $sb.Capacity)
        $sp = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($sp)) { return $Path }
        return $sp
    } catch { return $Path }
}

function Find-1CDesignerExe {
    $roots = @('HKLM:\SOFTWARE\1C\1Cv8','HKLM:\SOFTWARE\WOW6432Node\1C\1Cv8')
    foreach ($r in $roots) {
        if (Test-Path $r) {
            foreach ($k in (Get-ChildItem $r -ErrorAction SilentlyContinue)) {
                $bin = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).BinDir
                if ($bin -and (Test-Path $bin)) {
                    $exe = Join-Path $bin '1cv8.exe'
                    if (Test-Path $exe) { return $exe }
                }
            }
        }
    }
    return $null
}

function BuildArgsLine-F([string]$srcFolder,[string]$artifact,[string]$logFile,[string]$login,[string]$password){
    $parts = @('DESIGNER','/F',('"{0}"' -f $srcFolder),'/DisableStartupMessages','/DumpIB',('"{0}"' -f $artifact),'/Out',('"{0}"' -f $logFile))
    if ($login)    { $parts += @('/N',('"{0}"' -f $login)) }
    if ($password) { $parts += @('/P',('"{0}"' -f $password)) }
    ($parts -join ' ')
}
function BuildArgsLine-IBCS([string]$srcFolder,[string]$artifact,[string]$logFile,[string]$login,[string]$password){
    $srcEsc = $srcFolder.Replace('"','""')
    $conn = 'File="{0}";' -f $srcEsc
    $parts = @('DESIGNER','/IBConnectionString',('"{0}"' -f $conn),'/DisableStartupMessages','/DumpIB',('"{0}"' -f $artifact),'/Out',('"{0}"' -f $logFile))
    if ($login)    { $parts += @('/N',('"{0}"' -f $login)) }
    if ($password) { $parts += @('/P',('"{0}"' -f $password)) }
    ($parts -join ' ')
}

function Invoke-Pipeline {
    param([Parameter(Mandatory)][hashtable]$Ctx)

    $log = $Ctx.Log
    $tag = $Ctx.Tag
    & $log ("Начало бэкапа")
    & $log ("База: {0}" -f $tag)

    $configRoot = $null
    if ($Ctx.ContainsKey('ConfigRoot') -and $Ctx['ConfigRoot']) {
        $configRoot = [string]$Ctx['ConfigRoot']
    } else {
        $baseRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
        if ($baseRoot) { $configRoot = Join-Path -Path $baseRoot -ChildPath '..\config' }
    }

    $configDir = $null
    if ($Ctx.ContainsKey('ConfigDir') -and $Ctx['ConfigDir']) {
        $configDir = [string]$Ctx['ConfigDir']
    } elseif ($configRoot) {
        $configDir = Join-Path -Path $configRoot -ChildPath 'bases'
    }

    $configFile  = if ($configDir) { Join-Path -Path $configDir -ChildPath ("{0}.json" -f $tag) } else { $null }
    $keyPath     = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'key.bin' } else { $null }
    $secretsPath = if ($configRoot) { Join-Path -Path $configRoot -ChildPath 'secrets.json.enc' } else { $null }

    if (-not $configFile -or -not (Test-Path -LiteralPath $configFile)) { throw "Конфиг базы '$tag' не найден: $configFile" }

    $config  = ConvertTo-Hashtable (Get-Content $configFile -Raw | ConvertFrom-Json)
    # >>> пропуск отключенных баз
    if ($config.ContainsKey('Disabled') -and $config['Disabled']) {
        & $log ("База [{0}] отключена (Disabled=true) — пропуск." -f $tag)
        return $null
    }

    $secrets = @{}
    if ($Ctx.ContainsKey('Secrets') -and $Ctx['Secrets']) {
        $secrets = ConvertTo-Hashtable $Ctx['Secrets']
    }
    elseif ($secretsPath -and (Test-Path -LiteralPath $secretsPath) -and $keyPath -and (Test-Path -LiteralPath $keyPath)) {
        try { $secrets = ConvertTo-Hashtable (Decrypt-Secrets -InFile $secretsPath -KeyPath $keyPath) } catch { $secrets = @{} }
    }

    $type       = ("" + $config['BackupType']).ToUpper()
    $src        = $config['SourcePath']
    $dstDir     = $config['DestinationPath']
    $exeCfg     = $config['ExePath']
    $keep       = 0 + ($config['Keep'])
    $useCloud   = ("" + $config['CloudType']) -eq 'Yandex.Disk'
    $cloudCleanup = $false
    if ($config.ContainsKey('CloudCleanup')) { $cloudCleanup = [bool]$config['CloudCleanup'] }
    $dumpTimeoutMin = [int]$config['DumpTimeoutMin']; if ($dumpTimeoutMin -le 0) { $dumpTimeoutMin = 60 }

    if ([string]::IsNullOrWhiteSpace($src))    { throw "Не задан SourcePath в конфиге" }
    if ([string]::IsNullOrWhiteSpace($dstDir)) { throw "Не задан DestinationPath в конфиге" }
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

    $ts  = Get-Date -Format 'yyyy_MM_dd_HHmm'
    $ext = if ($type -eq 'DT') { 'dt' } else { '1CD' }
    $artifact = Join-Path $dstDir ("{0}_{1}.{2}" -f $tag, $ts, $ext)

    $stopped = @()
    try {
        if ($type -eq 'DT') {
            # список служб для лога
            $stopSvcsStr = '—'
            if ($config.ContainsKey('StopServices') -and $config['StopServices']) {
                $stopSvcsStr = ($config['StopServices'] -join ', ')
            }
            & $log ("Остановка служб: {0}" -f $stopSvcsStr)

            if ($config.ContainsKey('StopServices') -and $config['StopServices']) {
                foreach ($name in @($config['StopServices'])) {
                    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                    if ($null -ne $svc -and $svc.Status -ne 'Stopped') {
                        try { Stop-Service -Name $svc.Name -Force -ErrorAction Stop; $svc.WaitForStatus('Stopped','00:00:30'); $stopped += $svc.Name } catch {}
                    }
                }
            }

            & $log ("Выгрузка в формате DT (таймаут {0} мин)..." -f $dumpTimeoutMin)

            # выбираем exe: сначала ExePath из конфига (обычно 1cestart.exe), затем авто 1cv8.exe
            $exe = $null
            if ($exeCfg -and (Test-Path $exeCfg)) { $exe = $exeCfg } else { $exe = Find-1CDesignerExe }
            if (-not $exe) { throw "Не найден исполняемый файл 1С (ни ExePath из конфига, ни 1cv8.exe из реестра)" }

            # логин/пароль из secrets
            $loginKey = "{0}__DT_Login"    -f $tag
            $passKey  = "{0}__DT_Password" -f $tag
            $login    = if ($secrets.ContainsKey($loginKey)) { [string]$secrets[$loginKey] } else { $null }
            $password = if ($secrets.ContainsKey($passKey))  { [string]$secrets[$passKey] }  else { $null }

            if ($login) {
                & $log "Логин 1С получен из секретов."
            } else {
                & $log "Логин 1С в секретах не найден — запуск без указания пользователя."
            }
            if ($password) {
                & $log "Пароль 1С найден в секретах."
            } else {
                & $log "Пароль 1С в секретах отсутствует."
            }

            $srcFolder = (Resolve-Path -LiteralPath $src).Path
            $srcFolder = $srcFolder.TrimEnd('\','/')
            $logFile   = Join-Path $dstDir ("{0}_{1}.designer.log" -f $tag,$ts)

            # Попытка 1: /F с коротким 8.3 путём
            $srcF83 = Get-ShortPath $srcFolder
            $argsF  = BuildArgsLine-F $srcF83 $artifact $logFile $login $password
            Start-Process -FilePath $exe -ArgumentList $argsF -WindowStyle Hidden | Out-Null
            $ok = Wait-FileStable -Path $artifact -TimeoutSec ($dumpTimeoutMin*60)

            if (-not $ok) {
                # Попытка 2: IBConnectionString
                $argsIB = BuildArgsLine-IBCS $srcFolder $artifact $logFile $login $password
                Start-Process -FilePath $exe -ArgumentList $argsIB -WindowStyle Hidden | Out-Null
                $ok = Wait-FileStable -Path $artifact -TimeoutSec ($dumpTimeoutMin*60)
                if (-not $ok) {
                    if (Test-Path $logFile) { throw "Не дождались выгрузки за $dumpTimeoutMin мин. См. лог: $logFile" }
                    else                    { throw "Не дождались выгрузки за $dumpTimeoutMin мин" }
                }
            }
        }
        elseif ($type -eq '1CD') {
            & $log ("Копирование файла .1CD...")
            Copy-Item -LiteralPath $src -Destination $artifact -Force -ErrorAction Stop
        }
        else {
            throw "Неизвестный тип бэкапа: $type (ожидалось '1CD' или 'DT')"
        }

        & $log ("Файл бэкапа: {0}" -f $artifact)

        # === ЧИСТКА ЛОКАЛЬНО (ТОЛЬКО АРХИВЫ ТЕКУЩЕГО ТИПА) ===
        if ($keep -gt 0) {
            $mask = ("{0}_*.{1}" -f $tag, $ext)
            $all = Get-ChildItem -Path $dstDir -Filter $mask -File | Sort-Object LastWriteTime -Descending
            if ($all.Count -gt $keep) {
                $toDel = $all[$keep..($all.Count-1)]
                foreach ($f in $toDel) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    & $log ("Удалён старый локальный бэкап: {0}" -f $f.Name)
                }
            }
        }

        # Облако
        if ($useCloud -and (Get-Command Upload-ToYandexDisk -ErrorAction SilentlyContinue)) {
            $tokenKey = "{0}__YADiskToken" -f $tag
            if ($secrets.ContainsKey($tokenKey) -and $secrets[$tokenKey]) {
                $token = $secrets[$tokenKey]
                $remoteFolder = "/Backups1C/$tag"
                $remoteName   = Split-Path $artifact -Leaf
                & $log ("Выгрузка в облако Я.Диск")
                Upload-ToYandexDisk -Token $token -LocalPath $artifact -RemotePath "$remoteFolder/$remoteName" -BarWidth 28
                & $log ("Выгрузка в облако Я.Диск завершена")
                if ($cloudCleanup -and $keep -gt 0 -and (Get-Command Cleanup-YandexDiskFolder -ErrorAction SilentlyContinue)) {
                    try {
                        $deletedRemote = Cleanup-YandexDiskFolder -Token $token -RemoteFolder $remoteFolder -Keep $keep
                        foreach ($name in $deletedRemote) {
                            & $log ("Удалён старый облачный бэкап: {0}" -f $name)
                        }
                    } catch {
                        & $log ("Не удалось очистить облако Я.Диск: {0}" -f $_.Exception.Message)
                    }
                }
            } else {
                & $log ("ВНИМАНИЕ: включено облако, но токен для [{0}] не найден" -f $tag)
            }
        }

        & $log ("=== Успешно завершено [{0}] ===" -f $tag)
        return $artifact
    }
    catch {
        throw ("Сбой бэкапа [{0}]: {1}" -f $tag, $_.Exception.Message)
    }
    finally {
        if ($stopped.Count -gt 0) {
            foreach ($n in $stopped) {
                try {
                    Start-Service -Name $n -ErrorAction Stop
                    (Get-Service -Name $n).WaitForStatus('Running','00:00:30')
                } catch {}
            }
        }
    }
}

Export-ModuleMember -Function Invoke-Pipeline
