#Requires -Version 5.1
<#
.SYNOPSIS
Operator-controlled power actions for the existing Level1 sandbox only.
.DESCRIPTION
PLAN is default. STOP requests guest shutdown worker first, without forced
power-off. START powers control plane first. No disk, network, checkpoint or
Kubernetes operations. Both VM UUIDs must come from independent inventory.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','STOP','START')][string]$Mode = 'PLAN',
    [Parameter(Mandatory)][guid]$ExpectedControlPlaneVMId,
    [Parameter(Mandatory)][guid]$ExpectedWorkerVMId,
    [ValidateRange(10,600)][int]$TimeoutSeconds = 120,
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Mode = $Mode.ToUpperInvariant()
if ($ExpectedControlPlaneVMId -eq [guid]::Empty -or $ExpectedWorkerVMId -eq [guid]::Empty -or
    $ExpectedControlPlaneVMId -eq $ExpectedWorkerVMId) { throw 'BLOCKED: distinct nonempty UUIDs required' }
if ($Mode -ne 'PLAN' -and $Approval -cne ($Mode+'_EXACT_SENTINEL_SANDBOX_PAIR')) {
    throw 'BLOCKED: explicit exact-pair power approval required'
}
if ($Mode -eq 'PLAN' -and $Approval) { throw 'BLOCKED: PLAN takes no approval' }
$expected = @{'sentinel-l1-cp01'=$ExpectedControlPlaneVMId; 'sentinel-l1-w01'=$ExpectedWorkerVMId}
function Get-ExactPair {
    $pair=@{}
    foreach ($name in @('sentinel-l1-cp01','sentinel-l1-w01')) {
        $found=@(Get-VM -Name $name -ErrorAction Stop)
        if ($found.Count -ne 1 -or $found[0].Name -cne $name -or $found[0].Id -ne $expected[$name]) {
            throw 'BLOCKED: sandbox identity changed or is ambiguous'
        }
        $prefix='C:\Sentinel\Level1-Sandbox\VMs\'+$name
        $path=[IO.Path]::GetFullPath([string]$found[0].Path).TrimEnd('\')
        if ($path -ine $prefix -and -not $path.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'BLOCKED: sandbox VM configuration outside its expected folder'
        }
        if ($found[0].State -notin @('Running','Off')) { throw 'BLOCKED: transitional or saved VM state; inspect before power action' }
        $pair[$name]=$found[0]
    }
    return $pair
}
$pair=Get-ExactPair
if ($Mode -eq 'PLAN') {
    @($pair.Values) | Select-Object Name,Id,State,MemoryAssigned | Format-Table -AutoSize
    Write-Host 'SANDBOX_POWER_PLAN: STOP = worker then control plane; START = control plane then worker. No changes.'
    return
}
$order=if ($Mode -eq 'STOP') { @('sentinel-l1-w01','sentinel-l1-cp01') } else { @('sentinel-l1-cp01','sentinel-l1-w01') }
foreach ($name in $order) {
    $pair=Get-ExactPair
    $vm=$pair[$name]
    if ($Mode -eq 'STOP' -and $vm.State -eq 'Running') {
        Stop-VM -VM $vm -ErrorAction Stop
    } elseif ($Mode -eq 'START' -and $vm.State -eq 'Off') {
        Start-VM -VM $vm -ErrorAction Stop | Out-Null
    }
    $goal=if ($Mode -eq 'STOP') { 'Off' } else { 'Running' }
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $observed=@(Get-VM -Name $name -ErrorAction Stop)
        if ($observed.Count -ne 1 -or $observed[0].Id -ne $expected[$name]) { throw 'BLOCKED: VM identity changed during power action' }
        if ($observed[0].State -eq $goal) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw 'BLOCKED: power operation timed out; no forced fallback and no further node action' }
        Start-Sleep -Seconds 2
    } while ($true)
}
Write-Host "SANDBOX_POWER_$Mode`: exact pair reached requested power state. Kubernetes readiness has not been rechecked."
