#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only approval preflight for a small worker-shaped disposable Hyper-V guest.
.DESCRIPTION
  The existing two-node Sentinel-L1 Kubernetes cluster and its switches are read-only.
  This does not create, restart, reconfigure, or delete any Hyper-V resource.
#>
[CmdletBinding()]
param(
    [string]$TestVMName = 'sentinel-e2e-w02',
    [string]$TestRoot = 'C:\Sentinel\E2E-WorkerReplica',
    [int]$MemoryGB = 2,
    [int]$VirtualDiskGB = 24
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$vmName = 'sentinel-e2e-w02'
$root = 'C:\Sentinel\E2E-WorkerReplica'
$staticIP = '10.78.0.12'
$managementMAC = '02AA78000112'
$internalMAC = '02AA78000012'
$protected = @('sentinel-l1-cp01','sentinel-l1-w01','k8s-cp01','k8s-w01','sentinel-e2e-ssh01')
if ($TestVMName -cne $vmName -or $TestRoot -cne $root -or $MemoryGB -ne 2 -or $VirtualDiskGB -ne 24) {
    throw 'BLOCKED: only the reviewed sentinel-e2e-w02 2 GiB / 24 GiB isolated replica is permitted'
}
$problems = [System.Collections.Generic.List[string]]::new()
foreach ($cmd in @('Get-VM','Get-VMSwitch','Get-VMNetworkAdapter','Get-NetIPAddress','Get-NetNeighbor')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $problems.Add("Missing command $cmd") }
}
if ($problems.Count -gt 0) { throw ('BLOCKED: ' + ($problems -join '; ')) }

$vms = @(Get-VM -ErrorAction Stop)
$names = @($vms | ForEach-Object { [string]$_.Name })
if ($names -contains $vmName) { $problems.Add('Replica VM name already exists; never adopt or replace') }
if (Test-Path -LiteralPath $root) { $problems.Add('Replica root already exists; never overwrite files') }

$switches = @(Get-VMSwitch -ErrorAction Stop)
$defaultSwitch = @($switches | Where-Object { $_.Name -ceq 'Default Switch' })
$labSwitch = @($switches | Where-Object { $_.Name -ceq 'Sentinel-L1' })
if ($defaultSwitch.Count -ne 1) { $problems.Add('Expected exactly one existing Default Switch') }
if ($labSwitch.Count -ne 1) { $problems.Add('Expected existing Sentinel-L1 switch') }
elseif ([string]$labSwitch[0].SwitchType -ne 'Internal') { $problems.Add('Sentinel-L1 must be an Internal switch') }

$hostLabIP = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (Sentinel-L1)' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq '10.78.0.1' -and $_.PrefixLength -eq 24 })
if ($hostLabIP.Count -ne 1) { $problems.Add('Existing Sentinel-L1 host IP 10.78.0.1/24 not verified') }

# Existing production-shaped lab nodes must have the same two NICs.
foreach ($name in @('sentinel-l1-cp01','sentinel-l1-w01')) {
    $vm = @($vms | Where-Object { $_.Name -ceq $name })
    if ($vm.Count -ne 1) {
        $problems.Add("Existing lab node missing: $name")
        continue
    }
    $nics = @(Get-VMNetworkAdapter -VMName $name -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.SwitchName -eq 'Default Switch' }).Count -ne 1 -or
        @($nics | Where-Object { $_.SwitchName -eq 'Sentinel-L1' }).Count -ne 1) {
        $problems.Add("Existing lab topology differs from expected two NICs: $name")
    }
}

# Stage 3's stable MAC format, extended with the next worker suffix.
$allNics = @(Get-VMNetworkAdapter -All -ErrorAction Stop)
$allMACs = @($allNics | ForEach-Object { ([string]$_.MacAddress -replace '[:-]','').ToUpperInvariant() })
if ($managementMAC -in $allMACs -or $internalMAC -in $allMACs) {
    $problems.Add('Replica static MAC is already allocated to another Hyper-V NIC')
}
$assignedLabIP = @(Get-NetIPAddress -IPAddress $staticIP -ErrorAction SilentlyContinue)
if ($assignedLabIP.Count -gt 0) { $problems.Add("Replica IP $staticIP already allocated to Windows") }
$neighbors = @(Get-NetNeighbor -IPAddress $staticIP -ErrorAction SilentlyContinue |
    Where-Object { $_.State -notin @('Unreachable','Incomplete') })
if ($neighbors.Count -gt 0) { $problems.Add("Replica IP $staticIP exists in host neighbour cache; inspect before use") }
# Neighbour-cache absence alone does not prove address uniqueness.
# Lab addressing uses an explicit reserved plan: .1 host, .10 control plane, .11 worker, .12 E2E replica.

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
$availableGiB = [math]::Round(([double]$os.FreePhysicalMemory * 1KB / 1GB),2)
if ($availableGiB -lt ($MemoryGB + 2)) { $problems.Add('Insufficient free RAM with 2 GiB host reserve') }
$disk = Get-PSDrive -Name C -ErrorAction Stop
$freeDiskGiB = [math]::Round(([double]$disk.Free / 1GB),2)
if ($freeDiskGiB -lt ($VirtualDiskGB + 15)) { $problems.Add('Insufficient free disk with 15 GiB reserve') }

[pscustomobject]@{
    Result = if ($problems.Count -eq 0) { 'READY_FOR_REVIEW' } else { 'BLOCKED' }
    DisposableVM = $vmName
    MemoryGiB = $MemoryGB
    DiskGiB = $VirtualDiskGB
    Management = 'Default Switch (DHCP)'
    Private = "Sentinel-L1 (static $staticIP/24)"
    ManagementMAC = $managementMAC
    PrivateMAC = $internalMAC
    ExistingProtectedVMs = @($protected | Where-Object { $_ -in $names })
    FreeHostMemoryGiB = $availableGiB
    FreeDiskGiB = $freeDiskGiB
    Problems = @($problems.ToArray())
    Mutations = $false
} | Format-List

if ($problems.Count -gt 0) { exit 2 }
Write-Host 'WORKER_REPLICA_PREFLIGHT_PASS: existing switches reused; existing Kubernetes VMs unchanged.'
