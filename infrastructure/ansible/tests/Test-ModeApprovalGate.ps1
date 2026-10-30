#Requires -Version 5.1
<#
Smoke-test the real entrypoint's mode and token preflight under StrictMode.
Always supplies a missing local private config path so no WSL or VM call is made.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "..\Invoke-SentinelReadiness.ps1"
$unavailable = Join-Path $env:TEMP "sentinel-stage42-test-config-never-created"
if (Test-Path -LiteralPath $unavailable) {
    throw "Unsafe test prerequisite: expected absent config path"
}

function Assert-BlockedWith {
    param([string]$Contains, [hashtable]$Arguments)
    try {
        & $runner -ConfigRepo $unavailable @Arguments
        throw "Unexpectedly permitted a blocked invocation"
    } catch {
        if (-not $_.Exception.Message.Contains($Contains)) {
            throw "Unexpected approval preflight result: $($_.Exception.Message)"
        }
    }
}

Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    RebootValidate = $true
    RebootApprovalToken = "REBOOT_SENTINEL_STAGE42_SANDBOX"
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    PlanBaseline = $true
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    ApplyBaseline = $true
    ApprovalToken = "APPLY_SENTINEL_STAGE42_TO_SANDBOX"
}
Assert-BlockedWith -Contains "choose plan, apply or reboot validation" -Arguments @{
    PlanBaseline = $true
    RebootValidate = $true
}
Assert-BlockedWith -Contains "explicit sandbox reboot approval is missing" -Arguments @{
    RebootValidate = $true
}
Assert-BlockedWith -Contains "explicit sandbox apply approval is missing" -Arguments @{
    ApplyBaseline = $true
}

Write-Host "PASS: Stage 4.2 mode and approval preflight smoke tests"
