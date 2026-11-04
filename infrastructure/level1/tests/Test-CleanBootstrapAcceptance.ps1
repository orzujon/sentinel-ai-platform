#Requires -Version 5.1
# All checks read repository source only. No Hyper-V/WSL/SSH/Ansible use.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root = Split-Path $PSScriptRoot -Parent
$files = @(
    'tools\Invoke-SentinelFreshCluster.ps1',
    'tools\Get-SentinelFreshClusterPlan.ps1',
    'src\Sentinel.FreshCluster.psm1',
    '..\ansible\playbooks\170-fresh-reboot-persistence.yml'
)
foreach ($relative in @($files[0..2])) {
    $file=Join-Path $root $relative
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -ne 0) { throw "BLOCKED: PowerShell syntax: $relative" }
}
$entry = Get-Content -LiteralPath (Join-Path $root $files[0]) -Raw
$plan = Get-Content -LiteralPath (Join-Path $root $files[1]) -Raw
$profile = Get-Content -LiteralPath (Join-Path $root $files[2]) -Raw
$reboot = Get-Content -LiteralPath (Join-Path $root $files[3]) -Raw
if (-not $profile.Contains("{ 'cp01' } else { 'w01' }") -or
    $profile.Contains('sentinel-fresh-cp01') -or $profile.Contains('sentinel-fresh-w01')) {
    throw 'BLOCKED: exact cp01/w01 identity drift'
}
foreach ($required in @(
    "if (@(Get-VM -ErrorAction Stop).Count -ne 0)",
    "FRESH_BOOTSTRAP_REVISION_PIN",
    "git -C " ,
    "status --porcelain",
    "FRESH_BOOTSTRAP_E2E_PASS",
    "'REBOOT-TEST'",
    "-Stage VERIFY",
    "-Stage NETWORK-TEST",
    "FRESH_REBOOT_PERSISTENCE_PASS"
)) {
    if (-not $entry.Contains($required)) {
        throw "BLOCKED: missing bootstrap/reboot acceptance requirement: $required"
    }
}
if ($entry.Contains('Remove-VM') -or $entry.Contains('Stop-VM') -or
    $entry.Contains('Remove-VMSnapshot') -or $entry.Contains('Restart-VM')) {
    throw 'BLOCKED: clean bootstrap unexpectedly contains destructive VM lifecycle operation'
}
foreach ($required in @(
    'Get-ChildItem','Get-Item','ReparsePoint','AreAccessRulesProtected'
)) {
    if (-not $plan.Contains($required)) {
        throw "BLOCKED: missing read-only cleanup-state inspection: $required"
    }
}
foreach ($required in @(
    "groups['sentinel_sandbox'] | sort == ['cp01', 'w01']",
    "order: reverse_inventory",
    "serial: 1",
    "ansible.builtin.reboot",
    "systemctl, is-active",
    "systemctl, is-enabled",
    "FRESH_REBOOT_NODE_PASS"
)) {
    if (-not $reboot.Contains($required)) {
        throw "BLOCKED: missing safe reboot-test gate: $required"
    }
}
if ($reboot -match 'force: true|remove:|delete:' ) {
    throw 'BLOCKED: reboot playbook contains prohibited destructive operation'
}
Write-Host 'PASS: cp01/w01-only clean bootstrap and sequential guarded reboot contract'
