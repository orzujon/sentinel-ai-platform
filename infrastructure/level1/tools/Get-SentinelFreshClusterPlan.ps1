#Requires -Version 5.1
<#
.SYNOPSIS
Read-only host observations for a proposed separate two-node cluster.
.DESCRIPTION
No VM power operations, WSL/SSH calls, package operations or file writes.
Emits JSON to the console. This is not a deployment readiness certificate.
Run by the operator in Administrator PowerShell. No APPLY mode exists.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.FreshClusterPlan.psm1') -Force
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
$volume = Get-Volume -DriveLetter C -ErrorAction Stop
$vms = @(Get-VM -ErrorAction Stop)
$root = 'C:\Sentinel\FreshCluster\VMs'
$occupied = @()
# Treat even an empty pre-existing root or its parent as unreviewed state.
foreach ($candidate in @('C:\Sentinel\FreshCluster', $root)) {
    if (Test-Path -LiteralPath $candidate -ErrorAction Stop) { $occupied += $candidate }
}
$plan = Get-SentinelFreshClusterCapacity -FreeMemoryBytes ([long]$os.FreePhysicalMemory * 1KB) `
    -FreeDiskBytes ([long]$volume.SizeRemaining) -VMs $vms -OccupiedPaths $occupied
[pscustomobject]@{
    ObservedUtc = [datetime]::UtcNow.ToString('o')
    Plan = $plan
    VMInventory = @($vms | Select-Object Name, Id, @{Name='State'; Expression={[string]$_.State}},
        ProcessorCount, MemoryAssigned, MemoryStartup)
    SwitchInventory = @(Get-VMSwitch -ErrorAction Stop | Select-Object Name,
        @{Name='SwitchType'; Expression={[string]$_.SwitchType}})
    IPv4Routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Select-Object DestinationPrefix, InterfaceAlias, NextHop)
} | ConvertTo-Json -Depth 7
