#Requires -Version 5.1
# Offline Stage 5.3.3: parse identity workflow and reject guest writes without approval.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$entrypoint = Join-Path $root 'tools\Invoke-SentinelWorkerReplicaKvpIdentity.ps1'
$moduleFile = Join-Path $root 'src\Sentinel.KvpEvidence.psm1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw ('Invalid disposable KVP identity runner: ' + (($errors | ForEach-Object Message) -join '; '))
}
$source = Get-Content -LiteralPath $entrypoint -Raw
$validator = Get-Content -LiteralPath $moduleFile -Raw

foreach ($required in @(
    '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9',
    '10.78.0.12',
    'sentinel-e2e-w02',
    'disposable-worker-replica-e2e',
    'PUBLISH_DISPOSABLE_SENTINEL_W02_HOST_PUBLIC_KEY',
    'diagnostic_known_hosts',
    'Get-VMIntegrationService',
    'Get-CimInstance',
    'Msvm_ComputerSystem',
    'Get-CimAssociatedInstance',
    'Msvm_KvpExchangeComponent',
    'GuestExchangeItems',
    'ConvertFrom-SentinelKvpXml',
    'Assert-SentinelKvpIdentity',
    'Get-SentinelHostKeyFingerprint',
    'ssh-keyscan.exe',
    'StrictHostKeyChecking=yes',
    'sudo -n python3 -',
    'EVIDENCE_ONLY',
    'trusted=false'
)) {
    if (-not $source.Contains($required)) {
        throw "KVP identity runner missing safety or verification contract: $required"
    }
}
foreach ($forbidden in @('Set-VM', 'Stop-VM', 'Remove-VM', 'Remove-VMSwitch', 'Set-VMIntegrationService', 'New-VM', 'ssh-keygen -R', 'accept-new', 'UserKnownHostsFile=NUL')) {
    if ($source -match ('(?m)^\s*' + [regex]::Escape($forbidden) + '\b')) {
        throw "Dangerous operation in identity-only tool: $forbidden"
    }
}
if (-not $validator.Contains("'sentinel-e2e-w02'='10.78.0.12'")) {
    throw 'Host-side validation is missing the exact disposable guest mapping'
}
try {
    & $entrypoint -Mode PUBLISH 2>&1 | Out-Null
    throw 'Expected blocked PUBLISH before any VM or network access'
} catch {
    if ($_.Exception.Message -eq 'Expected blocked PUBLISH before any VM or network access') { throw }
    if ($_.Exception.Message -notmatch 'BLOCKED: explicit disposable-only publication approval required') {
        throw "Publisher rejected incorrectly: $($_.Exception.Message)"
    }
}
Write-Host 'PASS: public-key KVP workflow has exact VM/nonce mapping and refuses unapproved guest publication'
