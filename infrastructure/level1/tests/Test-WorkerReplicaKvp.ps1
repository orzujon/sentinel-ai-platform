#Requires -Version 5.1
# Offline CI: parse Windows KVP entrypoint and verify no-approval APPLY fails shut.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceFile = Join-Path $PSScriptRoot '..\tools\Invoke-SentinelWorkerReplicaKvp.ps1'
$bashFile = Join-Path $PSScriptRoot '..\src\worker-replica-kvp.sh'
$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($sourceFile,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw ('KVP replica entrypoint parsing failed: ' + (($errors | ForEach-Object Message) -join '; '))
}
$script = Get-Content $sourceFile -Raw
$linux = Get-Content $bashFile -Raw
foreach ($needed in @(
    '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9',
    'sentinel-e2e-w02',
    'disposable-worker-replica-e2e',
    'INSTALL_DISPOSABLE_SENTINEL_W02_KVP_FIVE_PACKAGES',
    'INSTALL_DISPOSABLE_SENTINEL_W02_MATCHING_KERNEL_CLOUD_TOOLS',
    'KERNEL_PLAN',
    'KERNEL_APPLY',
    'worker-replica-kvp-kernel-recovery.sh',
    'diagnostic_known_hosts',
    'StrictHostKeyChecking=yes',
    'Get-VMNetworkAdapter',
    'Default Switch',
    'Sentinel-L1',
    '10.78.0.12',
    'Get-Content',
    'Convert]::ToBase64String',
    'sudo -n bash -s --',
    'KVP',
    'PLAN',
    'APPLY'
)) {
    if (-not $script.Contains($needed)) {
        throw "Missing KVP disposable identity, trust or approval contract: $needed"
    }
}
foreach ($needed in @(
    'validate-simulation',
    'linux-cloud-tools-common=7.0.0-42.42',
    'bpftool=7.7.0+7.0.0-42.42',
    'linux-libc-dev=7.0.0-42.42',
    'linux-perf=7.0.0-42.42',
    'linux-tools-common=7.0.0-42.42',
    'DEBIAN_FRONTEND=noninteractive',
    'apt-get -s',
    'systemctl enable --now hv-kvp-daemon.service',
    'KVP_REPLICA_PLAN_READY',
    'KVP_GUEST_DAEMON_ACTIVE_HOST_UNVERIFIED',
    '60-hv-kvp-daemon.rules',
    'udevadm control --reload',
    'udevadm trigger --action=add',
    'udevadm settle --timeout=20',
    'sys-devices-virtual-misc-vmbus',
    'TAGS=.*:systemd:',
    'systemctl show',
    '/etc/kubernetes/admin.conf'
)) {
    if (-not $linux.Contains($needed)) {
        throw "Linux KVP transaction contract missing: $needed"
    }
}
foreach ($forbidden in @('Stop-VM','Remove-VM','Set-VMNetworkAdapter','Remove-VMSwitch','ssh-keyscan','Read-Host')) {
    if ($script -match ('(?m)^\s*' + [regex]::Escape($forbidden) + '\b')) {
        throw "Unexpected dangerous or interactive operation: $forbidden"
    }
}
try {
    & $sourceFile -Mode APPLY 2>&1 | Out-Null
    throw 'APPLY without approval token unexpectedly proceeded'
} catch {
    if ($_.Exception.Message -eq 'APPLY without approval token unexpectedly proceeded') { throw }
    if ($_.Exception.Message -notmatch 'BLOCKED: explicit reviewed five-package') {
        throw "APPLY denied for wrong reason: $($_.Exception.Message)"
    }
}
$recovery = Get-Content (Join-Path $PSScriptRoot '..\src\worker-replica-kvp-kernel-recovery.sh') -Raw
foreach ($needed in @(
    '7.0.0-38-generic',
    'linux-cloud-tools-7.0.0-38=7.0.0-38.38',
    'linux-cloud-tools-7.0.0-38-generic=7.0.0-38.38',
    'KVP_KERNEL_PLAN_READY',
    'KVP_GUEST_DAEMON_STABLE_HOST_UNVERIFIED',
    'apt-get -s',
    'validate_simulation',
    'reset-failed',
    'systemctl restart hv-kvp-daemon.service',
    'sleep 3',
    'MainPID',
    '/etc/kubernetes/admin.conf'
)) {
    if (-not $recovery.Contains($needed)) {
        throw "Kernel-matched KVP recovery contract missing: $needed"
    }
}
try {
    & $sourceFile -Mode KERNEL_APPLY 2>&1 | Out-Null
    throw 'KERNEL_APPLY without approval token unexpectedly proceeded'
} catch {
    if ($_.Exception.Message -eq 'KERNEL_APPLY without approval token unexpectedly proceeded') { throw }
    if ($_.Exception.Message -notmatch 'BLOCKED: explicit reviewed matching-kernel') {
        throw "KERNEL_APPLY denied for wrong reason: $($_.Exception.Message)"
    }
}
Write-Host 'PASS: KVP kernel-matched recovery rejects APPLY before any guest operations without approval'
Write-Host 'PASS: worker replica KVP Windows entrypoint parses and APPLY fails before SSH without approval'
