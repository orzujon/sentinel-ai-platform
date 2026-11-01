#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.3.3 - disposable VM SSH host PUBLIC key publication and host-side KVP verification.
.DESCRIPTION
  PLAN: root-only guest checks, NO KVP pool writes.
  PUBLISH: separately approved, one-time guest record publication.
  VERIFY: reads Hyper-V guest-origin KVP via CIM, checks provisioner manifest,
          then compares the public key observed over untrusted SSH networking.
  Never copies a private key or modifies known_hosts; existing Kubernetes VMs
  and switches are completely out of scope. Provisional SSH trust is used
  solely to administer this disposable test VM, not for identity attestation.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','PUBLISH','VERIFY')][string]$Mode = 'PLAN',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedId = [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'
$name = 'sentinel-e2e-w02'
$ip = '10.78.0.12'
$folder = 'C:\Sentinel\E2E-WorkerReplica\sentinel-e2e-w02'
$manifestFile = Join-Path $folder 'provisioning.json'
$knownHosts = Join-Path $folder 'diagnostic_known_hosts'
$source = Join-Path $PSScriptRoot '..\src\publish_worker_replica_kvp.py'
$module = Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1'

# Operator approval is a deployment gate, not a credential.
if ($Mode -eq 'PUBLISH' -and $Approval -cne 'PUBLISH_DISPOSABLE_SENTINEL_W02_HOST_PUBLIC_KEY') {
    throw 'BLOCKED: explicit disposable-only publication approval required'
}

$vm = @(Get-VM -Name $name -ErrorAction Stop)
if ($vm.Count -ne 1 -or $vm[0].Id -ne $expectedId -or $vm[0].State -ne 'Running') {
    throw 'BLOCKED: unexpected disposable VM identity/state'
}
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf) -or
    (Get-Item -LiteralPath $manifestFile).Length -gt 8192) {
    throw 'BLOCKED: missing or oversized provisioner manifest'
}
$manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schema -ne 1 -or
    [string]$manifest.node -cne $name -or
    [string]$manifest.purpose -cne 'disposable-worker-replica-e2e' -or
    [string]$manifest.privateIP -cne $ip -or
    [guid]$manifest.vmId -ne $expectedId -or
    [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$' -or
    [string]$manifest.managementMAC -cne '02AA78000112' -or
    [string]$manifest.privateMAC -cne '02AA78000012' -or
    $manifest.kubernetesInstall -ne $false) {
    throw 'BLOCKED: independent provisioning record mismatch'
}
$nics = @(Get-VMNetworkAdapter -VM $vm[0] -ErrorAction Stop)
$mgmt = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -eq '02AA78000112' })
$private = @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -eq '02AA78000012' })
if ($nics.Count -ne 2 -or $mgmt.Count -ne 1 -or $private.Count -ne 1) {
    throw 'BLOCKED: disposable worker NIC layout drifted'
}
$service = @(Get-VMIntegrationService -VMName $name -ErrorAction Stop |
    Where-Object { $_.Name -in @('Key-Value Pair Exchange','Data Exchange') })
if ($service.Count -ne 1 -or -not $service[0].Enabled -or
    $service[0].PrimaryStatusDescription -cne 'OK') {
    throw 'BLOCKED: Hyper-V KVP integration is not currently OK'
}

if ($Mode -eq 'VERIFY') {
    Import-Module $module -Force -ErrorAction Stop
    # Windows trusts VM registration + the provisioner-created host manifest,
    # NOT any VM ID or IP claimed inside the guest-origin JSON.
    $system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter "Name='$($vm[0].Id)'")
    if ($system.Count -ne 1) { throw 'BLOCKED: exact Hyper-V VM not resolved by UUID' }
    $exchange = @(Get-CimAssociatedInstance -InputObject $system[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
    if ($exchange.Count -ne 1) { throw 'BLOCKED: KVP exchange component unavailable' }
    $published = ConvertFrom-SentinelKvpXml -Items @($exchange[0].GuestExchangeItems)
    $entry = [pscustomobject]@{
        node = $name
        ip = $ip
        vmId = [string]$manifest.vmId
        nonce = [string]$manifest.nonce
    }
    $result = Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId ([string]$vm[0].Id) -GuestData $published
    # Network observation is not an authority: compare it to independent KVP
    # evidence, never auto-accept it into a trusted SSH host-key store.
    $scanner = 'C:\Program Files\Git\usr\bin\ssh-keyscan.exe'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        throw 'BLOCKED: read-only SSH key scanner unavailable'
    }
    $scan = @(& $scanner -T 5 -t ed25519 $ip 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: network SSH host-key observation failed' }
    $records = @($scan | Where-Object { $_ -match '^10\.78\.0\.12 ssh-ed25519 [A-Za-z0-9+/]+={0,2}$' })
    if ($records.Count -ne 1) { throw 'BLOCKED: require exactly one observed ED25519 SSH host key' }
    $observedPublicKey = $records[0] -replace '^10\.78\.0\.12 ', ''
    $observedFP = Get-SentinelHostKeyFingerprint -PublicKey $observedPublicKey
    if ($observedFP -cne $result.fingerprint -or
        $observedPublicKey -cne $result.publicKey) {
        throw 'BLOCKED: network-observed SSH identity differs from Hyper-V KVP evidence'
    }
    $result | Select-Object node,ip,vmId,fingerprint,result,trusted | Format-List
    Write-Host 'SENTINEL_KVP_SSH_IDENTITY_EVIDENCE_MATCH: provisioner VM UUID, nonce, host-published key, and network-observed key agree.'
    Write-Host 'EVIDENCE_ONLY: no private keys transferred, no known_hosts modified, trusted=false.'
    return
}

if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'BLOCKED: guest publisher source unavailable'
}
if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
    throw 'BLOCKED: isolated diagnostic known_hosts not found'
}
$trusted = @(Get-Content -LiteralPath $knownHosts -Encoding ASCII)
if ($trusted.Count -ne 1 -or
    $trusted[0] -notmatch '^10\.78\.0\.12 ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') {
    throw 'BLOCKED: provisional diagnostic SSH key file unexpected'
}
$ssh = 'C:\Program Files\Git\usr\bin\ssh.exe'
$identity = Join-Path $HOME '.ssh\id_ed25519'
if (-not (Test-Path -LiteralPath $ssh -PathType Leaf) -or
    -not (Test-Path -LiteralPath $identity -PathType Leaf)) {
    throw 'BLOCKED: diagnostic SSH client or user identity missing'
}

$python = Get-Content -LiteralPath $source -Raw -Encoding UTF8
$guestMode = if ($Mode -eq 'PUBLISH') { 'publish' } else { 'plan' }
# No remote shell quotes, embedded base64 or long command argument.
# OpenSSH forwards its standard input to Python's standard input.
# This avoids Windows PowerShell / Git SSH argument-quoting failures.
$remote = if ($Mode -eq 'PUBLISH') {
    'sudo -n python3 - --mode publish --approval PUBLISH_DISPOSABLE_SENTINEL_W02_HOST_PUBLIC_KEY'
} else {
    'sudo -n python3 - --mode plan'
}
$sshArgs = @(
    '-i', $identity,
    '-o', 'IdentitiesOnly=yes',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$knownHosts",
    '-o', 'GlobalKnownHostsFile=/dev/null',
    "orzu@$ip",
    $remote
)
# PowerShell 5.1 defaults to an ASCII native-pipeline encoding. Explicit UTF-8
# preserves source bytes and supports both Windows PowerShell and PowerShell 7.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Host "SENTINEL_KVP_PUBLIC_KEY_$($Mode): VM=$name; trust=DIAGNOSTIC_ONLY"
$python | & $ssh @sshArgs
if ($LASTEXITCODE -ne 0) {
    throw "BLOCKED: guest KVP public-key $Mode failed; exit=$LASTEXITCODE; do not blindly retry"
}
Write-Host "SENTINEL_KVP_PUBLIC_KEY_$($Mode)_PASS: disposable guest only; host identity still untrusted"
