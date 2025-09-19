#requires -Version 5.1

function Format-Bytes {
    param([Parameter(Mandatory)][decimal]$Bytes)
    $units = @('b','kb','mb','gb','tb')
    $val = [decimal]$Bytes
    $i = 0
    while ($val -ge 1024 -and $i -lt $units.Count-1) {
        $val = [math]::Round($val/1024,1)
        $i++
    }
    ("{0:N1}{1}" -f $val, $units[$i]).Replace('.',',')
}
function Format-Speed {
    param([Parameter(Mandatory)][double]$BytesPerSec)
    (Format-Bytes ([decimal]$BytesPerSec)) + '/s'
}
function Show-BarLine {
    param(
        [int]$Width = 28,
        [double]$Percent,
        [string]$doneHuman,
        [string]$totalHuman,
        [string]$speedHuman
    )
    if ($Width -lt 10) { $Width = 10 }
    $bars = [int][math]::Round(($Percent/100.0) * $Width)
    $bar = ('#' * $bars).PadRight($Width,' ')
    "{0} {1,3}% {2}/{3} {4}" -f $bar, [int]$Percent, $doneHuman, $totalHuman, $speedHuman
}

function Normalize-YandexDiskPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'disk:/' }
    $p = $Path.Trim()
    if ($p.StartsWith('disk:/')) { return $p }
    if ($p.StartsWith('/')) { return 'disk:' + $p }
    return 'disk:/' + $p.TrimStart('/')
}

function Get-YandexDiskFilesList {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$RemoteFolder
    )

    $headers   = @{ Authorization = "OAuth $Token" }
    $path      = Normalize-YandexDiskPath $RemoteFolder
    $encFolder = [Uri]::EscapeDataString($path)

    $limit  = 200
    $offset = 0
    $items  = @()

    while ($true) {
        $url = "https://cloud-api.yandex.net/v1/disk/resources?path=$encFolder&limit=$limit&offset=$offset&fields=_embedded.items.name,_embedded.items.path,_embedded.items.created,_embedded.items.modified,_embedded.items.type"
        try {
            $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
        } catch {
            $ex = $_.Exception
            $respObj = $null
            try { $respObj = $ex.Response } catch { $respObj = $null }
            if ($respObj) {
                try { if ([int]$respObj.StatusCode -eq 404) { return @() } } catch {}
            }
            if ($ex.Message -match '404') { return @() }
            throw
        }

        $batch = @()
        if ($resp._embedded -and $resp._embedded.items) {
            $batch = $resp._embedded.items | Where-Object { $_.type -eq 'file' }
        }
        $items += $batch

        if (-not $resp._embedded.items -or $resp._embedded.items.Count -lt $limit) { break }
        $offset += $limit
    }

    return $items
}

function Cleanup-YandexDiskFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$RemoteFolder,
        [Parameter(Mandatory)][int]$Keep
    )

    $keepCount = [math]::Max(0, [int]$Keep)
    $files = Get-YandexDiskFilesList -Token $Token -RemoteFolder $RemoteFolder
    if (-not $files -or $files.Count -le $keepCount) { return @() }

    $headers = @{ Authorization = "OAuth $Token" }
    $sorted = $files | Sort-Object @{Expression={
                if ($_.created) { [datetime]$_.created }
                elseif ($_.modified) { [datetime]$_.modified }
                else { [datetime]::MinValue }
            };Descending=$true}

    if ($sorted.Count -le $keepCount) { return @() }

    $deleted = @()
    for ($i = $keepCount; $i -lt $sorted.Count; $i++) {
        $item = $sorted[$i]
        $pathRaw = if ($item.path) { $item.path } else { "{0}/{1}" -f $RemoteFolder.TrimEnd('/'), $item.name }
        $path = Normalize-YandexDiskPath $pathRaw
        $enc = [Uri]::EscapeDataString($path)
        $url = "https://cloud-api.yandex.net/v1/disk/resources?path=$enc&permanently=true"
        try {
            Invoke-RestMethod -Uri $url -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
            $deleted += $item.name
        } catch {
            throw
        }
    }

    return $deleted
}

function Upload-ToYandexDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath,
        [int]$ChunkSize = 4MB,
        [int]$BarWidth  = 28
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "Файл не найден: $LocalPath"
    }
    $fileInfo = Get-Item -LiteralPath $LocalPath
    $total = [long]$fileInfo.Length
    $done  = 0L

    $encPath = [Uri]::EscapeDataString($RemotePath)
    $headers = @{ Authorization = "OAuth $Token" }

    # 1) получить URL
    $url = "https://cloud-api.yandex.net/v1/disk/resources/upload?path=$encPath&overwrite=true"
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
    if (-not $resp.href) { throw "Не удалось получить URL загрузки" }
    $putUrl = $resp.href

    # 2) PUT потоково
    $req = [System.Net.HttpWebRequest]::Create($putUrl)
    $req.Method = "PUT"
    $req.AllowWriteStreamBuffering = $false
    $req.SendChunked = $true
    $req.Timeout = 10*60*1000
    $req.ReadWriteTimeout = 10*60*1000
    $req.ContentLength = $total

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastTick = 0L

    $fs = [System.IO.File]::OpenRead($LocalPath)
    try {
        $reqStream = $req.GetRequestStream()
        try {
            $buffer = New-Object byte[] $ChunkSize
            while ($true) {
                $read = $fs.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $reqStream.Write($buffer, 0, $read)
                $done += $read

                # прогресс
                $elapsed = [math]::Max(0.2, $sw.Elapsed.TotalSeconds)
                $speed   = ($done - $lastTick) / $elapsed
                $lastTick = $done
                $sw.Restart()

                $pct  = if ($total -gt 0) { 100.0 * $done / $total } else { 0 }
                $line = Show-BarLine -Width $BarWidth -Percent $pct `
                        -doneHuman (Format-Bytes $done) `
                        -totalHuman (Format-Bytes $total) `
                        -speedHuman (Format-Speed $speed)

                try {
                    # корректная перерисовка строки
                    $raw = $Host.UI.RawUI
                    $pos = $raw.CursorPosition
                    $pos.X = 0
                    $raw.CursorPosition = $pos
                    $w = $raw.BufferSize.Width
                    Write-Host ($line.PadRight([math]::Max($w,120))) -NoNewline
                } catch {
                    # запасной путь
                    Write-Host "`r$line" -NoNewline
                }
            }
        } finally { $reqStream.Close() }

        $resp2 = $req.GetResponse()
        $resp2.Close()
        Write-Host ""
    }
    finally {
        $fs.Close()
    }
}

Export-ModuleMember -Function Upload-ToYandexDisk, Cleanup-YandexDiskFolder
