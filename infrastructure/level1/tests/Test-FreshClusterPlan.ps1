#Requires -Version 5.1
# Offline synthetic data only; never imports Hyper-V or invokes the host collector.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.FreshClusterPlan.psm1') -Force
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
$existing = @(
    [pscustomobject]@{Name='sentinel-l1-cp01'; MemoryAssigned=4GB},
    [pscustomobject]@{Name='sentinel-l1-w01'; MemoryAssigned=4GB}
)
$low = Get-SentinelFreshClusterCapacity -FreeMemoryBytes 6GB -FreeDiskBytes 200GB -VMs $existing -OccupiedPaths @()
Assert-True (-not $low.CapacityAndNamesPassNow) 'Must not count potential shutdown RAM as currently free'
Assert-True ($low.ExistingSandboxAssignedMemoryGiB -eq 8) 'Report assigned existing RAM separately'
$enough = Get-SentinelFreshClusterCapacity -FreeMemoryBytes 14GB -FreeDiskBytes 140GB -VMs $existing -OccupiedPaths @()
Assert-True $enough.CapacityAndNamesPassNow 'Exact resource boundary should pass capacity only'
Assert-True (-not $enough.CreateSupported -and -not $enough.ExecutionAuthorized) 'Capacity must never authorize creation'
$collision = Get-SentinelFreshClusterCapacity -FreeMemoryBytes 32GB -FreeDiskBytes 200GB `
    -VMs @([pscustomobject]@{Name='CP01'; MemoryAssigned=0}) -OccupiedPaths @()
Assert-True (-not $collision.CapacityAndNamesPassNow) 'Names must collide case-insensitively'
$disk = Get-SentinelFreshClusterCapacity -FreeMemoryBytes 32GB -FreeDiskBytes 139GB -VMs @() -OccupiedPaths @()
Assert-True (-not $disk.CapacityAndNamesPassNow) 'Budget full disk capacities and reserve'
$path = Get-SentinelFreshClusterCapacity -FreeMemoryBytes 32GB -FreeDiskBytes 200GB -VMs @() -OccupiedPaths @('existing')
Assert-True (-not $path.CapacityAndNamesPassNow) 'An existing storage root must block reuse'
$errors = $null
$tokens = $null
$collector = Join-Path $PSScriptRoot '..\tools\Get-SentinelFreshClusterPlan.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'Collector must parse'
$allowed = @('Set-StrictMode','Import-Module','Join-Path','Get-CimInstance','Get-Volume',
    'Get-VM','Test-Path','Get-Item','Get-ChildItem','Get-SentinelFreshClusterCapacity','Select-Object',
    'Get-VMSwitch','Get-NetRoute','ConvertTo-Json')
$commands = $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst]}, $true)
foreach ($command in $commands) {
    Assert-True ($command.GetCommandName() -in $allowed) 'Collector contains an unreviewed command'
}
Write-Host 'PASS: 8 offline planning assertions and collector command allowlist; no live infrastructure accessed'
