#Requires -Version 5.1
<#
.SYNOPSIS
  Sentinel Stage 5.3.4 trusted SSH host-key registration for ONE disposable VM.
.DESCRIPTION
  PLAN: read Hyper-V KVP and network SSH host key; validate independent
  provisioning manifest; show whether a protected dedicated trust file exists.
  REGISTER: separately approved, create that file only when all proofs match.
  ACCEPT: read-only SSH authentication with ONLY the newly registered key,
  no provisional diagnostic known_hosts, no SSH configuration or updates.
  No guest/VM/network/cluster changes, no new SSH private keys.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','REGISTER','ACCEPT')][string]$Mode = 'PLAN',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Approval is checked BEFORE all Hyper-V and network access.
if ($Mode -eq 'REGISTER' -and
    $Approval -cne 'REGISTER_DISPOSABLE_SENTINEL_W02_KVP_VERIFIED_SSH_HOST') {
    throw 'BLOCKED: exact disposable-only trusted SSH host registration approval required'
}

$expectedId = [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'
$name = 'sentinel-e2e-w02'
$ip = '10.78.0.12'
$folder = 'C:\Sentinel\E2E-WorkerReplica\sentinel-e2e-w02'
$manifestFile = Join-Path $folder 'provisioning.json'
$trustedFile = Join-Path $folder 'trusted_known_hosts'
$module = Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1'
$trustModule = Join-Path $PSScriptRoot '..\src\Sentinel.SshTrust.psm1'
Import-Module $module -Force -ErrorAction Stop
Import-Module $trustModule -Force -ErrorAction Stop

# Bind KVP evidence to exactly the originally provisioned Hyper-V VM and
# host-created manifest. Never select by a guest-reported VM name alone.
$vms = @(Get-VM -Name $name -ErrorAction Stop)
if ($vms.Count -ne 1 -or $vms[0].Id -ne $expectedId -or
    $vms[0].State -ne 'Running') {
    throw 'BLOCKED: disposable VM UUID or running state mismatch'
}
$vm = $vms[0]
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf) -or
    (Get-Item -LiteralPath $manifestFile).Length -gt 8192) {
    throw 'BLOCKED: immutable provisioner manifest missing or oversized'
}
$manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schema -ne 1 -or
    [string]$manifest.purpose -cne 'disposable-worker-replica-e2e' -or
    [string]$manifest.node -cne $name -or
    [string]$manifest.privateIP -cne $ip -or
    [guid]$manifest.vmId -ne $expectedId -or
    [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$' -or
    [string]$manifest.managementMAC -cne '02AA78000112' -or
    [string]$manifest.privateMAC -cne '02AA78000012' -or
    $manifest.kubernetesInstall -ne $false) {
    throw 'BLOCKED: independent provisioning record changed'
}
$nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
$mgmt = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -eq '02AA78000112' })
$private = @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -eq '02AA78000012' })
if ($nics.Count -ne 2 -or $mgmt.Count -ne 1 -or $private.Count -ne 1) {
    throw 'BLOCKED: two-NIC disposable identity changed'
}
$service = @(Get-VMIntegrationService -VMName $name -ErrorAction Stop |
    Where-Object { $_.Name -in @('Key-Value Pair Exchange','Data Exchange') })
if ($service.Count -ne 1 -or -not $service[0].Enabled -or
    $service[0].PrimaryStatusDescription -cne 'OK') {
    throw 'BLOCKED: host Hyper-V KVP integration is unavailable'
}

$system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter "Name='$($vm.Id)'")
if ($system.Count -ne 1) { throw 'BLOCKED: Hyper-V VM UUID not found by CIM' }
$exchange = @(Get-CimAssociatedInstance -InputObject $system[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
if ($exchange.Count -ne 1) { throw 'BLOCKED: exact VM guest KVP exchange component missing' }
$guestJson = ConvertFrom-SentinelKvpXml -Items @($exchange[0].GuestExchangeItems)
$entry = [pscustomobject]@{
    node=$name
    ip=$ip
    vmId=[string]$manifest.vmId
    nonce=[string]$manifest.nonce
}
$evidence = Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId ([string]$vm.Id) -GuestData $guestJson

# A network-first scan is only evidence for comparison. It never establishes
# trust on its own, and its response is never stored or accepted without KVP.
$scanner = 'C:\Program Files\Git\usr\bin\ssh-keyscan.exe'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw 'BLOCKED: expected Git for Windows ssh-keyscan.exe missing'
}
$observed = @(& $scanner -T 5 -t ed25519 $ip 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: network SSH host key observation failed' }
$matching = @($observed | Where-Object { $_ -cmatch '^10\.78\.0\.12 ssh-ed25519 [A-Za-z0-9+/]+={0,2}$' })
if ($matching.Count -ne 1) { throw 'BLOCKED: exactly one ED25519 network host key required' }
$networkPublicKey = $matching[0].Substring(($ip + ' ').Length)
if ($networkPublicKey -cne [string]$evidence.publicKey) {
    throw 'BLOCKED: network host key disagrees with VM-bound KVP public key'
}
$line = Get-SentinelTrustedHostLine -IPAddress $ip -PublicKey ([string]$evidence.publicKey) -Fingerprint ([string]$evidence.fingerprint)

# This file is deliberately distinct from the provisional diagnostic key.
$state = Get-SentinelTrustStoreState -Path $trustedFile -ExpectedLine $line
Write-Host "SENTINEL_STAGE534_$($Mode): VM=$name; ip=$ip; fingerprint=$($evidence.fingerprint); store=$state"

if ($Mode -eq 'PLAN') {
    Write-Host "SENTINEL_SSH_TRUST_PLAN_READY: verified KVP/VM-ID/nonce/network evidence; dedicated trust store=$state; read-only."
    return
}

if ($Mode -eq 'REGISTER') {
    $registration = Register-SentinelTrustedHostFile -Path $trustedFile -ExpectedLine $line
    Write-Host "SENTINEL_SSH_HOST_TRUST_$($registration): VM UUID and KVP-verified host key pinned in dedicated file."
    Write-Host 'No global known_hosts, diagnostic key, VM settings or Kubernetes nodes changed.'
    return
}

if ($state -ne 'MATCH') {
    throw 'BLOCKED: SSH acceptance requires an existing protected, matching trusted_known_hosts file'
}

# Stage 5.3.5 preview: actual user SSH authentication with ONLY the key that
# Stage 5.3.4 registered. No SSH agent, TOFU, host key updates, agent
# forwarding, config overrides, password prompts, jump hosts or diagnostic file.
$ssh = 'C:\Program Files\Git\usr\bin\ssh.exe'
$identity = Join-Path $HOME '.ssh\id_ed25519'
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf) -or
    -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    throw 'BLOCKED: approved SSH client or existing login private key missing'
}
$sshArgs = @(
    '-F','none',
    '-T',
    '-n',
    '-i',$identity,
    '-o','IdentitiesOnly=yes',
    '-o','IdentityAgent=none',
    '-o','BatchMode=yes',
    '-o','PasswordAuthentication=no',
    '-o','KbdInteractiveAuthentication=no',
    '-o','PreferredAuthentications=publickey',
    '-o','ConnectTimeout=10',
    '-o','StrictHostKeyChecking=yes',
    '-o','HostKeyAlgorithms=ssh-ed25519',
    '-o','UpdateHostKeys=no',
    '-o','VerifyHostKeyDNS=no',
    '-o','ControlMaster=no',
    '-o','ForwardAgent=no',
    '-o','ClearAllForwardings=yes',
    '-o',"UserKnownHostsFile=$trustedFile",
    '-o','GlobalKnownHostsFile=/dev/null',
    "orzu@$ip",
    'hostname'
)
$answer = @(& $ssh @sshArgs)
if ($LASTEXITCODE -ne 0) {
    throw "BLOCKED: authenticated SSH with KVP-pinned host key failed (exit=$LASTEXITCODE)"
}
if ($answer.Count -ne 1 -or $answer[0].Trim() -cne $name) {
    throw 'BLOCKED: authenticated SSH reported an unexpected guest hostname'
}
if ((Get-SentinelTrustStoreState -Path $trustedFile -ExpectedLine $line) -ne 'MATCH') {
    throw 'BLOCKED: trust store changed during authenticated SSH validation'
}
Write-Host "SENTINEL_SSH_PINNED_AUTHENTICATION_PASS: host=$name; fingerprint=$($evidence.fingerprint); command=hostname."
Write-Host 'Only dedicated KVP-pinned trusted_known_hosts used; no provisional key, auto-trust, password or host-key updates.'
