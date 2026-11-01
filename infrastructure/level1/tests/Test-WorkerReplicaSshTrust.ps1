#Requires -Version 5.1
# Offline test for exact, private, non-overwriting, KVP-bound SSH known_hosts.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path $PSScriptRoot '..'
$entrypoint = Join-Path $root 'tools\Invoke-SentinelWorkerReplicaSshTrust.ps1'
$kvpModuleFile = Join-Path $root 'src\Sentinel.KvpEvidence.psm1'
$moduleFile = Join-Path $root 'src\Sentinel.SshTrust.psm1'
foreach ($path in @($entrypoint,$moduleFile)) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ('BLOCKED: parser error in ' + $path + ': ' + (($parseErrors | ForEach-Object Message) -join '; '))
    }
}
$scriptText = Get-Content -LiteralPath $entrypoint -Raw
$moduleText = Get-Content -LiteralPath $moduleFile -Raw

# The approval must fail BEFORE Get-VM/CIM/SSH/network and cannot be read from
# the guest as a self-approval claim.
function Expect-Blocked([scriptblock]$Action) {
    try {
        & $Action | Out-Null
        throw 'Expected BLOCKED'
    } catch {
        if ($_.Exception.Message -eq 'Expected BLOCKED') { throw }
        if ($_.Exception.Message -notmatch 'BLOCKED') {
            throw ('Wrong error instead of fail closed: ' + $_.Exception.Message)
        }
    }
}
Expect-Blocked { & $entrypoint -Mode REGISTER }
Expect-Blocked { & $entrypoint -Mode REGISTER -Approval 'anything' }

foreach ($required in @(
    '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9',
    'sentinel-e2e-w02',
    'disposable-worker-replica-e2e',
    'REGISTER_DISPOSABLE_SENTINEL_W02_KVP_VERIFIED_SSH_HOST',
    '10.78.0.12',
    'Msvm_ComputerSystem',
    'Msvm_KvpExchangeComponent',
    'GuestExchangeItems',
    'Assert-SentinelKvpIdentity',
    'Get-SentinelTrustedHostLine',
    'Register-SentinelTrustedHostFile',
    'Get-SentinelTrustStoreState',
    'ssh-keyscan.exe',
    'trusted_known_hosts',
    'KVP',
    "'PLAN','REGISTER','ACCEPT'",
    'StrictHostKeyChecking=yes',
    'UpdateHostKeys=no',
    'IdentityAgent=none',
    'IdentitiesOnly=yes',
    'PasswordAuthentication=no',
    'PreferredAuthentications=publickey',
    'HostKeyAlgorithms=ssh-ed25519',
    'GlobalKnownHostsFile=/dev/null',
    'UserKnownHostsFile=$trustedFile',
    "'-F','none'",
    'SENTINEL_SSH_PINNED_AUTHENTICATION_PASS'
)) {
    if (-not $scriptText.Contains($required)) { throw "Missing trust contract: $required" }
}
foreach ($forbidden in @('Stop-VM','Remove-VM','New-VM','Remove-VMSwitch','Set-VM','ssh-keygen -R','StrictHostKeyChecking=accept-new','StrictHostKeyChecking=no','UserKnownHostsFile=NUL','diagnostic_known_hosts')) {
    if ($scriptText.Contains($forbidden)) {
        throw "BLOCKED: unexpected destructive or weak-trust command: $forbidden"
    }
}
foreach ($required in @(
    '[IO.FileMode]::CreateNew',
    '[Security.AccessControl.FileSecurity]::new()',
    'SetAccessRuleProtection($true,$false)',
    'AreAccessRulesProtected',
    'FileAttributes]::ReparsePoint',
    'WriteThrough',
    '[IO.File]::ReadAllBytes',
    'SENTINEL'
)) {
    if ($required -cne 'SENTINEL' -and -not $moduleText.Contains($required)) {
        throw "Missing protected atomic trust-store safety contract: $required"
    }
}
# Exact sequence used by the real Stage 5.3.4 entrypoint. In particular,
# a nested -Force re-import must never erase KVP exports from script scope.
Import-Module $kvpModuleFile -Force -ErrorAction Stop
Import-Module $moduleFile -Force -ErrorAction Stop
foreach ($function in @(
    'ConvertFrom-SentinelKvpXml',
    'Assert-SentinelKvpIdentity',
    'Get-SentinelHostKeyFingerprint',
    'Get-SentinelTrustedHostLine',
    'Get-SentinelTrustStoreState',
    'Register-SentinelTrustedHostFile'
)) {
    if (-not (Get-Command $function -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "BLOCKED: missing exported command after both module imports: $function"
    }
}
# Reload trust module as a separate operation: KVP functions must remain visible.
Import-Module $moduleFile -Force -ErrorAction Stop
if (-not (Get-Command ConvertFrom-SentinelKvpXml -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'BLOCKED: Stage 5.3.4 regression: trust module reload hid KVP XML parser'
}
Write-Host 'PASS: Stage 5.3.4 shared KVP parser remains callable after trust module imports'
$wire = [byte[]](0,0,0,11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') +
        [byte[]](0,0,0,32) + ([byte[]](18) * 32)
$key = 'ssh-ed25519 ' + [Convert]::ToBase64String($wire)
$sha = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = 'SHA256:' + [Convert]::ToBase64String($sha.ComputeHash($wire)).TrimEnd('=') }
finally { $sha.Dispose() }
$line = Get-SentinelTrustedHostLine -IPAddress '10.78.0.12' -PublicKey $key -Fingerprint $fingerprint
Expect-Blocked { Get-SentinelTrustedHostLine -IPAddress '10.78.0.11' -PublicKey $key -Fingerprint $fingerprint }
Expect-Blocked { Get-SentinelTrustedHostLine -IPAddress '10.78.0.12' -PublicKey $key -Fingerprint 'SHA256:wrong' }
Expect-Blocked { Get-SentinelTrustedHostLine -IPAddress '10.78.0.12' -PublicKey 'ssh-rsa invalid' -Fingerprint $fingerprint }

$folder = Join-Path $env:TEMP ("sentinel-ssh-trust-offline-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop)
$target = Join-Path $folder 'trusted_known_hosts'
try {
    if ((Get-SentinelTrustStoreState -Path $target -ExpectedLine $line) -ne 'ABSENT') {
        throw 'Expected no pre-existing trusted host entry'
    }
    $first = Register-SentinelTrustedHostFile -Path $target -ExpectedLine $line
    if ($first -cne 'REGISTERED') { throw 'Expected first protected CreateNew registration' }
    $second = Register-SentinelTrustedHostFile -Path $target -ExpectedLine $line
    if ($second -cne 'ALREADY_REGISTERED') { throw 'Registration must be idempotent' }
    if ((Get-SentinelTrustStoreState -Path $target -ExpectedLine $line) -ne 'MATCH') {
        throw 'Expected identical registered trust bytes and restrictive ACL'
    }
    $original = [IO.File]::ReadAllBytes($target)
    if (-not ([Text.Encoding]::ASCII.GetString($original) -ceq ($line + [char]10))) {
        throw 'Trust file must contain only one verified IP and SSH key line'
    }
    [IO.File]::WriteAllText($target,"10.78.0.12 ssh-ed25519 malicious" + [char]10,[Text.Encoding]::ASCII)
    Expect-Blocked { Get-SentinelTrustStoreState -Path $target -ExpectedLine $line }
    Expect-Blocked { Register-SentinelTrustedHostFile -Path $target -ExpectedLine $line }
    if ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($target)) -notmatch 'malicious') {
        throw 'Registrar overwrote a mismatched existing key unexpectedly'
    }
} finally {
    # Only CI-created temp fixtures, never any real known_hosts file.
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS: disposable KVP SSH trust registration and strict ACL, no overwrite, invalid identity, no approval guards'
