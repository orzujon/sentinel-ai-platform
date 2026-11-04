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
# A retired pair can legitimately leave empty, ACL-protected parent folders.
# Their existence alone is not an occupied VM slot. Never delete/reuse any
# unexpected contents: flag them instead. Exact VM folders are always blockers.
foreach ($candidate in @('C:\Sentinel\FreshCluster', $root)) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not ([IO.Directory]::GetAccessControl($candidate)).AreAccessRulesProtected) {
        $occupied += $candidate
        continue
    }
    $allowedChild = if ($candidate -eq 'C:\Sentinel\FreshCluster') { @('VMs') } else { @() }
    foreach ($entry in @(Get-ChildItem -LiteralPath $candidate -Force -ErrorAction Stop)) {
        if ($entry.Name -cnotin $allowedChild -or
            -not $entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $occupied += $entry.FullName
        }
    }
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
