<#
Run the 4 synthetic evaluation cases against a local Sentinel API.
The runner measures retrieval/completion/formal checks, NOT AI factual accuracy.
Manual review of the captured model outputs is essential.
#>
param(
    [string]$BaseUrl = "http://127.0.0.1:8000"
)

$ErrorActionPreference = "Stop"
$casesPath = Join-Path $PSScriptRoot "cases/day2-v1.json"
$dataset = Get-Content -LiteralPath $casesPath -Raw | ConvertFrom-Json
$records = @()

foreach ($case in $dataset.cases) {
    Write-Host ("Running " + $case.id + " ...")
    $expected = [string]$case.expected_source
    $record = [ordered]@{
        case_id = $case.id
        expected_source = $expected
        actual_source = ""
        retrieval_passed = $false
        completion_reason = $null
        response_check_status = $null
        warnings = @()
        request_id = $null
        latency_seconds = $null
        human_review_status = "not_reviewed"
        manual_review_guide = $case.review_guide
        analysis = $null
        error = $null
    }

    try {
        $body = $case.incident | ConvertTo-Json -Compress -Depth 5
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-RestMethod -Uri "$BaseUrl/api/investigate" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 150
        $clock.Stop()
        $actual = if (@($result.sources).Count -gt 0) { [string]$result.sources[0].id } else { "" }
        $record.actual_source = $actual
        $record.retrieval_passed = ($actual -eq $expected)
        $record.completion_reason = $result.completion_reason
        $record.response_check_status = $result.response_checks.status
        $record.warnings = @($result.response_checks.warnings)
        $record.request_id = $result.request_id
        $record.latency_seconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
        $record.analysis = $result.analysis
    } catch {
        $record.error = $_.Exception.Message
    }
    $records += [PSCustomObject]$record
}

$reportsDir = Join-Path $PSScriptRoot "reports"
New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outPath = Join-Path $reportsDir "day2-v1-$stamp.json"

$report = [ordered]@{
    dataset_version = $dataset.dataset_version
    timestamp_local = (Get-Date).ToString("o")
    api_base_url = $BaseUrl
    model_output_is_unverified = $true
    cases = $records
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outPath -Encoding utf8

$records |
    Select-Object case_id, expected_source, actual_source, retrieval_passed, completion_reason, response_check_status |
    Format-Table -AutoSize

$passed = @($records | Where-Object { $_.retrieval_passed -and -not $_.error }).Count
Write-Host "Retrieval accuracy on these $($records.Count) labelled cases: $passed/$($records.Count)"
Write-Host "Report saved locally: $outPath"
Write-Host "IMPORTANT: Inspect each analysis against its manual_review_guide. Formal checks DO NOT validate factual correctness."
if ($passed -ne $records.Count) {
    Write-Warning "One or more retrieval cases failed or returned errors. See report."
}
