#Requires -Version 5.1
# Offline, non-destructive syntax and config isolation tests.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$files = @(
    (Join-Path $root 'sentinel.ps1'),
    (Join-Path $root 'src\Sentinel.Preflight.psm1'),
    (Join-Path $root 'src\Sentinel.Images.psm1'),
    (Join-Path $root 'src\Sentinel.Infrastructure.psm1'),
    (Join-Path $root 'src\Sentinel.GuestHealth.psm1')
)
foreach ($path in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parser errors in $path`: $($errors | Out-String)"
    }
    Write-Host "Syntax PASS: $path"
}

$config = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\lab.json') -Raw | ConvertFrom-Json
if ($config.mode -ne 'isolated-sandbox') { throw 'Sandbox isolation missing' }
foreach ($vm in $config.vms) {
    if ($vm.name -in @($config.protection.vmNames)) { throw "VM overlaps protected list: $($vm.name)" }
}
if ($config.network.switch -in @($config.protection.switchNames)) { throw 'Switch overlap' }
if ($config.network.subnet -eq '10.77.0.0/24') { throw 'Existing lab network reused' }
if ($config.paths.vmRoot -notlike 'C:\Sentinel\Level1-Sandbox\VMs*') { throw 'Sandbox storage escaped allowlist' }
Write-Host 'Protection config PASS'

Import-Module (Join-Path $root 'src\Sentinel.Preflight.psm1') -Force
if (-not (Test-SentinelSubnetsOverlap '10.77.0.0/24' '10.77.0.128/25')) { throw 'Overlap test failed' }
if (Test-SentinelSubnetsOverlap '10.78.0.0/24' '10.77.0.0/24') { throw 'Disjoint subnet test failed' }
if (-not (Test-SentinelSubnetsOverlap '10.78.0.0/24' '10.0.0.0/8')) { throw 'Parent subnet overlap failed' }
Write-Host 'IPv4 overlap tests PASS'
Write-Host 'All static safety checks passed. No VMs were inspected or changed.'
