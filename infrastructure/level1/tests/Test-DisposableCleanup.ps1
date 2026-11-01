#Requires -Version 5.1
# Offline parsing and negative-approval gates for destructive disposable cleanup.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\tools\Remove-SentinelDisposableE2E.ps1'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw ('Cleanup parser errors: ' + (($errors | ForEach-Object Message) -join '; '))
}
$src = Get-Content -LiteralPath $path -Raw
foreach ($must in @(
    "sentinel-e2e-ssh01",
    "C:\Sentinel\E2E-Disposable",
    "disposable-ssh-kvp-e2e",
    "REMOVE_DISPOSABLE_SENTINEL_E2E_SSH01",
    "ExpectedVMId",
    "Get-VMSnapshot",
    "Get-VMHardDiskDrive",
    "Get-VMDvdDrive",
    "Get-VMNetworkAdapter",
    "ReparsePoint",
    'foreach ($other',
    "Remove-VM -VM",
    "Remove-Item -LiteralPath",
    "Stage2ImageCacheUntouched",
    "CLEANUP_PLAN_READY",
    "DISPOSABLE_E2E_REMOVED"
)) {
    if (-not $src.Contains($must)) { throw "Cleanup safeguard missing: $must" }
}
foreach ($protected in @('sentinel-l1-cp01','sentinel-l1-w01','k8s-cp01','k8s-w01','sentinel-e2e-w02')) {
    if (-not $src.Contains($protected)) { throw "Cleanup protected name absent: $protected" }
}
foreach ($forbidden in @('Remove-VMSwitch','New-VMSwitch','Set-VMNetworkAdapter','Remove-VMHardDiskDrive','Remove-VHD','ssh-keyscan','Read-Host')) {
    if ($src -match ('(?m)^\s*' + [regex]::Escape($forbidden) + '\b')) {
        throw "Destructive or interactive command forbidden in cleanup: $forbidden"
    }
}
# Without approval the destructive mode MUST block before contacting Hyper-V.
try {
    & $path -Mode REMOVE -ExpectedVMId '83119b70-b594-4813-a07f-d2a5a329db43' 2>&1 | Out-Null
    throw 'No-approval attempt did not block'
} catch {
    if ($_.Exception.Message -eq 'No-approval attempt did not block') { throw }
    if ($_.Exception.Message -notmatch 'BLOCKED: explicit REMOVE') {
        throw "Cleanup declined for wrong reason: $($_.Exception.Message)"
    }
}
Write-Host 'PASS: E2E cleanup script parses and destructive mode refuses absent approval'
