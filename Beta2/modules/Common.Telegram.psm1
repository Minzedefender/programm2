#requires -Version 5.1

try {
    $currentProto = [Net.ServicePointManager]::SecurityProtocol
    if (($currentProto -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
        [Net.ServicePointManager]::SecurityProtocol = $currentProto -bor [Net.SecurityProtocolType]::Tls12
    }
} catch {
    # ignore TLS adjustments errors
}

function Split-TelegramChunks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$ChunkSize = 3500
    )

    if ($ChunkSize -le 0) { $ChunkSize = 3500 }
    $result = @()
    $remaining = $Text
    while ($remaining.Length -gt $ChunkSize) {
        $result += $remaining.Substring(0, $ChunkSize)
        $remaining = $remaining.Substring($ChunkSize)
    }
    if ($remaining.Length -gt 0 -or $result.Count -eq 0) {
        $result += $remaining
    }
    return $result
}

function Send-TelegramMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [switch]$DisableNotification
    )

    if ([string]::IsNullOrWhiteSpace($Token))  { throw "Token не задан" }
    if ([string]::IsNullOrWhiteSpace($ChatId)) { throw "ChatId не задан" }

    $uri = "https://api.telegram.org/bot$Token/sendMessage"
    $chunks = Split-TelegramChunks -Text $Text

    foreach ($chunk in $chunks) {
        $body = @{ chat_id = $ChatId; text = $chunk }
        if ($DisableNotification) { $body.disable_notification = $true }
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop | Out-Null
    }
}

Export-ModuleMember -Function Send-TelegramMessage
