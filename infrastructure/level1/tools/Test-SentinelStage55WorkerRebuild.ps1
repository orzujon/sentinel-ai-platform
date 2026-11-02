#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.5: read-only host-side preflight for a potential worker rebuild.
.DESCRIPTION
  Checks exact VM UUIDs, power, switch/NIC topology, worker disk ownership,
  checkpoints and worker storage boundaries. NEVER drains a node, deletes a
  VM, changes Kubernetes, or considers a rebuild approved. Kubernetes workload
  and persistent-data safety must be assessed independently before an APPLY
  workflow is developed and approved.
.EXAMPLE
  .\Test-SentinelStage55WorkerRebuild.ps1 -ExpectedWorkerVMId $worker.Id -ExpectedControlPlaneVMId $cp.Id
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN')][string]$Mode = 'PLAN',
    [Parameter(Mandatory)][guid]$ExpectedWorkerVMId,
    [Parameter(Mandatory)][guid]$ExpectedControlPlaneVMId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ExpectedWorkerVMId -eq [guid]::Empty -or $ExpectedControlPlaneVMId -eq [guid]::Empty -or
    $ExpectedWorkerVMId -eq $ExpectedControlPlaneVMId) {
    throw 'BLOCKED: distinct, nonempty approved VM UUIDs required'
}
$cpName = 'sentinel-l1-cp01'
$workerName = 'sentinel-l1-w01'
$vmRoot = 'C:\Sentinel\Level1-Sandbox\VMs'
$workerDir = Join-Path $vmRoot $workerName

function Test-UnderPath([string]$Candidate,[string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $item = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $item.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)
}

foreach ($command in @('Get-VM','Get-VMNetworkAdapter','Get-VMHardDiskDrive',
                       'Get-VMSnapshot','Get-VHD','Get-VMIntegrationService','Get-VMSwitch')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "BLOCKED: Hyper-V read-only inspection command missing: $command"
    }
}
$allVMs = @(Get-VM -ErrorAction Stop)
$cpMatches = @($allVMs | Where-Object { $_.Name -ceq $cpName })
$workerMatches = @($allVMs | Where-Object { $_.Name -ceq $workerName })
if ($cpMatches.Count -ne 1 -or $workerMatches.Count -ne 1) {
    throw 'BLOCKED: exact control-plane and worker VM names must both exist once'
}
$cp = $cpMatches[0]
$worker = $workerMatches[0]
if ($cp.Id -ne $ExpectedControlPlaneVMId -or $worker.Id -ne $ExpectedWorkerVMId) {
    throw 'BLOCKED: actual VM UUID changed since operator review'
}
if ($cp.State -ne 'Running' -or $worker.State -ne 'Running') {
    throw 'BLOCKED: both Kubernetes VMs must be running for preflight'
}
if (-not (Test-UnderPath ([string]$cp.Path) (Join-Path $vmRoot $cpName)) -or
    -not (Test-UnderPath ([string]$worker.Path) $workerDir)) {
    throw 'BLOCKED: unexpected control-plane or worker Hyper-V configuration location'
}
$expected = @('Default Switch','Sentinel-L1')
$switches = @(Get-VMSwitch -ErrorAction Stop)
if (@($switches | Where-Object { $_.Name -ceq 'Default Switch' }).Count -ne 1 -or
    @($switches | Where-Object { $_.Name -ceq 'Sentinel-L1' -and $_.SwitchType -eq 'Internal' }).Count -ne 1) {
    throw 'BLOCKED: existing two-switch topology differs'
}
foreach ($vm in @($cp,$worker)) {
    $nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.SwitchName -ceq $expected[0] }).Count -ne 1 -or
        @($nics | Where-Object { $_.SwitchName -ceq $expected[1] }).Count -ne 1) {
        throw "BLOCKED: VM network adapter topology changed: $($vm.Name)"
    }
}
$snapshots = @(Get-VMSnapshot -VM $worker -ErrorAction Stop)
if ($snapshots.Count -ne 0) {
    throw 'BLOCKED: worker has Hyper-V checkpoints; rebuild and disk ownership require independent review'
}
$disks = @(Get-VMHardDiskDrive -VM $worker -ErrorAction Stop)
if ($disks.Count -ne 1 -or -not (Test-UnderPath ([string]$disks[0].Path) $workerDir)) {
    throw 'BLOCKED: worker disk count or ownership unexpected; cannot plan replacement'
}
$workerDisk = [string]$disks[0].Path
$vhd = Get-VHD -Path $workerDisk -ErrorAction Stop
if ([string]$vhd.VhdType -notin @('Dynamic','Fixed') -or
    -not [string]::IsNullOrWhiteSpace([string]$vhd.ParentPath)) {
    throw 'BLOCKED: worker disk is differencing or otherwise unexpected'
}
foreach ($other in @($allVMs | Where-Object { $_.Id -ne $worker.Id })) {
    foreach ($disk in @(Get-VMHardDiskDrive -VM $other -ErrorAction Stop)) {
        if ([string]::Equals([string]$disk.Path, $workerDisk,[StringComparison]::OrdinalIgnoreCase)) {
            throw "BLOCKED: another VM shares worker disk: $($other.Name)"
        }
    }
}
$kvp = @(Get-VMIntegrationService -VM $worker -ErrorAction Stop |
    Where-Object { $_.Name -in @('Key-Value Pair Exchange','Data Exchange') })
$kvpDescription = if ($kvp.Count -eq 1) { [string]$kvp[0].PrimaryStatusDescription } else { 'NOT_FOUND' }
[pscustomobject]@{
    Result = 'HOST_PLAN_READY_ONLY'
    Target = $workerName
    TargetVMId = [string]$worker.Id
    ProtectedControlPlane = $cpName
    ControlPlaneVMId = [string]$cp.Id
    WorkerDisk = $workerDisk
    WorkerKvpStatus = $kvpDescription
    HostChecks = 'PASS'
    KubernetesChecks = 'NOT_RUN'
    DataAndBackupChecks = 'NOT_RUN'
    FirstBootWorkerKvpPipeline = 'NOT_YET_IMPLEMENTED'
    WorkerRejoinPipeline = 'NOT_YET_IMPLEMENTED'
    DestructionApproved = $false
    Mutations = $false
} | Format-List
Write-Host 'STAGE55_HOST_PLAN_READY: exact VM identities, topology and worker disk reviewed without mutation.'
Write-Host 'STAGE55_DELETE_BLOCKED: must verify Kubernetes workloads, PVs, backups and worker rejoin automation before replacement.'
