# limits-probe.ps1 — empirical context/output limit discovery for DeepseekFreeAPI
#
# Usage:
#   .\tests\limits-probe.ps1                     # probes http://127.0.0.1:3020
#   .\tests\limits-probe.ps1 -BaseUrl http://127.0.0.1:3010
#
# How it works:
#  - CONTEXT: sends prompts of increasing size (filler text) with a secret
#    marker at the very start and a question at the end asking the model to
#    repeat the marker. If the marker comes back, the whole prompt fit the
#    context window. Binary-searches the failure boundary.
#  - OUTPUT: asks the model to print consecutive integers one per line until
#    it is cut off; the highest number reached approximates output tokens.
#
# Token counts are ESTIMATES (~1 token per common English word in the filler).

param(
    [string]$BaseUrl = "http://127.0.0.1:3020",
    [string]$ApiKey  = "cualquier-valor",
    [string[]]$Models = @("deepseek-v4-flash", "deepseek-v4-pro")
)

$ErrorActionPreference = "Continue"

function Send-Chat {
    param([string]$Model, [string]$Content, [int]$TimeoutSec = 420)
    $payload = @{
        model    = $Model
        messages = @(@{ role = "user"; content = $Content })
        stream   = $false
        search   = $false
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/v1/chat/completions" -Method Post `
            -Headers @{ Authorization = "Bearer $ApiKey"; "Content-Type" = "application/json" } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec $TimeoutSec
        return @{ ok = $true; reply = [string]$r.choices[0].message.content }
    } catch {
        $detail = $_.ErrorDetails.Message
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        return @{ ok = $false; status = $status; error = "$($_.Exception.Message) | $detail" }
    }
}

# filler unit: 9 common English words ~ 9-11 tokens
$unit = "The quick brown fox jumps over the lazy dog. "
$unitWords = 9

function Build-Prompt {
    param([int]$Words, [string]$Marker)
    $repeats = [math]::Ceiling($Words / $unitWords)
    $filler = [string]::Join("", [System.Linq.Enumerable]::Repeat($unit, $repeats))
    return "SECRET MARKER: $Marker. Remember it.`n`n$filler`n`nQuestion: what was the secret marker at the very beginning of this message? Reply with ONLY the marker text, nothing else."
}

function Test-ContextSize {
    param([string]$Model, [int]$Words, [string]$Marker)
    $prompt = Build-Prompt -Words $Words -Marker $Marker
    Write-Host ("  [{0}] probe {1:N0} words (~{2:N0} tokens, {3:N1} MB)..." -f $Model, $Words, $Words, ($prompt.Length / 1MB)) -NoNewline
    $r = Send-Chat -Model $Model -Content $prompt
    if (-not $r.ok) {
        Write-Host " ERROR: $($r.error.Substring(0, [math]::Min(180, $r.error.Length)))"
        return "error"
    }
    if ($r.reply -like "*$Marker*") {
        Write-Host " OK (marker recalled)"
        return "ok"
    }
    Write-Host " MARKER LOST (reply: $($r.reply.Substring(0, [math]::Min(60, $r.reply.Length))))"
    return "lost"
}

function Find-ContextLimit {
    param([string]$Model)
    Write-Host "`n=== CONTEXT LIMIT: $Model ==="
    $marker = "ZEBRA-" + (Get-Random -Maximum 99999)

    # phase 1: exponential bracket
    $lastOk = 0
    $words = 8192
    $fail = $null
    while ($words -le 524288) {
        $res = Test-ContextSize -Model $Model -Words $words -Marker $marker
        if ($res -eq "ok") {
            $lastOk = $words
            $words *= 2
        } else {
            $fail = $words
            break
        }
    }
    if ($null -eq $fail) {
        Write-Host "  no failure up to $lastOk words — context >= ~$lastOk tokens"
        return @{ okWords = $lastOk; failWords = -1 }
    }

    # phase 2: binary search between lastOk and fail
    $lo = $lastOk; $hi = $fail
    $iter = 0
    while (($hi - $lo) -gt 2048 -and $iter -lt 7) {
        $mid = [int](($lo + $hi) / 2)
        $marker2 = "ZEBRA-" + (Get-Random -Maximum 99999)
        $res = Test-ContextSize -Model $Model -Words $mid -Marker $marker2
        if ($res -eq "ok") { $lo = $mid } else { $hi = $mid }
        $iter++
    }
    Write-Host ("  -> boundary: OK up to ~{0:N0} words (~{0:N0}+ tokens est.), fails around ~{1:N0}" -f $lo, $hi)
    return @{ okWords = $lo; failWords = $hi }
}

function Find-OutputLimit {
    param([string]$Model)
    Write-Host "`n=== OUTPUT LIMIT: $Model ==="
    $content = "Write consecutive integers starting from 1, one per line (1, 2, 3, ...). " +
               "Keep going as long as the system allows. Do NOT stop early, do NOT write anything besides the numbers."
    Write-Host "  requesting maximal numeric output..."
    $r = Send-Chat -Model $Model -Content $content -TimeoutSec 600
    if (-not $r.ok) {
        Write-Host "  ERROR: $($r.error)"
        return -1
    }
    $nums = [regex]::Matches($r.reply, "(?m)^\s*(\d+)\s*$") | ForEach-Object { [int]$_.Groups[1].Value }
    $max = 0
    if ($nums.Count -gt 0) { $max = ($nums | Measure-Object -Maximum).Maximum }
    Write-Host ("  -> reply length {0:N0} chars, {1:N0} lines, highest number ~{2:N0} (~{2:N0} output tokens est.)" -f $r.reply.Length, $nums.Count, $max)
    return $max
}

# ── main ──────────────────────────────────────────────────────────────────────
$results = @{}
foreach ($m in $Models) {
    $ctx = Find-ContextLimit -Model $m
    $out = Find-OutputLimit -Model $m
    $results[$m] = @{ context = $ctx; output = $out }
}

Write-Host "`n=== SUMMARY ==="
foreach ($m in $Models) {
    $r = $results[$m]
    $ctxOk = $r.context.okWords; $ctxFail = $r.context.failWords
    $ctxStr = if ($ctxFail -lt 0) { ">= ~$ctxOk tokens" } else { "~$ctxOk..$ctxFail tokens" }
    Write-Host ("{0}: context {1} | output ~{2:N0} tokens" -f $m, $ctxStr, $r.output)
}
