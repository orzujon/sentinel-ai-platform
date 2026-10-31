#Requires -Version 5.1
<#
.SYNOPSIS
    Sentinel Infrastructure Provisioning Pipeline (v1 preflight-only entry point).
.DESCRIPTION
    Read-only host checks and observable report. It cannot create, stop, delete or reconfigure VMs.
.EXAMPLE
    .\sentinel.ps1 preflight
.EXAMPLE
    .\sentinel.ps1 runs
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('preflight','runs','image-discover','prepare-images','verify-image','infra-plan','infra-provision','infra-verify','bootstrap-plan','bootstrap-verify')]
    [string]$Command = 'preflight',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\lab.json'),
    [string]$ConfigRepo = 'C:\Sentinel\config-readonly'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stage 5 entry point: classify existing or clean sandbox, with no mutation.
if ($Command -in @('bootstrap-plan','bootstrap-verify')) {
    # Stage 5 planning uses immutable, public-safe sandbox identity and needs
    # no local credentials or legacy Stage 1-3 JSON. A supplied config may
    # supplement future phases, but never overrides the pinned identity.
    $bootstrapConfig = [pscustomobject]@{
        lab = 'sentinel-l1-sandbox'
        mode = 'isolated-sandbox'
        network = [pscustomobject]@{ switch = 'Sentinel-L1'; type = 'Internal' }
        paths = [pscustomobject]@{ vmRoot = 'C:\Sentinel\Level1-Sandbox\VMs' }
        vms = @(
            [pscustomobject]@{ name = 'sentinel-l1-cp01' },
            [pscustomobject]@{ name = 'sentinel-l1-w01' }
        )
        protection = [pscustomobject]@{ vmNames = @('k8s-cp01','k8s-w01') }
    }
    $bootstrapSource = 'pinned-sandbox-contract'
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $provided = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($provided.lab -cne $bootstrapConfig.lab -or
            $provided.mode -cne $bootstrapConfig.mode -or
            $provided.network.switch -cne $bootstrapConfig.network.switch -or
            $provided.network.type -cne $bootstrapConfig.network.type -or
            $provided.paths.vmRoot -cne $bootstrapConfig.paths.vmRoot -or
            ((@($provided.vms | ForEach-Object { $_.name }) | Sort-Object) -join ',') -cne
            ((@($bootstrapConfig.vms | ForEach-Object { $_.name }) | Sort-Object) -join ',')) {
            throw 'BLOCKED: supplied legacy config disagrees with the pinned Stage 5 sandbox identity'
        }
        $bootstrapSource = $ConfigPath
    }
    $bootstrapRun = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $bootstrapDir = Join-Path (Join-Path $PSScriptRoot 'runs') $bootstrapRun
    Import-Module (Join-Path $PSScriptRoot 'src\Sentinel.Bootstrap.psm1') -Force
    if ($Command -eq 'bootstrap-verify') {
        $stage4 = Join-Path $PSScriptRoot '..\ansible\Invoke-SentinelReadiness.ps1'
        $verified = Invoke-SentinelBootstrapVerify -Config $bootstrapConfig -RunDirectory $bootstrapDir -Stage4Script $stage4 -ConfigRepo $ConfigRepo
        Write-Host "Sentinel Level 1 Stage 5 existing verification: $($verified.Result)"
        Write-Host "Reason: $($verified.Reason)"
        Write-Host "Report: $($verified.ReportPath)"
        if ($verified.Result -ne 'VERIFIED') { exit 2 }
        exit 0
    }
    $bootstrapResult = Invoke-SentinelBootstrapPlan -Config $bootstrapConfig -RunDirectory $bootstrapDir -ConfigPath $bootstrapSource
    Write-Host "Sentinel Level 1 Stage 5 bootstrap plan: $($bootstrapResult.Result)"
    Write-Host "Route: $($bootstrapResult.Route)"
    Write-Host "Reason: $($bootstrapResult.Reason)"
    Write-Host "Report: $($bootstrapResult.ReportPath)"
    Write-Host "No Hyper-V or guest configuration was modified."
    if ($bootstrapResult.Result -eq 'BLOCKED') { exit 2 }
    exit 0
}
# SENTINEL_STAGE2_DISPATCH_V1
if ($Command -in @('image-discover', 'prepare-images', 'verify-image')) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration missing: $ConfigPath" }
    $imageConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $imageRunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $imageRunDir = Join-Path (Join-Path $PSScriptRoot 'runs') $imageRunId
    Import-Module (Join-Path $PSScriptRoot 'src\Sentinel.Images.psm1') -Force
    $op = switch ($Command) {
        'image-discover' { 'discover' }
        'prepare-images' { 'prepare' }
        'verify-image' { 'verify' }
    }
    Write-Host "`nSentinel L1 / Stage 2 image $op / run $imageRunId" -ForegroundColor Cyan
    $result = Invoke-SentinelImageStage -Config $imageConfig -RunDirectory $imageRunDir -Operation $op
    $result.Checks | Format-Table Check, Status, Detail -AutoSize -Wrap
    Write-Host "Result: $($result.Result) / $($result.Reason)"
    if ($result.CandidateSha256) { Write-Host "Upstream candidate digest (NOT APPROVED): $($result.CandidateSha256)" }
    if ($result.Artifact) { Write-Host "Verified artifact: $($result.Artifact)" }
    Write-Host "Evidence: $($result.ReportPath)"
    if ($result.Result -eq 'BLOCKED') { exit 2 }
    exit 0
}
# SENTINEL_STAGE3_DISPATCH_V1
if ($Command -in @('infra-plan','infra-provision','infra-verify')) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing config: $ConfigPath" }
    $infraConfig=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $infraRun=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $infraDir=Join-Path (Join-Path $PSScriptRoot 'runs') $infraRun
    Import-Module (Join-Path $PSScriptRoot 'src\Sentinel.Infrastructure.psm1') -Force
    $infraOp=switch ($Command) {
        'infra-plan' { 'plan' }
        'infra-provision' { 'apply' }
        'infra-verify' { 'verify' }
    }
    Write-Host "Sentinel Level 1 Stage 3: $infraOp (run $infraRun)" -ForegroundColor Cyan
    $infraResult=Invoke-SentinelInfrastructure -Config $infraConfig -RunDirectory $infraDir -Operation $infraOp -ToolsPath (Join-Path $PSScriptRoot 'src')
    Write-Host "Result: $($infraResult.Result) - $($infraResult.Reason)"
    Write-Host "Report: $($infraResult.ReportPath)"
    if ($infraResult.Result -eq 'BLOCKED') { exit 2 }
    exit 0
}
if ($Command -eq 'runs') {
    $runRoot = Join-Path $PSScriptRoot 'runs'
    Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object {
            $report = Join-Path $_.FullName 'preflight.json'
            if (-not (Test-Path -LiteralPath $report)) { $report = Join-Path $_.FullName 'image.json' }
            if (-not (Test-Path -LiteralPath $report)) { $report = Join-Path $_.FullName 'infra.json' }
            if (-not (Test-Path -LiteralPath $report)) { $report = Join-Path $_.FullName 'bootstrap-plan.json' }
            if (-not (Test-Path -LiteralPath $report)) { $report = Join-Path $_.FullName 'bootstrap-verify.json' }
            if (Test-Path -LiteralPath $report) {
                $entry = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
                [pscustomobject]@{ RunId = $entry.runId; Result = $entry.result; DurationSeconds = $entry.durationSeconds; Report = $report }
            }
        } | Format-Table -AutoSize
    return
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config missing: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$runDir = Join-Path (Join-Path $PSScriptRoot 'runs') $runId
Import-Module (Join-Path $PSScriptRoot 'src\Sentinel.Preflight.psm1') -Force

Write-Host "`nSentinel L1 / Host Preflight (READ ONLY)" -ForegroundColor Cyan
Write-Host "Target lab: $($config.lab)"
Write-Host "Run ID: $runId`n"

$result = Invoke-SentinelPreflight -Config $config -RunDirectory $runDir
$result.Checks | Format-Table -Property Check, Status, Detail -AutoSize -Wrap
Write-Host "`nResult: $($result.Result)" -ForegroundColor $(if ($result.Result -eq 'BLOCKED') { 'Red' } elseif ($result.Result -eq 'READY') { 'Green' } else { 'Yellow' })
Write-Host "Report: $($result.ReportPath)"
Write-Host "Events: $($result.EventPath)"
Write-Host 'No Hyper-V resources were modified.'

if ($result.Result -eq 'BLOCKED') { exit 2 }
if ($result.Result -eq 'READY_WITH_WARNINGS') { exit 0 }
exit 0
