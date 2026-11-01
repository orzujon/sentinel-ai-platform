#Requires -Version 5.1
# Pure validation functions for guest -> host KVP evidence. No VM or disk mutations.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-SentinelKvpXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Items)
    $matches = @()
    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item) -or $item.Length -gt 8192) { throw 'BLOCKED: empty or oversized KVP XML' }
        try { [xml]$doc = $item } catch { throw 'BLOCKED: invalid KVP XML' }
        $name = $doc.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE")
        $data = $doc.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE")
        if ($null -eq $name -or $null -eq $data) { throw 'BLOCKED: incomplete KVP name/data fields' }
        if ($name.InnerText -ceq 'Sentinel.SSHHostKey.Ed25519') {
            if ($data.InnerText.Length -gt 2048) { throw 'BLOCKED: KVP identity data too large' }
            $matches += $data.InnerText
        }
    }
    if ($matches.Count -ne 1) { throw 'BLOCKED: expected exactly one Sentinel guest KVP identity record' }
    return $matches[0]
}

function Get-SentinelHostKeyFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKey)
    if ($PublicKey -cnotmatch '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})$') { throw 'BLOCKED: invalid ED25519 public key encoding' }
    try { $wire = [Convert]::FromBase64String($Matches[1]) } catch { throw 'BLOCKED: malformed ED25519 host key' }
    if ($wire.Length -ne 51) { throw 'BLOCKED: ED25519 host key wire length mismatch' }
    $header = [byte[]](0,0,0,11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + [byte[]](0,0,0,32)
    for ($i=0; $i -lt $header.Length; $i++) {
        if ($wire[$i] -ne $header[$i]) { throw 'BLOCKED: ED25519 host key algorithm mismatch' }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($wire) } finally { $sha.Dispose() }
    return 'SHA256:' + [Convert]::ToBase64String($digest).TrimEnd('=')
}

function Assert-SentinelKvpIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ManifestEntry,
        [Parameter(Mandatory)][string]$ActualVMId,
        [Parameter(Mandatory)][string]$GuestData
    )
    $expected = @{
        'sentinel-l1-cp01'='10.78.0.10'
        'sentinel-l1-w01'='10.78.0.11'
    }
    $node = [string]$ManifestEntry.node
    if (-not $expected.ContainsKey($node) -or [string]$ManifestEntry.ip -cne $expected[$node]) {
        throw 'BLOCKED: unknown or unpinned guest network identity'
    }
    $manifestVM = [guid]::Empty
    $actualVM = [guid]::Empty
    if (-not [guid]::TryParse([string]$ManifestEntry.vmId,[ref]$manifestVM) -or
        -not [guid]::TryParse($ActualVMId,[ref]$actualVM) -or
        $manifestVM -ne $actualVM) { throw 'BLOCKED: Hyper-V VM ID does not match the independent provisioning manifest' }
    if ([string]$ManifestEntry.nonce -cnotmatch '^[0-9a-f]{64}$') {
        throw 'BLOCKED: missing or malformed provisioner nonce'
    }
    if ($GuestData.Length -gt 2048) { throw 'BLOCKED: oversized guest evidence' }
    try { $guest = $GuestData | ConvertFrom-Json -ErrorAction Stop } catch { throw 'BLOCKED: malformed guest identity JSON' }
    if ([int]$guest.schema -ne 1 -or
        [string]$guest.node -cne $node -or [string]$guest.ip -cne $expected[$node] -or
        [string]$guest.nonce -cne [string]$ManifestEntry.nonce) {
        throw 'BLOCKED: guest evidence does not match provisioner-supplied node/IP/nonce'
    }
    $fingerprint = Get-SentinelHostKeyFingerprint -PublicKey ([string]$guest.publicKey)
    if ([string]$guest.fingerprint -cne $fingerprint) { throw 'BLOCKED: inconsistent guest key fingerprint' }
    return [pscustomobject]@{
        result='EVIDENCE_MATCH'
        node=$node
        ip=$expected[$node]
        vmId=$manifestVM.ToString()
        fingerprint=$fingerprint
        publicKey=[string]$guest.publicKey
        # No trust is established by guest-published KVP evidence alone.
        trusted=$false
    }
}
Export-ModuleMember -Function ConvertFrom-SentinelKvpXml, Get-SentinelHostKeyFingerprint, Assert-SentinelKvpIdentity
