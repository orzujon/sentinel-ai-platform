#Requires -Version 5.1
<#
.SYNOPSIS
  Safely inspect or remove the first failed, disposable Sentinel E2E SSH VM.
.DESCRIPTION
  PLAN is read-only. REMOVE requires an explicit approval token, exactly
  matching Hyper-V VM ID, the original host-local provisioning manifest,
  exclusive ownership of the disposable directory and no foreign VM disks.
  It does NOT touch any Kubernetes VM, switches, or the Stage 2 image cache.
  Only sentinel-e2e-ssh01 is an allowed target. No interactive prompts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$ExpectedVMId,
    [ValidateSet('PLAN','REMOVE')][string]$Mode = 'PLAN',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vmName = 'sentinel-e2e-ssh01'
$root = 'C:\Sentinel\E2E-Disposable'
$folder = Join-Path $root $vmName
$manifestPath = Join-Path $folder 'provisioning.json'
$expectedDisk = Join-Path $folder 'os.vhdx'
$expectedSeed = Join-Path $folder 'seed.iso'
$approvalToken = 'REMOVE_DISPOSABLE_SENTINEL_E2E_SSH01'
$protectedNames = @('sentinel-l1-cp01','sentinel-l1-w01','k8s-cp01','k8s-w01','sentinel-e2e-w02')
function Test-PathBelow([string]$Path,[string]$Directory) {
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return ($absolute.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or
            $absolute.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase))
}
function Assert-NotReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "BLOCKED: reparse point in disposable storage: $Path"
    }
}

if ($ExpectedVMId -eq [guid]::Empty) { throw 'BLOCKED: expected VM GUID must not be empty' }
if ($Mode -eq 'REMOVE' -and $Approval -cne $approvalToken) {
    throw 'BLOCKED: explicit REMOVE_DISPOSABLE_SENTINEL_E2E_SSH01 token required'
}
foreach ($command in @('Get-VM','Get-VMHardDiskDrive','Get-VMDvdDrive','Get-VMSnapshot','Get-VMNetworkAdapter','Get-VHD')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "BLOCKED: missing Hyper-V command $command"
    }
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'BLOCKED: original E2E provisioning manifest missing'
}
Assert-NotReparse $root
Assert-NotReparse $folder
Assert-NotReparse $manifestPath

# The root was created exclusively for this one disposable VM.
$topLevel = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
if ($topLevel.Count -ne 1 -or -not
    [string]::Equals([string]$topLevel[0].FullName,$folder,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'BLOCKED: disposable root contains unexpected files/directories; manual review required'
}
# Reject junctions and symbolic links anywhere under the deletion target,
# including in Hyper-V-generated configuration directories.
foreach ($entry in @(Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction Stop)) {
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "BLOCKED: reparse point inside disposable VM directory: $($entry.FullName)"
    }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schema -ne 1 -or
    [string]$manifest.node -cne $vmName -or
    [string]$manifest.purpose -cne 'disposable-ssh-kvp-e2e' -or
    [guid]$manifest.vmId -ne $ExpectedVMId -or
    [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$') {
    throw 'BLOCKED: host-local provisioning manifest does not match approved disposable identity'
}

$allVMs = @(Get-VM -ErrorAction Stop)
$matches = @($allVMs | Where-Object { $_.Name -ceq $vmName })
if ($matches.Count -ne 1) { throw 'BLOCKED: expected exactly one existing disposable VM' }
$vm = $matches[0]
if ($vm.Id -ne $ExpectedVMId -or $vm.Name -in $protectedNames) {
    throw 'BLOCKED: Hyper-V VM identity does not match authorized disposable'
}
if (-not (Test-PathBelow -Path ([string]$vm.Path) -Directory $folder)) {
    throw 'BLOCKED: VM configuration resides outside disposable VM directory'
}
$disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
if ($disks.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$disks[0].Path)) {
    throw ("BLOCKED: expected exactly one attached disk; Hyper-V returned {0}" -f $disks.Count)
}
$attachedPath = [IO.Path]::GetFullPath([string]$disks[0].Path)
$basePath = [IO.Path]::GetFullPath($expectedDisk)
if (-not (Test-PathBelow -Path $attachedPath -Directory $folder)) {
    throw "BLOCKED: attached disk escapes disposable VM directory: $attachedPath"
}
if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
    throw "BLOCKED: original OS VHDX missing: $basePath"
}
$baseVhd = Get-VHD -Path $basePath -ErrorAction Stop
if ($baseVhd.VhdType -notin @('Dynamic','Fixed') -or
    -not [string]::IsNullOrWhiteSpace([string]$baseVhd.ParentPath)) {
    throw 'BLOCKED: base disk is itself a differencing disk or unsupported image type'
}
$diskTopology = 'base-vhdx'
if (-not [string]::Equals($attachedPath,$basePath,[StringComparison]::OrdinalIgnoreCase)) {
    # Hyper-V Automatic Checkpoints commonly switch the live attachment
    # from os.vhdx to os_<GUID>.avhdx. Never assume an arbitrary AVHDX is safe.
    $basename = [IO.Path]::GetFileName($attachedPath)
    if ($basename -notmatch '^os_[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\.avhdx$') {
        throw "BLOCKED: unexpected differencing disk filename: $basename"
    }
    $delta = Get-VHD -Path $attachedPath -ErrorAction Stop
    $parent = [string]$delta.ParentPath
    if ($delta.VhdType -ne 'Differencing' -or
        [string]::IsNullOrWhiteSpace($parent) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath($parent),
            $basePath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw ("BLOCKED: attached AVHDX is not a verified single-child differencing disk. Attached={0}; parent={1}; type={2}" -f
            $attachedPath,$parent,$delta.VhdType)
    }
    $diskTopology = 'single-avhdx-differencing-child'
}
$allDeltaFiles = @(Get-ChildItem -LiteralPath $folder -Recurse -Force -File -Filter '*.avhdx' -ErrorAction Stop)
if ($diskTopology -eq 'base-vhdx' -and $allDeltaFiles.Count -ne 0) {
    throw 'BLOCKED: unexpected orphaned AVHDX files alongside the base disk'
}
if ($diskTopology -eq 'single-avhdx-differencing-child' -and
    ($allDeltaFiles.Count -ne 1 -or
     -not [string]::Equals([string]$allDeltaFiles[0].FullName,$attachedPath,[StringComparison]::OrdinalIgnoreCase))) {
    throw 'BLOCKED: additional or unexpected AVHDX files found in disposable tree'
}
$checkpoints = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
if ($checkpoints.Count -gt 1) {
    throw "BLOCKED: more than one checkpoint exists ($($checkpoints.Count)); inspect before cleanup"
}
if ($checkpoints.Count -gt 0) {
    # A checkpoint's VM configuration must also live inside our exclusive
    # disposable folder; no outside snapshot storage is ever removed.
    if ([string]::IsNullOrWhiteSpace([string]$vm.SnapshotFileLocation) -or
        -not (Test-PathBelow -Path ([string]$vm.SnapshotFileLocation) -Directory $folder)) {
        throw 'BLOCKED: checkpoint storage is outside disposable VM directory'
    }
}
$dvds = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
if ($dvds.Count -ne 1 -or -not
    [string]::Equals([string]$dvds[0].Path,$expectedSeed,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'BLOCKED: unexpected VM NoCloud seed ISO attachment'
}
$nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
if ($nics.Count -ne 1 -or $nics[0].SwitchName -cne 'Default Switch') {
    throw 'BLOCKED: unexpected VM network attachment'
}
foreach ($other in @($allVMs | Where-Object { $_.Id -ne $ExpectedVMId })) {
    foreach ($attachment in @(
        @(Get-VMHardDiskDrive -VM $other -ErrorAction Stop)
        @(Get-VMDvdDrive -VM $other -ErrorAction Stop)
    )) {
        foreach ($drive in @($attachment)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$drive.Path) -and
                (Test-PathBelow -Path ([string]$drive.Path) -Directory $root)) {
                throw "BLOCKED: another VM references a disk or DVD within disposable root: $($other.Name)"
            }
        }
    }
}
[pscustomobject]@{
    Result = 'SAFE_DISPOSABLE_TARGET'
    Mode = $Mode
    VMName = $vm.Name
    VMId = [string]$vm.Id
    VMState = [string]$vm.State
    Directory = $root
    VMConfiguration = [string]$vm.Path
    Disk = $disks[0].Path
    BaseDisk = $basePath
    DiskTopology = $diskTopology
    CheckpointCount = $checkpoints.Count
    Seed = $dvds[0].Path
    ProtectedVMsUntouched = $true
    Stage2ImageCacheUntouched = $true
} | Format-List
if ($Mode -eq 'PLAN') {
    Write-Host 'CLEANUP_PLAN_READY: original E2E VM/manifest/disks match; no changes made.'
    return
}
# Mutation gate: recheck that the VM is still the same unique Hyper-V object.
$fresh = @(Get-VM -Name $vmName -ErrorAction Stop)
if ($fresh.Count -ne 1 -or $fresh[0].Id -ne $ExpectedVMId) {
    throw 'BLOCKED: VM changed after cleanup validation'
}
$freshDisks = @(Get-VMHardDiskDrive -VM $fresh[0] -ErrorAction Stop)
if ($freshDisks.Count -ne 1 -or
    -not [string]::Equals([string]$freshDisks[0].Path,$attachedPath,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'BLOCKED: attached disk changed after validation; no deletion'
}
if (@(Get-VMSnapshot -VM $fresh[0] -ErrorAction Stop).Count -ne $checkpoints.Count) {
    throw 'BLOCKED: checkpoint count changed after validation; no deletion'
}
if ($fresh[0].State -ne 'Off') {
    Stop-VM -VM $fresh[0] -TurnOff -Force -ErrorAction Stop
}
$stopped = Get-VM -Name $vmName -ErrorAction Stop
if ($stopped.Id -ne $ExpectedVMId -or $stopped.State -ne 'Off') {
    throw 'BLOCKED: unexpected VM state after shutdown; no deletion'
}
Remove-VM -VM $stopped -Force -ErrorAction Stop
if (@(Get-VM -Name $vmName -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'BLOCKED: Hyper-V VM still registered; preserve disk for inspection'
}
# Remove only the validated, exclusively owned disposable tree.
# Neither the Level1-Sandbox VM directory nor the ImageCache is in scope.
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
if (Test-Path -LiteralPath $root) {
    throw 'BLOCKED: disposable directory still present; inspect manually'
}
Write-Host 'DISPOSABLE_E2E_REMOVED: original VM registration and exclusive test files removed; other VMs/switches/image cache untouched.'
