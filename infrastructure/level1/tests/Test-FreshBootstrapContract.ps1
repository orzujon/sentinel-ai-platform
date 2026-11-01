#Requires -Version 5.1
# Stage 5.3 offline fresh-bootstrap dependency contract. NEVER invokes VM tools.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.Bootstrap.psm1') -Force
$steps = @(Get-SentinelFreshBootstrapSteps)
if ($steps.Count -ne 11) { throw 'Unexpected fresh-bootstrap step count' }
$ids = @($steps | ForEach-Object { $_.id })
if (@($ids | Sort-Object -Unique).Count -ne $steps.Count) { throw 'Duplicate bootstrap step' }
$completed = @()
$last = 0
foreach ($step in $steps) {
    if ($step.order -le $last) { throw 'Bootstrap sequence is out of order' }
    foreach ($prereq in $step.requires) {
        if ($prereq -notin $completed) { throw "Missing or future dependency for $($step.id): $prereq" }
    }
    $last = $step.order
    $completed += $step.id
}
$critical = @('guest-first-trust','worker-join')
foreach ($id in $critical) {
    $found = @($steps | Where-Object { $_.id -eq $id })
    if ($found.Count -ne 1 -or $found[0].ready -ne $false) {
        throw "Unsafe assertion: bootstrap prerequisite $id must remain unimplemented"
    }
}
foreach ($id in @('hyperv-create','linux-baseline','kubernetes-packages','control-plane-init','worker-join')) {
    $found = @($steps | Where-Object { $_.id -eq $id })[0]
    if ($found.approval -eq 'none') { throw "Mutating $id missing approval policy" }
}
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Sentinel.Bootstrap.psm1') -Raw
if ($source -notmatch 'freshBootstrapReady = \$false') {
    throw 'Full clean bootstrap must remain explicitly unsupported'
}
Write-Host 'PASS: Stage 5.3 fresh bootstrap dependency map and fail-closed gates'
