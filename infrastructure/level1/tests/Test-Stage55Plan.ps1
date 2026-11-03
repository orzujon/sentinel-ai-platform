#Requires -Version 5.1
# Stage 5.5 contract testing; no live VM, network, API, disk or SSH access.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\tools\Test-SentinelStage55WorkerRebuild.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) { throw "BLOCKED: Stage55 PowerShell parser errors: $($errors | Out-String)" }
$source = Get-Content -LiteralPath $path -Raw -Encoding UTF8
foreach ($required in @(
    "ValidateSet('PLAN')",
    'ExpectedWorkerVMId',
    'ExpectedControlPlaneVMId',
    'sentinel-l1-w01',
    'sentinel-l1-cp01',
    'Get-VMHardDiskDrive',
    'Get-VMSnapshot',
    'Get-VMIntegrationService',
    'DestructionApproved = $false',
    "KubernetesChecks = 'NOT_RUN'",
    'STAGE55_HOST_PLAN_READY',
    'STAGE55_DELETE_BLOCKED'
)) {
    if (-not $source.Contains($required)) { throw "BLOCKED: Stage55 missing safety requirement: $required" }
}
foreach ($forbidden in @('Stop-VM','Remove-VM','New-VM','Set-VM','Remove-VHD','Remove-Item','Invoke-Expression','kubectl delete','kubectl drain')) {
    if ($source -match ('(?m)^\s*'+[regex]::Escape($forbidden)+'\s')) {
        throw "BLOCKED: Stage55 read-only plan contains a mutating action: $forbidden"
    }
}
try {
    & $path -Mode PLAN -ExpectedWorkerVMId ([guid]::Empty) -ExpectedControlPlaneVMId ([guid]::NewGuid()) | Out-Null
    throw 'Expected-Blocked-Missing-UUID'
} catch {
    if ($_.Exception.Message -eq 'Expected-Blocked-Missing-UUID') { throw }
    if ($_.Exception.Message -notmatch '^BLOCKED: distinct, nonempty approved VM UUIDs required') { throw }
}
Write-Host 'PASS: Stage55 read-only worker rebuild plan syntax, exact identity requirement and no destructive execution'
