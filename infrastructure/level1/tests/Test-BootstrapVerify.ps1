#Requires -Version 5.1
# Stage 5.2 static safety checks: verify mode cannot mutate the lab.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$entry = Get-Content -LiteralPath (Join-Path $root 'sentinel.ps1') -Raw
$module = Get-Content -LiteralPath (Join-Path $root 'src\Sentinel.Bootstrap.psm1') -Raw

if ($entry -notmatch "'bootstrap-verify'" -or $entry -notmatch 'Invoke-SentinelBootstrapVerify') {
    throw 'Stage 5 verify command is not connected'
}
if ($module -notmatch 'Invoke-SentinelBootstrapPlan' -or
    $module -notmatch 'Assert-SentinelExistingHyperV' -or
    $module -notmatch '& \$Stage4Script -ConfigRepo \$ConfigRepo -Reconcile') {
    throw 'Stage 5 verification does not chain route, Hyper-V, and read-only Kubernetes checks'
}
$verifySection = ($module -split 'function Invoke-SentinelBootstrapVerify \{')[1]
if ([string]::IsNullOrWhiteSpace($verifySection)) { throw 'Stage 5 verification implementation missing' }
foreach ($prohibited in @('-ReconcileApprovalToken','-NetworkTest','New-VM','Remove-VM','Stop-VM','kubeadm init','kubeadm reset')) {
    if ($verifySection.Contains($prohibited)) { throw "Forbidden mutating operation in verification: $prohibited" }
}
if ($module -notmatch "stage='kubernetes-readonly'" -or $module -notmatch 'mutating = \$false') {
    throw 'Stage 5 verification report or read-only contract missing'
}
if ($verifySection -notmatch '& \$Stage4Script -ConfigRepo \$ConfigRepo -Reconcile \| Out-Host') {
    throw 'Stage 4 console output must not contaminate Stage 5 structured result'
}
if ($verifySection -notmatch '\$LASTEXITCODE -ne 0' -or
    $verifySection -notmatch "Stage 4 read-only reconciliation failed") {
    throw 'Stage 5 must fail closed on a nonzero Stage 4 process exit'
}
Write-Host 'PASS: Stage 5.2 existing-lab verification safely chains read-only controls'
