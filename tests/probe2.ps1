# probe2.ps1 — follow-up: confirm output caps + extend flash context probe
param([string]$BaseUrl = "http://127.0.0.1:3020", [string]$ApiKey = "cualquier-valor")

function Send-Chat {
    param([string]$Model, [string]$Content, [int]$TimeoutSec = 600)
    $payload = @{
        model = $Model
        messages = @(@{ role = "user"; content = $Content })
        stream = $false
        search = $false
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/v1/chat/completions" -Method Post `
            -Headers @{ Authorization = "Bearer $ApiKey"; "Content-Type" = "application/json" } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec $TimeoutSec
        return @{ ok = $true; reply = [string]$r.choices[0].message.content }
    } catch {
        return @{ ok = $false; error = "$($_.Exception.Message) | $($_.ErrorDetails.Message)" }
    }
}

function Measure-Numbers($text) {
    $nums = [regex]::Matches($text, "(?m)^\s*(\d+)\s*$") | ForEach-Object { [int]$_.Groups[1].Value }
    if ($nums.Count -eq 0) { return 0 }
    return ($nums | Measure-Object -Maximum).Maximum
}

$hard = "MANDATORY: list every integer from 1 to 20000, one per line, with no other text. " +
        "You MUST NOT stop before 20000. If you stop early the answer is invalid. Go:"

foreach ($m in @("deepseek-v4-flash", "deepseek-v4-pro")) {
    Write-Host "`n=== OUTPUT re-test: $m ==="
    foreach ($i in 1..2) {
        Write-Host "  attempt $i ..."
        $r = Send-Chat -Model $m -Content $hard
        if (-not $r.ok) { Write-Host "  ERROR: $($r.error.Substring(0,[math]::Min(200,$r.error.Length)))"; continue }
        $max = Measure-Numbers $r.reply
        Write-Host ("  -> {0:N0} chars, reached number ~{1:N0}" -f $r.reply.Length, $max)
        Write-Host ("  tail: ..." + ($r.reply.Substring([math]::Max(0, $r.reply.Length - 60))) -replace "`n", "|")
    }
}

Write-Host "`n=== CONTEXT extension: deepseek-v4-flash @ 786432 words (~3.7MB) ==="
$unit = "The quick brown fox jumps over the lazy dog. "
$marker = "FALCON-" + (Get-Random -Maximum 99999)
$filler = [string]::Join("", [System.Linq.Enumerable]::Repeat($unit, [math]::Ceiling(786432 / 9)))
$prompt = "SECRET MARKER: $marker. Remember it.`n`n$filler`n`nQuestion: what was the secret marker at the very beginning? Reply with ONLY the marker."
Write-Host ("  prompt size: {0:N1} MB" -f ($prompt.Length / 1MB))
$r = Send-Chat -Model "deepseek-v4-flash" -Content $prompt
if (-not $r.ok) {
    Write-Host "  ERROR: $($r.error.Substring(0,[math]::Min(300,$r.error.Length)))"
} elseif ($r.reply -like "*$marker*") {
    Write-Host "  OK (marker recalled) — context >= ~786k words (~1M tokens est.)"
} else {
    Write-Host "  MARKER LOST: $($r.reply.Substring(0,[math]::Min(100,$r.reply.Length)))"
}
