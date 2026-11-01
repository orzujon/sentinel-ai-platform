#Requires -Version 5.1
# Synthetic KVP input and VM UUIDs; never calls Hyper-V or SSH.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1') -Force

$wire = [byte[]](0,0,0,11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') +
    [byte[]](0,0,0,32) + ([byte[]](1) * 32)
$key = 'ssh-ed25519 ' + [Convert]::ToBase64String($wire)
$fp = Get-SentinelHostKeyFingerprint -PublicKey $key
$vmId = [guid]::NewGuid().ToString()
$entry = [pscustomobject]@{ node='sentinel-l1-cp01'; ip='10.78.0.10'; vmId=$vmId; nonce=('a' * 64) }
$payload = [ordered]@{ schema=1; node=$entry.node; ip=$entry.ip; nonce=$entry.nonce; publicKey=$key; fingerprint=$fp }
$serialized = $payload | ConvertTo-Json -Compress
$xmlData = '<INSTANCE><PROPERTY NAME="Name"><VALUE>Sentinel.SSHHostKey.Ed25519</VALUE></PROPERTY><PROPERTY NAME="Data"><VALUE>' +
    [Security.SecurityElement]::Escape($serialized) + '</VALUE></PROPERTY></INSTANCE>'
$other = '<INSTANCE><PROPERTY NAME="Name"><VALUE>Unrelated</VALUE></PROPERTY><PROPERTY NAME="Data"><VALUE>ok</VALUE></PROPERTY></INSTANCE>'
$actual = ConvertFrom-SentinelKvpXml -Items @($other,$xmlData)
$good = Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $vmId -GuestData $actual
if ($good.result -ne 'EVIDENCE_MATCH' -or $good.trusted -ne $false -or $good.fingerprint -cne $fp) {
    throw 'Expected an evidence match with trust=false'
}
function Expect-Blocked([scriptblock]$Action) {
    try {
        & $Action | Out-Null
        throw 'Expected BLOCKED'
    } catch {
        if ([string]$_.Exception.Message -ceq 'Expected BLOCKED') { throw }
        if ([string]$_.Exception.Message -notmatch 'BLOCKED') { throw }
    }
}
Expect-Blocked { ConvertFrom-SentinelKvpXml -Items @($xmlData,$xmlData) }
Expect-Blocked { ConvertFrom-SentinelKvpXml -Items @($other) }
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId ([guid]::NewGuid().ToString()) -GuestData $serialized }
$wrong = [pscustomobject]@{ node=$entry.node; ip=$entry.ip; vmId=$entry.vmId; nonce=('b' * 64) }
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $wrong -ActualVMId $vmId -GuestData $serialized }
$tampered = $serialized.Replace('10.78.0.10','10.78.0.11')
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $vmId -GuestData $tampered }
$badFP = $serialized.Replace($fp, 'SHA256:incorrect')
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $vmId -GuestData $badFP }
Expect-Blocked { Get-SentinelHostKeyFingerprint -PublicKey 'ssh-rsa invalid' }

# The worker replica is a separate pinned disposable VM; no live VM is queried.
$w02Id = [guid]::NewGuid().ToString()
$w02 = [pscustomobject]@{ node='sentinel-e2e-w02'; ip='10.78.0.12'; vmId=$w02Id; nonce=('c' * 64) }
$w02Payload = [ordered]@{ schema=1; node=$w02.node; ip=$w02.ip; nonce=$w02.nonce; publicKey=$key; fingerprint=$fp } | ConvertTo-Json -Compress
$w02Match = Assert-SentinelKvpIdentity -ManifestEntry $w02 -ActualVMId $w02Id -GuestData $w02Payload
if ($w02Match.node -cne 'sentinel-e2e-w02' -or $w02Match.ip -cne '10.78.0.12' -or $w02Match.trusted) {
    throw 'Disposable guest KVP evidence did not remain untrusted and correctly bound'
}
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $w02 -ActualVMId ([guid]::NewGuid().ToString()) -GuestData $w02Payload }
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $w02 -ActualVMId $w02Id -GuestData ($w02Payload.Replace('10.78.0.12','10.78.0.11')) }
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $w02 -ActualVMId $w02Id -GuestData ($w02Payload.Replace(('c' * 64),('d' * 64))) }
Write-Host 'PASS: Hyper-V KVP evidence validation, VM ID, nonce, duplicates and host-key safety'
