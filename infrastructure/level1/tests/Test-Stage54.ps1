#Requires -Version 5.1
# Windows CI for Stage54; NO real Hyper-V VM, network or SSH connections.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$creator = Join-Path $root 'tools\New-SentinelStage54VM.ps1'
$trust = Join-Path $root 'tools\Invoke-SentinelStage54Trust.ps1'
$pipeline = Join-Path $root 'tools\Invoke-SentinelStage54.ps1'
$kvp = Join-Path $root 'src\Sentinel.KvpEvidence.psm1'
$trusted = Join-Path $root 'src\Sentinel.SshTrust.psm1'
foreach ($file in @($creator,$trust,$pipeline,$kvp,$trusted)) {
    $tokens=$null
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        throw "BLOCKED: PowerShell parser error: $file; $($errors | Out-String)"
    }
}
function Expect-Blocked([scriptblock]$Action) {
    try {
        & $Action | Out-Null
        throw 'Expected BLOCKED'
    } catch {
        if ($_.Exception.Message -eq 'Expected BLOCKED') { throw }
        if ($_.Exception.Message -notmatch 'BLOCKED') {
            throw ('BLOCKED: unexpected error instead of approval gate: ' + $_.Exception.Message)
        }
    }
}
$fake = 'a' * 64
Expect-Blocked { & $creator -Mode CREATE -Slot 20 -ImagePath 'C:\missing.img' -ImageSHA256 $fake }
Expect-Blocked { & $pipeline -Mode RUN -Slot 20 -ImagePath 'C:\missing.img' -ImageSHA256 $fake }
Expect-Blocked { & $trust -Mode REGISTER -Slot 20 }
Expect-Blocked { & $trust -Mode REGISTER -Slot 20 -Approval 'wrong' }

$createSrc = Get-Content -LiteralPath $creator -Raw -Encoding UTF8
$trustSrc = Get-Content -LiteralPath $trust -Raw -Encoding UTF8
$pipelineSrc = Get-Content -LiteralPath $pipeline -Raw -Encoding UTF8
foreach ($req in @(
    "ValidateRange(20,29)",
    "C:\Sentinel\Stage54",
    "sentinel-e2e-auto",
    "CREATE_FRESH_DISPOSABLE_SENTINEL_STAGE54",
    "Get-VMNetworkAdapter -All",
    "Get-NetIPAddress",
    "Get-NetNeighbor",
    "Get-VMSwitch",
    "sourceImageSHA256",
    "Get-FileHash",
    "SetAccessRuleProtection",
    "Resize-VHD",
    "AutomaticCheckpointsEnabled",
    "Sentinel-L1",
    "Default Switch",
    "To-B64",
    "publish_firstboot_kvp.py",
    "firstboot-kvp-setup.sh",
    "ssh_deletekeys: true",
    "ssh_pwauth: false",
    "ssh_authorized_keys:",
    "runcmd:",
    "STAGE54_VM_CREATED"
)) {
    if (-not $createSrc.Contains($req)) { throw "BLOCKED: creator missing guarded contract: $req" }
}
foreach ($req in @(
    "ValidateRange(20,29)",
    "Msvm_ComputerSystem",
    "Msvm_KvpExchangeComponent",
    "GuestExchangeItems",
    "ConvertFrom-SentinelKvpXml",
    "Assert-SentinelKvpIdentity",
    "Get-SentinelTrustedHostLine",
    "Register-SentinelTrustedHostFile",
    "Get-SentinelTrustStoreState",
    "ssh-keyscan.exe",
    "Stage54",
    "REGISTER_KVP_VERIFIED_SENTINEL_STAGE54_HOST_KEY",
    "StrictHostKeyChecking=yes",
    "HostKeyAlgorithms=ssh-ed25519",
    "PasswordAuthentication=no",
    "BatchMode=yes",
    'UserKnownHostsFile=$trustedFile',
    "IdentityAgent=none",
    "GlobalKnownHostsFile=/dev/null",
    "ANSIBLE_HOST_KEY_CHECKING=True",
    "-m ping",
    "STAGE54_ANSIBLE_HANDOFF_PASS"
)) {
    if (-not $trustSrc.Contains($req)) { throw "BLOCKED: trust/ansible workflow missing safety contract: $req" }
}
foreach ($req in @(
    "CREATE_AND_REGISTER_FRESH_SENTINEL_STAGE54",
    "New-SentinelStage54VM.ps1",
    "Invoke-SentinelStage54Trust.ps1",
    "Start-Sleep",
    "STAGE54_WAITING_FOR_FIRSTBOOT_KVP",
    "STAGE54_ZERO_TOUCH_E2E_PASS"
)) {
    if (-not $pipelineSrc.Contains($req)) { throw "BLOCKED: run orchestrator missing: $req" }
}
foreach ($s in @($createSrc,$trustSrc,$pipelineSrc)) {
    foreach ($forbid in @('Remove-VM ', 'Stop-VM ', 'Remove-VMSwitch ', 'New-VMSwitch ', 'StrictHostKeyChecking=accept-new', 'StrictHostKeyChecking=no', 'UserKnownHostsFile=NUL','ssh-keygen -R')) {
        if ($s.Contains($forbid)) { throw "BLOCKED: forbidden Stage54 destructive/TOFU primitive: $forbid" }
    }
}
if ($createSrc.Contains('ssh-keyscan') -or $createSrc.Contains('diagnostic_known_hosts')) {
    throw 'BLOCKED: firstboot provisioning must never rely on untrusted diagnostic SSH key discovery'
}

Import-Module $kvp -Force -ErrorAction Stop
Import-Module $trusted -Force -ErrorAction Stop
$wire = [byte[]](0,0,0,11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') +
    [byte[]](0,0,0,32) + ([byte[]](34) * 32)
$key = 'ssh-ed25519 ' + [Convert]::ToBase64String($wire)
$fp = Get-SentinelHostKeyFingerprint -PublicKey $key
$vmId = [guid]::NewGuid().ToString()
foreach ($slot in 20..29) {
    $node = 'sentinel-e2e-auto' + $slot
    $ip = '10.78.0.' + $slot
    $entry = [pscustomobject]@{node=$node;ip=$ip;vmId=$vmId;nonce=('a'*64)}
    $json = [ordered]@{schema=1;node=$node;ip=$ip;nonce=('a'*64);publicKey=$key;fingerprint=$fp} | ConvertTo-Json -Compress
    $validated = Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $vmId -GuestData $json
    if ($validated.trusted -ne $false -or $validated.fingerprint -cne $fp) {
        throw "BLOCKED: Stage54 slot $slot failed nonce/VM UUID/host-key contract"
    }
    $known = Get-SentinelTrustedHostLine -IPAddress $ip -PublicKey $key -Fingerprint $fp
    if ($known -cne "$ip $key") { throw 'BLOCKED: unexpected SSH known_hosts payload' }
    $wrong = [pscustomobject]@{node=$node;ip=('10.78.0.'+($slot+1));vmId=$vmId;nonce=('a'*64)}
    Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $wrong -ActualVMId $vmId -GuestData $json }
}
foreach ($bad in @('10.78.0.10','10.78.0.11','10.78.0.19','10.78.0.30','127.0.0.1')) {
    Expect-Blocked { Get-SentinelTrustedHostLine -IPAddress $bad -PublicKey $key -Fingerprint $fp }
}
Write-Host 'PASS: Stage54 firstboot no-TOFU safety contracts, all 10 disposable slots, fail-closed approvals and VM-bound public host identity'
