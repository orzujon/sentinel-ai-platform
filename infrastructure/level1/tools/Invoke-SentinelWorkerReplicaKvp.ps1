#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.3 disposable worker KVP PLAN/APPLY with one explicit approval gate.
.DESCRIPTION
  PLAN is read-only on Windows and Linux. APPLY installs exactly five reviewed
  Ubuntu package versions after a fresh simulation, then starts the KVP daemon.
  SSH trust is provisional and diagnostic only, not production attestation.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','APPLY')][string]$Mode = 'PLAN',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedId = [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'
$name = 'sentinel-e2e-w02'
$folder = 'C:\Sentinel\E2E-WorkerReplica\sentinel-e2e-w02'
$manifestFile = Join-Path $folder 'provisioning.json'
$knownHosts = Join-Path $folder 'diagnostic_known_hosts'
$source = Join-Path $PSScriptRoot '..\src\worker-replica-kvp.sh'

# Approval must be checked before any network interaction or guest mutation.
if ($Mode -eq 'APPLY' -and $Approval -cne 'INSTALL_DISPOSABLE_SENTINEL_W02_KVP_FIVE_PACKAGES') {
    throw 'BLOCKED: explicit reviewed five-package disposable VM approval required'
}
$vm = @(Get-VM -Name $name -ErrorAction Stop)
if ($vm.Count -ne 1 -or $vm[0].Id -ne $expectedId -or $vm[0].State -ne 'Running') {
    throw 'BLOCKED: disposable worker VM ID or state differs from approved record'
}
$manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
if ([guid]$manifest.vmId -ne $expectedId -or
    [string]$manifest.node -cne $name -or
    [string]$manifest.purpose -cne 'disposable-worker-replica-e2e' -or
    [string]$manifest.privateIP -cne '10.78.0.12' -or
    [string]$manifest.managementMAC -cne '02AA78000112' -or
    [string]$manifest.privateMAC -cne '02AA78000012' -or
    [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$') {
    throw 'BLOCKED: disposable worker provisioning manifest mismatch'
}
$nics = @(Get-VMNetworkAdapter -VM $vm[0] -ErrorAction Stop)
$mgmt = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -eq '02AA78000112' })
$private = @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -eq '02AA78000012' })
if ($nics.Count -ne 2 -or $mgmt.Count -ne 1 -or $private.Count -ne 1) {
    throw 'BLOCKED: worker networking no longer matches approved two-NIC layout'
}
if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
    throw 'BLOCKED: isolated diagnostic known_hosts missing'
}
$trusted = @(Get-Content -LiteralPath $knownHosts -Encoding ASCII)
if ($trusted.Count -ne 1 -or $trusted[0] -notmatch '^10\.78\.0\.12 ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') {
    throw 'BLOCKED: expected one provisional ED25519 host key for 10.78.0.12'
}
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'BLOCKED: reviewed KVP transaction script missing'
}
$ssh = 'C:\Program Files\Git\usr\bin\ssh.exe'
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) {
    throw 'BLOCKED: Git for Windows SSH client missing'
}
$identity = Join-Path $HOME '.ssh\id_ed25519'
if (-not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    throw 'BLOCKED: SSH identity missing'
}

# Encode UTF-8 Linux script before piping it, avoiding CRLF shell failures.
$linux = Get-Content -LiteralPath $source -Raw -Encoding UTF8
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linux))
$guestMode = if ($Mode -eq 'APPLY') { 'apply' } else { 'plan' }
$runner = if ($Mode -eq 'APPLY') { 'sudo -n bash -s --' } else { 'bash -s --' }
$remote = "printf '%s' '$encoded' | base64 -d | $runner $guestMode"
$sshArgs = @(
    '-i', $identity,
    '-o', 'IdentitiesOnly=yes',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$knownHosts",
    '-o', 'GlobalKnownHostsFile=/dev/null',
    'orzu@10.78.0.12',
    $remote
)

Write-Host "SENTINEL_KVP_$($Mode): target=$name vmId=$expectedId; trust=PROVISIONAL_DIAGNOSTIC_ONLY"
& $ssh @sshArgs
if ($LASTEXITCODE -ne 0) {
    throw "BLOCKED: disposable KVP $Mode failed remotely with exit code $LASTEXITCODE; inspect output; do not auto-retry"
}
Write-Host "SENTINEL_KVP_$($Mode)_PASS: disposable VM only; existing Kubernetes VMs untouched"
