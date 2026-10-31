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
    DiscoverKubernetes = $true
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    PlanKubernetesPackages = $true
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    ConfigureKubernetesRepo = $true
    RepositoryApprovalToken = "CONFIGURE_SENTINEL_STAGE432_K8S_REPO"
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    ApplyBaseline = $true
    ApprovalToken = "APPLY_SENTINEL_STAGE42_TO_SANDBOX"
}
Assert-BlockedWith -Contains "choose exactly one Stage 4.2 or 4.3 mode" -Arguments @{
    PlanBaseline = $true
    RebootValidate = $true
}
Assert-BlockedWith -Contains "choose exactly one Stage 4.2 or 4.3 mode" -Arguments @{
    ApplyBaseline = $true
    DiscoverKubernetes = $true
}
Assert-BlockedWith -Contains "choose exactly one Stage 4.2 or 4.3 mode" -Arguments @{
    DiscoverKubernetes = $true
    PlanKubernetesPackages = $true
}
Assert-BlockedWith -Contains "choose exactly one Stage 4.2 or 4.3 mode" -Arguments @{
    ConfigureKubernetesRepo = $true
    PlanKubernetesPackages = $true
}
Assert-BlockedWith -Contains "separate Stage 4.3.2 repository approval is missing" -Arguments @{
    ConfigureKubernetesRepo = $true
}
Assert-BlockedWith -Contains "repository approval token only applies to" -Arguments @{
    RepositoryApprovalToken = "CONFIGURE_SENTINEL_STAGE432_K8S_REPO"
}
Assert-BlockedWith -Contains "explicit sandbox reboot approval is missing" -Arguments @{
    RebootValidate = $true
}
Assert-BlockedWith -Contains "explicit sandbox apply approval is missing" -Arguments @{
    ApplyBaseline = $true
}

Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    PlanKubernetesInstall = $true
}
Assert-BlockedWith -Contains "private configuration clone is missing" -Arguments @{
    InstallKubernetesPackages = $true
    InstallApprovalToken = "INSTALL_SENTINEL_STAGE432_K8S_1372"
}
Assert-BlockedWith -Contains "separate Kubernetes package installation approval missing" -Arguments @{
    InstallKubernetesPackages = $true
}
Assert-BlockedWith -Contains "installation token only valid" -Arguments @{
    InstallApprovalToken = "INSTALL_SENTINEL_STAGE432_K8S_1372"
}
Assert-BlockedWith -Contains "choose exactly one Stage 4.2 or 4.3 mode" -Arguments @{
    PlanKubernetesInstall = $true
    InstallKubernetesPackages = $true
}
Write-Host "PASS: Stage 4.2 mode and approval preflight smoke tests"
