#Requires -Version 5.1
# Offline: synthetic public key and temporary trust files only. No VM/SSH calls.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.SshTrust.psm1') -Force
function Expect-Blocked([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch 'BLOCKED') { throw }; return }
    throw 'Expected BLOCKED'
}
$wire=[byte[]](0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+[byte[]](0,0,0,32)+[byte[]](1..32)
$key='ssh-ed25519 '+[Convert]::ToBase64String($wire)
$fp=Get-SentinelHostKeyFingerprint -PublicKey $key
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sentinel-fresh-trust-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    foreach ($ip in @('10.78.0.30','10.78.0.31')) {
        Expect-Blocked { Get-SentinelTrustedHostLine -IPAddress $ip -PublicKey $key -Fingerprint $fp }
        $line=Get-SentinelTrustedHostLine -FreshCluster -IPAddress $ip -PublicKey $key -Fingerprint $fp
        $target=Join-Path $testRoot ($ip+'.known_hosts')
        if ((Get-SentinelTrustStoreState -FreshCluster -Path $target -ExpectedLine $line) -ne 'ABSENT') { throw 'Expected absent' }
        Expect-Blocked { Register-SentinelTrustedHostFile -Path $target -ExpectedLine $line }
        if (Test-Path -LiteralPath $target) { throw 'Default scope wrote fresh trust' }
        if ((Register-SentinelTrustedHostFile -FreshCluster -Path $target -ExpectedLine $line) -ne 'REGISTERED') { throw 'Expected registration' }
        if ((Register-SentinelTrustedHostFile -FreshCluster -Path $target -ExpectedLine $line) -ne 'ALREADY_REGISTERED') { throw 'Expected idempotent registration' }
        if ((Get-SentinelTrustStoreState -FreshCluster -Path $target -ExpectedLine $line) -ne 'MATCH') { throw 'Expected match' }
        Expect-Blocked { Get-SentinelTrustStoreState -Path $target -ExpectedLine $line }
        [IO.File]::AppendAllText($target,'unexpected')
        Expect-Blocked { Get-SentinelTrustStoreState -FreshCluster -Path $target -ExpectedLine $line }
    }
    foreach ($ip in @('10.78.0.10','10.78.0.11','10.78.0.12','10.78.0.20','10.78.0.32')) {
        Expect-Blocked { Get-SentinelTrustedHostLine -FreshCluster -IPAddress $ip -PublicKey $key -Fingerprint $fp }
    }
    $legacy=Get-SentinelTrustedHostLine -IPAddress '10.78.0.20' -PublicKey $key -Fingerprint $fp
    Expect-Blocked { Register-SentinelTrustedHostFile -FreshCluster -Path (Join-Path $testRoot 'old') -ExpectedLine $legacy }
    $source=Get-Content (Join-Path $PSScriptRoot '..\tools\Invoke-SentinelFreshTrust.ps1') -Raw
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($cmd in $ast.FindAll({param($a) $a -is [Management.Automation.Language.CommandAst]},$true)) {
        if ($cmd.GetCommandName() -in @('Get-SentinelTrustedHostLine','Get-SentinelTrustStoreState','Register-SentinelTrustedHostFile')) {
            if (@($cmd.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'FreshCluster' }).Count -ne 1) {
                throw 'Fresh entrypoint failed to forward scope to shared trust helper'
            }
        }
    }
} finally {
    # Only exact temporary files created by this fixture; no recursive deletion.
    foreach ($ip in @('10.78.0.30','10.78.0.31')) {
        $target=Join-Path $testRoot ($ip+'.known_hosts')
        if ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
    }
    [IO.Directory]::Delete($testRoot)
}
Write-Host 'PASS: fresh trust registration round-trip, scope isolation, changed-file rejection and caller forwarding'
