#Requires -Version 5.1
# Offline Windows GitHub Actions contract for a minimal Stage 3 worker replica.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$paths = @(
    'tools/Test-SentinelWorkerReplicaE2E.ps1',
    'tools/New-SentinelWorkerReplicaE2E.ps1'
)
foreach ($path in $paths) {
    $full = Join-Path $root $path
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($full,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "BLOCKED: parser error in $path" }
}
$source = Get-Content (Join-Path $root 'tools/New-SentinelWorkerReplicaE2E.ps1') -Raw
$preflight = Get-Content (Join-Path $root 'tools/Test-SentinelWorkerReplicaE2E.ps1') -Raw
$original = Get-Content (Join-Path $root 'src/Sentinel.Infrastructure.psm1') -Raw

foreach ($required in @(
    'sentinel-e2e-w02',
    'C:\Sentinel\E2E-WorkerReplica',
    'CREATE_DISPOSABLE_SENTINEL_E2E_W02',
    'Test-SentinelWorkerReplicaE2E.ps1',
    'Get-FileHash',
    'ConvertTo-SentinelWslMountPath',
    'Default Switch',
    'Sentinel-L1',
    '02AA78000112',
    '02AA78000012',
    '10.78.0.12',
    'growpart:',
    'resize_rootfs: true',
    'packages: [openssh-server]',
    'ssh_pwauth: false',
    'ssh_deletekeys: true',
    'Add-VMNetworkAdapter',
    'AutomaticCheckpointsEnabled',
    'Set-VMNetworkAdapter',
    'match:',
    'macaddress:',
    'dhcp4: true',
    'dhcp4: false',
    'PLAN'
)) {
    if (-not $source.Contains($required)) { throw "Missing replica deployment contract: $required" }
}
foreach ($required in @(
    'Get-VMNetworkAdapter -All',
    'Get-NetIPAddress',
    'Get-NetNeighbor',
    'Get-VMSwitch',
    '10.78.0.1',
    '10.78.0.12',
    '02AA78000112',
    '02AA78000012',
    'sentinel-l1-cp01',
    'sentinel-l1-w01',
    '2 GiB host reserve',
    'READY_FOR_REVIEW'
)) {
    if (-not $preflight.Contains($required)) { throw "Missing replica preflight safeguard: $required" }
}
foreach ($forbidden in @('Remove-VM','Stop-VM','Remove-VMSwitch','New-VMSwitch','Remove-Item','ssh-keyscan','StrictHostKeyChecking=accept-new','Read-Host')) {
    if ($source -match ('(?m)^\s*' + [regex]::Escape($forbidden) + '\b')) {
        throw "Unexpected destructive or interactive operation in replica creator: $forbidden"
    }
}
foreach ($forbidden in @('Remove-VM','Stop-VM','Start-VM','New-VM','Set-VM','New-VMSwitch','Add-VMNetworkAdapter')) {
    if ($preflight -match ('(?m)^\s*' + [regex]::Escape($forbidden) + '\b')) {
        throw "Unexpected mutation in replica preflight: $forbidden"
    }
}
foreach ($forbidden in @('kubeadm','kubectl','kubelet','linux-cloud-tools-common=','hv-kvp-daemon.service')) {
    if ($source.Contains($forbidden)) {
        throw "Replica first boot must not depend on Kubernetes or unverified KVP package: $forbidden"
    }
}
# Cross-check the source Stage 3 worker contract and the new replica.
foreach ($shared in @('Default Switch','Sentinel-L1','K8s-Internal','Set-VMNetworkAdapter','macaddress:', 'dhcp4: true','dhcp4: false','growpart:','resize_rootfs: true','packages: [openssh-server]')) {
    if (-not $original.Contains($shared) -or -not $source.Contains($shared)) {
        throw "Worker replica is not aligned to Stage 3 startup contract: $shared"
    }
}
if (([regex]::Matches($source, '(?m)^\s+macaddress:')).Count -ne 2) {
    throw 'Worker replica cloud-init must MAC-match exactly two adapters'
}
try {
    & (Join-Path $root 'tools/Test-SentinelWorkerReplicaE2E.ps1') -TestVMName 'sentinel-l1-w01' 2>&1 | Out-Null
    throw 'Expected preflight to reject protected VM name'
} catch {
    if ($_.Exception.Message -eq 'Expected preflight to reject protected VM name') { throw }
    if ($_.Exception.Message -notmatch 'BLOCKED') { throw }
}
Write-Host 'PASS: Stage 5.3 minimal two-NIC worker replica matches Stage 3 and rejects protected target'
