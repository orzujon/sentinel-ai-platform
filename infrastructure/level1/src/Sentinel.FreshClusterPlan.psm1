#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SentinelFreshClusterCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$FreeMemoryBytes,
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$FreeDiskBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VMs,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$OccupiedPaths
    )
    # Proposal only. Nothing returned by this function authorizes execution.
    $root = 'C:\Sentinel\FreshCluster\VMs'
    $names = @('sentinel-fresh-cp01', 'sentinel-fresh-w01')
    $protected = @(@('k8s-cp01', 'k8s-w01', 'sentinel-l1-cp01', 'sentinel-l1-w01',
        'sentinel-l1-regcp01', 'sentinel-l1-regw01', 'sentinel-e2e-auto20') +
        @($VMs | Where-Object { $_.Name -notin $names } | ForEach-Object { $_.Name }) | Sort-Object -Unique)
    $blockers = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        if (@($VMs | Where-Object { $_.Name -ieq $name }).Count -gt 0) {
            $blockers.Add("Proposed VM name already exists: $name")
        }
    }
    if ($OccupiedPaths.Count -gt 0) {
        $blockers.Add('Proposed storage root already exists; no adoption or overwrite is permitted')
    }
    # Static 4 GiB per guest plus a conservative 6 GiB available host reserve.
    # Full disk capacities are budgeted, not just initial dynamic VHDX sizes.
    $requiredMemory = 14GB
    $requiredDisk = 140GB
    if ($FreeMemoryBytes -lt $requiredMemory) {
        $blockers.Add('Insufficient current free RAM for two 4 GiB guests plus 6 GiB host reserve')
    }
    if ($FreeDiskBytes -lt $requiredDisk) {
        $blockers.Add('Insufficient C: space for two 60 GiB disks plus 20 GiB reserve')
    }
    $sandbox = @($VMs | Where-Object { $_.Name -in @('sentinel-l1-cp01', 'sentinel-l1-w01') })
    $assigned = 0L
    foreach ($vm in $sandbox) { $assigned += [long]$vm.MemoryAssigned }
    [pscustomobject]@{
        SchemaVersion = 1
        Result = 'PLAN_ONLY'
        CreateSupported = $false
        ExecutionAuthorized = $false
        ProposedVMNames = $names
        ProtectedVMNames = $protected
        ProposedStorageRoot = $root
        ProposedMemoryPerVMGiB = 4
        ProposedVCPUPerVM = 2
        ProposedDiskPerVMGiB = 60
        FreeMemoryGiB = [math]::Round($FreeMemoryBytes / 1GB, 2)
        RequiredFreeMemoryGiB = 14
        FreeDiskGiB = [math]::Round($FreeDiskBytes / 1GB, 2)
        RequiredFreeDiskGiB = 140
        ExistingSandboxAssignedMemoryGiB = [math]::Round($assigned / 1GB, 2)
        CapacityAndNamesPassNow = ($blockers.Count -eq 0)
        Blockers = @($blockers.ToArray())
        Unresolved = @(
            'Measure capacity again after operator-controlled shutdown; assigned RAM is not a guaranteed future free-memory value',
            'Review unique node IPs/MACs, pod/service CIDRs and route conflicts before approving any network profile',
            'Bind a reviewed image, private configuration revision and both new VM identities',
            'Extend first-boot KVP and pinned trust for a pair without weakening Stage54 disposable protections',
            'Connect existing baseline, package, init, CNI, join and validation stages to the new profile'
        )
    }
}

Export-ModuleMember -Function Get-SentinelFreshClusterCapacity
