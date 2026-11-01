#Requires -Version 5.1
<#
.SYNOPSIS
  Sentinel Stage 5.4: KVP-verified SSH trust and Ansible handoff without TOFU.
.DESCRIPTION
  VERIFY is read-only. REGISTER creates one protected known_hosts file only
  after fresh VM UUID, nonce, KVP, and network SSH key matches. ACCEPT uses
  pinned SSH; ANSIBLE uses only that pinned key for a read-only ping module.
  Never changes Hyper-V VMs, networks, guest SSH policy or live Kubernetes.
#>
[CmdletBinding()]
param(
    [ValidateSet('VERIFY','REGISTER','ACCEPT','ANSIBLE')][string]$Mode = 'VERIFY',
    [ValidateRange(20,29)][int]$Slot = 20,
    [string]$WSLPrivateKey = '/home/orzu/.ssh/id_ed25519',
    [ValidateSet('Ubuntu-26.04')][string]$Distribution = 'Ubuntu-26.04',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'REGISTER' -and
    $Approval -cne 'REGISTER_KVP_VERIFIED_SENTINEL_STAGE54_HOST_KEY') {
    throw 'BLOCKED: Stage54 trust registration requires explicit approval'
}
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.SshTrust.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.WslPaths.psm1') -Force -ErrorAction Stop

$name = 'sentinel-e2e-auto' + $Slot
$ip = '10.78.0.' + $Slot
$mgmtMac = '02AA780001' + $Slot
$privateMac = '02AA780000' + $Slot
$folder = Join-Path 'C:\Sentinel\Stage54' $name
$manifestPath = Join-Path $folder 'provisioning.json'
$trustedFile = Join-Path $folder 'trusted_known_hosts'
$inventoryPath = Join-Path $folder 'ansible-inventory.ini'

function Get-SentinelStage54Identity {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        (Get-Item -LiteralPath $manifestPath).Length -gt 4096) {
        throw 'BLOCKED: missing or oversized trusted provisioning manifest'
    }
    $dir = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not ([IO.Directory]::GetAccessControl($folder)).AreAccessRulesProtected) {
        throw 'BLOCKED: provisioning manifest folder is reparse point or ACL not protected'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.schema -ne 2 -or
        [string]$manifest.purpose -cne 'sentinel-stage54-disposable-bootstrap' -or
        [string]$manifest.node -cne $name -or
        [string]$manifest.privateIP -cne $ip -or
        [string]$manifest.managementMAC -cne $mgmtMac -or
        [string]$manifest.privateMAC -cne $privateMac -or
        [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$manifest.sourceImageSHA256 -cnotmatch '^[a-f0-9]{64}$' -or
        $manifest.kubernetesInstall -ne $false) {
        throw 'BLOCKED: untrusted or inconsistent provisioning manifest'
    }
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$manifest.vmId,[ref]$id) -or $id -eq [guid]::Empty) {
        throw 'BLOCKED: invalid provisioner Hyper-V VM UUID'
    }
    $vms = @(Get-VM -Name $name -ErrorAction Stop)
    if ($vms.Count -ne 1 -or $vms[0].Id -ne $id -or
        $vms[0].State -ne 'Running') {
        throw 'BLOCKED: actual Hyper-V VM UUID/state differs from the provisioner'
    }
    $vm = $vms[0]
    $nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.MacAddress -ceq $mgmtMac -and $_.SwitchName -ceq 'Default Switch' }).Count -ne 1 -or
        @($nics | Where-Object { $_.MacAddress -ceq $privateMac -and $_.SwitchName -ceq 'Sentinel-L1' }).Count -ne 1) {
        throw 'BLOCKED: exact VM NIC/MAC/switch binding drifted'
    }
    $service = @(Get-VMIntegrationService -VMName $name -ErrorAction Stop |
        Where-Object { $_.Name -in @('Key-Value Pair Exchange','Data Exchange') })
    if ($service.Count -ne 1 -or -not $service[0].Enabled -or
        $service[0].PrimaryStatusDescription -cne 'OK') {
        throw 'BLOCKED: Hyper-V KVP is not yet ready; never use SSH first-contact fallback'
    }
    $system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter "Name='$id'")
    if ($system.Count -ne 1) { throw 'BLOCKED: actual VM UUID not resolvable through CIM' }
    $exchange = @(Get-CimAssociatedInstance -InputObject $system[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
    if ($exchange.Count -ne 1) { throw 'BLOCKED: guest-origin KVP exchange missing' }
    $payload = ConvertFrom-SentinelKvpXml -Items @($exchange[0].GuestExchangeItems)
    $entry = [pscustomobject]@{node=$name;ip=$ip;vmId=[string]$id;nonce=[string]$manifest.nonce}
    $evidence = Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId ([string]$vm.Id) -GuestData $payload
    $scanner = 'C:\Program Files\Git\usr\bin\ssh-keyscan.exe'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
        throw 'BLOCKED: expected non-trusting Git for Windows SSH scanner unavailable'
    }
    $scan = @(& $scanner -T 5 -t ed25519 $ip 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: network SSH key observation unavailable' }
    # Reject a second or changed key rather than trusting a mixed answer.
    $candidates = @($scan | Where-Object { $_ -cmatch ('^' + [regex]::Escape($ip) + ' ssh-ed25519 ') })
    if ($candidates.Count -ne 1 -or $candidates[0] -cne ($ip + ' ' + [string]$evidence.publicKey)) {
        throw 'BLOCKED: network SSH ED25519 key does not exactly match Hyper-V KVP evidence'
    }
    $line = Get-SentinelTrustedHostLine -IPAddress $ip -PublicKey ([string]$evidence.publicKey) -Fingerprint ([string]$evidence.fingerprint)
    return [pscustomobject]@{line=$line;fingerprint=[string]$evidence.fingerprint;vmId=[string]$id}
}

function Assert-PinnedSSH {
    param([Parameter(Mandatory)]$Evidence)
    if ((Get-SentinelTrustStoreState -Path $trustedFile -ExpectedLine $Evidence.line) -cne 'MATCH') {
        throw 'BLOCKED: dedicated trusted_known_hosts not registered or fingerprint changed'
    }
    $ssh = 'C:\Program Files\Git\usr\bin\ssh.exe'
    $private = Join-Path $HOME '.ssh\id_ed25519'
    if (-not (Test-Path -LiteralPath $ssh -PathType Leaf) -or
        -not (Test-Path -LiteralPath $private -PathType Leaf)) {
        throw 'BLOCKED: existing Windows SSH client or user private identity missing'
    }
    $sshArgs = @(
        '-F','none','-T','-n','-i',$private,
        '-o','IdentitiesOnly=yes','-o','IdentityAgent=none',
        '-o','BatchMode=yes','-o','PasswordAuthentication=no',
        '-o','KbdInteractiveAuthentication=no','-o','PreferredAuthentications=publickey',
        '-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes',
        '-o','HostKeyAlgorithms=ssh-ed25519','-o','UpdateHostKeys=no',
        '-o','VerifyHostKeyDNS=no','-o','ControlMaster=no',
        '-o','ForwardAgent=no','-o','ClearAllForwardings=yes',
        '-o',"UserKnownHostsFile=$trustedFile",
        '-o','GlobalKnownHostsFile=/dev/null',
        "orzu@$ip",'hostname'
    )
    $answer = @(& $ssh @sshArgs)
    if ($LASTEXITCODE -ne 0 -or $answer.Count -ne 1 -or $answer[0].Trim() -cne $name) {
        throw 'BLOCKED: strict SSH with KVP-pinned host key failed'
    }
    if ((Get-SentinelTrustStoreState -Path $trustedFile -ExpectedLine $Evidence.line) -cne 'MATCH') {
        throw 'BLOCKED: host trust changed during strict SSH'
    }
    Write-Host "STAGE54_PINNED_SSH_PASS: $name fingerprint=$($Evidence.fingerprint)"
}

$evidence = Get-SentinelStage54Identity
Write-Host "STAGE54_IDENTITY_MATCH: $name VM-ID=$($evidence.vmId) fingerprint=$($evidence.fingerprint)"
if ($Mode -eq 'VERIFY') {
    Write-Host 'STAGE54_KVP_VERIFY_PASS: fresh VM/nonce/KVP and SSH network identities agree; trust unchanged.'
    return
}
if ($Mode -eq 'REGISTER') {
    $registration = Register-SentinelTrustedHostFile -Path $trustedFile -ExpectedLine $evidence.line
    Write-Host "STAGE54_TRUST_$($registration): $name; protected, isolated known_hosts; no auto-acceptance."
    return
}
Assert-PinnedSSH -Evidence $evidence
if ($Mode -eq 'ACCEPT') { return }

# ANSIBLE: only after independent identity + trust + real SSH authentication.
# Requires an already existing WSL user key, not a new or copied credential.
if ($WSLPrivateKey -cnotmatch '^/home/[a-z][a-z0-9_-]*/\.ssh/id_ed25519$') {
    throw 'BLOCKED: Ansible key must be an existing /home/<user>/.ssh/id_ed25519'
}
$trustedLinuxPath = ConvertTo-SentinelWslMountPath $trustedFile
$inventoryLinuxPath = ConvertTo-SentinelWslMountPath $inventoryPath
$sshOptions = '-F none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=' + $trustedLinuxPath +
    ' -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519' +
    ' -o UpdateHostKeys=no -o VerifyHostKeyDNS=no -o BatchMode=yes' +
    ' -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no' +
    ' -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -o IdentityAgent=none' +
    ' -o ForwardAgent=no -o ControlMaster=no'
$nl = [string][char]10
$inventory = '[stage54]' + $nl + $name + ' ansible_host=' + $ip +
    ' ansible_user=orzu ansible_ssh_private_key_file=' + $WSLPrivateKey +
    " ansible_ssh_common_args='$sshOptions'" + $nl
if (Test-Path -LiteralPath $inventoryPath) {
    $current = Get-Item -LiteralPath $inventoryPath -Force
    if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8) -cne $inventory) {
        throw 'BLOCKED: existing Ansible inventory is a reparse point or has changed'
    }
} else {
    $stream = [IO.File]::Open($inventoryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($inventory)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush()
    } finally {
        $stream.Dispose()
    }
}
& wsl.exe -d $Distribution --exec test -r $WSLPrivateKey
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: existing controller WSL SSH private key not readable' }
& wsl.exe -d $Distribution --exec ansible --version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: Ansible not installed in controller WSL distribution' }
# Ansible ping is a read-only remote Python module, not network ICMP.
& wsl.exe -d $Distribution --exec env ANSIBLE_HOST_KEY_CHECKING=True ansible -i $inventoryLinuxPath $name -m ping -e 'ansible_python_interpreter=/usr/bin/python3' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: Ansible pinned-host-key ping failed' }
if ((Get-SentinelTrustStoreState -Path $trustedFile -ExpectedLine $evidence.line) -cne 'MATCH') {
    throw 'BLOCKED: trust file changed during Ansible handoff'
}
Write-Host "STAGE54_ANSIBLE_HANDOFF_PASS: $name inventory=$inventoryPath; KVP-pinned SSH only."
