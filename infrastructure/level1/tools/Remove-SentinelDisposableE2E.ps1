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
foreach ($command in @('Get-VM','Get-VMHardDiskDrive','Get-VMDvdDrive','Get-VMSnapshot','Get-VMNetworkAdapter')) {
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
# Show the exact Hyper-V layout on mismatch; never infer ownership or delete.
$diskPaths = @($disks | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_.Path)) { '<blank>' } else { [string]$_.Path }
})
$diskValid = $false
if ($disks.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$disks[0].Path)) {
    $diskValid = [string]::Equals(
        [IO.Path]::GetFullPath([string]$disks[0].Path),
        [IO.Path]::GetFullPath($expectedDisk),
        [StringComparison]::OrdinalIgnoreCase
    )
}
if (-not $diskValid) {
    throw ("BLOCKED: unexpected VM disk attachment. Expected one attached disk '{0}'; Hyper-V returned {1}: {2}. No modifications performed." -f
        $expectedDisk, $disks.Count, ($diskPaths -join ' ; '))
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
if (@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count -gt 0) {
    throw 'BLOCKED: VM checkpoints exist; inspect checkpoint storage separately'
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
