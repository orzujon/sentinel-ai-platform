#Requires -Version 5.1
# Stage 5 phase classification tests; entirely synthetic and no Hyper-V calls.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.Bootstrap.psm1') -Force

$expected = @('sentinel-l1-cp01','sentinel-l1-w01')
$tests = @(
    @{ Names=@('other-vm'); Switch=$false; Root=$false; Want='new-sandbox' },
    @{ Names=@('other-vm','sentinel-l1-cp01','sentinel-l1-w01'); Switch=$true; Root=$true; Want='verify-existing' },
    @{ Names=@('sentinel-l1-cp01'); Switch=$true; Root=$true; Want='blocked-partial' },
    @{ Names=@(); Switch=$true; Root=$true; Want='blocked-partial' },
    @{ Names=@(); Switch=$false; Root=$true; Want='blocked-partial' },
    @{ Names=$expected; Switch=$false; Root=$true; Want='blocked-partial' }
)
foreach ($case in $tests) {
    $actual = Get-SentinelBootstrapRoute -ExpectedVMNames $expected -ExistingVMNames @($case.Names) -ExpectedSwitchExists ([bool]$case.Switch) -ExpectedVMRootExists ([bool]$case.Root)
    if ($actual -cne $case.Want) { throw "Unsafe route classification: expected $($case.Want), got $actual" }
}
try {
    Get-SentinelBootstrapRoute -ExpectedVMNames @('unrelated-cp','unrelated-w') -ExistingVMNames @() -ExpectedSwitchExists $false -ExpectedVMRootExists $false | Out-Null
    throw 'Unapproved VM names must not be accepted'
} catch {
    if ($_.Exception.Message -match 'Unapproved VM names') { throw }
}
Write-Host 'PASS: Stage 5 route planner refuses partial infrastructure and protected identities'
