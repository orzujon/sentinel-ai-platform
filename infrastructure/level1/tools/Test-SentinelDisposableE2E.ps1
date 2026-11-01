#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only Hyper-V disposable SSH/KVP end-to-end acceptance preflight.
.DESCRIPTION
  Does not create a VM. Separately checks the proposed test VM identity,
  target path, and available host resources. Existing Sentinel Kubernetes VMs
  are never targets. Use PowerShell elevated if Hyper-V inspection requires it.
#>
[CmdletBinding()]
param(
    [string]$TestVMName = 'sentinel-e2e-ssh01',
    [string]$TestRoot = 'C:\Sentinel\E2E-Disposable',
    [int]$MemoryGB = 3,
    [int]$VirtualDiskGB = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$problems = [System.Collections.Generic.List[string]]::new()
$protected = @('sentinel-l1-cp01','sentinel-l1-w01','k8s-cp01','k8s-w01')
if ($TestVMName -cne 'sentinel-e2e-ssh01' -or $TestVMName -in $protected) {
    throw 'BLOCKED: only the dedicated disposable sentinel-e2e-ssh01 name is permitted'
}
if ($TestRoot -cne 'C:\Sentinel\E2E-Disposable') {
    throw 'BLOCKED: unexpected disposable VM path'
}
if ($MemoryGB -ne 3 -or $VirtualDiskGB -ne 30) {
    throw 'BLOCKED: use reviewed 3 GiB RAM and 30 GiB disk plan'
}
foreach ($cmd in @('Get-VM','Get-VMSwitch')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        $problems.Add("$cmd unavailable")
    }
}
if ($problems.Count -gt 0) {
    throw ('BLOCKED: ' + ($problems -join '; '))
}
$existing = @(Get-VM -ErrorAction Stop)
$names = @($existing | ForEach-Object { [string]$_.Name })
if ($names -contains $TestVMName) { $problems.Add('Disposable VM name already exists') }
if (Test-Path -LiteralPath $TestRoot) { $problems.Add('Disposable VM target directory already exists; refusing adoption') }
$switches = @(Get-VMSwitch -ErrorAction Stop)
$default = @($switches | Where-Object { $_.Name -eq 'Default Switch' })
if ($default.Count -ne 1) { $problems.Add('Hyper-V Default Switch unavailable or ambiguous') }
$protectedPresent = @($protected | Where-Object { $_ -in $names })
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
$availableMemoryGB = [math]::Round(([double]$os.FreePhysicalMemory * 1KB / 1GB),2)
# Conservative: reserve 2 GiB above the reviewed 3 GiB VM allocation.
if ($availableMemoryGB -lt ($MemoryGB + 2)) { $problems.Add('Insufficient free host RAM after 2 GiB safety reserve') }
$drive = Get-PSDrive -Name 'C' -ErrorAction Stop
$freeDiskGB = [math]::Round(([double]$drive.Free / 1GB),2)
# Plan with 15 GiB headroom for transient image conversion and logs.
if ($freeDiskGB -lt ($VirtualDiskGB + 15)) { $problems.Add('Insufficient C: disk headroom') }
$record = [pscustomobject]@{
    Result = if ($problems.Count -eq 0) { 'READY_FOR_REVIEW' } else { 'BLOCKED' }
    DisposableVM = $TestVMName
    DisposableRoot = $TestRoot
    Network = 'Default Switch (existing; no new switch)'
    RequestedMemoryGiB = $MemoryGB
    RequestedDiskGiB = $VirtualDiskGB
    FreeHostMemoryGiB = $availableMemoryGB
    FreeDiskGiB = $freeDiskGB
    ExistingProtectedVMs = $protectedPresent
    Problems = @($problems.ToArray())
    Mutations = $false
}
$record | Format-List
if ($problems.Count -gt 0) { exit 2 }
Write-Host 'READ_ONLY: disposable E2E preflight passed; NO VM has been created.'
