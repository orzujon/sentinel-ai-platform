#Requires -Version 5.1
# Pure offline artifact resolver tests. All files live under one unique temp root.
# Never reads real C:\Sentinel cache, runs Hyper-V, opens WSL or downloads files.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'src\Sentinel.FreshArtifacts.psm1'
$runnerPath = Join-Path $root 'tools\Invoke-SentinelFreshCluster.ps1'
foreach ($file in @($modulePath,$runnerPath)) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ("BLOCKED: parser errors in {0}: {1}" -f $file,($errors | Out-String)) }
}
Import-Module $modulePath -Force
function Expect-Blocked([scriptblock]$Action) {
    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'BLOCKED') { throw }
        return
    }
    throw 'Expected BLOCKED in an offline artifact test'
}
# Ensure the committed profile cannot silently turn candidate evidence into approval.
$committed = Get-SentinelFreshArtifactSelection
if ($committed.Approved -or $committed.ReviewStatus -cne 'pending-review') {
    throw 'BLOCKED: expected pending-review repository profile; review/promotion needs a separate commit and test update'
}
$runnerSource = Get-Content -LiteralPath $runnerPath -Raw -Encoding UTF8
foreach ($required in @('ARTIFACTS','Get-SentinelFreshArtifactSelection',
    '-Profile $Profile','-RequireApproval:$needsApproval',
    '$artifacts.ImagePath','$artifacts.ImageSHA256','$artifacts.FlannelSHA256')) {
    if (-not $runnerSource.Contains($required)) { throw "BLOCKED: missing profile integration $required" }
}
foreach ($forbidden in @('[string]$ImagePath,','[string]$ImageSHA256,','[string]$FlannelSHA256,')) {
    if ($runnerSource.Contains($forbidden)) { throw "BLOCKED: public entrypoint still accepts unreviewed artifact override: $forbidden" }
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sentinel-fresh-artifact-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
try {
    $cache = Join-Path $fixtureRoot 'cache'
    $lockPath = Join-Path $fixtureRoot 'fresh.lock.json'
    $bytes = [Text.Encoding]::UTF8.GetBytes('offline signed-image-cache test fixture -- no VM')
    $sha = (New-Object Security.Cryptography.SHA256Managed).ComputeHash($bytes)
    $digest = [BitConverter]::ToString($sha).Replace('-','').ToLowerInvariant()
    $build = '20261016'
    $sourceUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-'+$build+'/ubuntu-26.04-server-cloudimg-amd64.img'
    $folder = Join-Path (Join-Path $cache 'ubuntu\26.04') $build
    [void][IO.Directory]::CreateDirectory($folder)
    $imagePath = Join-Path $folder ($digest+'.img')
    $metaPath = Join-Path $folder ($digest+'.json')
    [IO.File]::WriteAllBytes($imagePath,$bytes)
    $metadata = [ordered]@{buildId=$build;sha256=$digest;sourceUrl=$sourceUrl;sizeBytes=$bytes.Length}
    $lock = [ordered]@{
        schemaVersion=1
        profile='sentinel-fresh-cluster-v1'
        review=[ordered]@{status='pending-review';approvedBy=$null;approvedAtUtc=$null;approvalReference=$null}
        image=[ordered]@{imageRef='ubuntu-26.04-'+$build;buildId=$build;sourceUrl=$sourceUrl;sha256=$digest}
        flannel=[ordered]@{version='v0.28.10';sourceUrl='https://github.com/flannel-io/flannel/releases/download/v0.28.10/kube-flannel.yml';sha256=('a'*64)}
    }
    function Save-Lock {
        [IO.File]::WriteAllText($lockPath,($lock | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    }
    function Save-Metadata {
        [IO.File]::WriteAllText($metaPath,($metadata | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    }
    Save-Lock
    Save-Metadata
    $argsForTest = @{LockPath=$lockPath;CacheRoot=$cache;Profile='sentinel-fresh-cluster-v1';VerifyImageCache=$true}
    $candidate = Get-SentinelFreshArtifactSelection @argsForTest
    if ($candidate.Approved -or -not $candidate.ImageCacheVerified -or
        $candidate.ImageSHA256 -cne $digest -or $candidate.ImagePath -cne $imagePath -or
        $candidate.FlannelSHA256 -cne ('a'*64) -or $candidate.LockSHA256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'BLOCKED: verified offline candidate resolution failed'
    }
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest -RequireApproval }
    $lock.review.status='approved'
    Save-Lock
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest -RequireApproval }
    $lock.review.approvedBy='test-reviewer'
    $lock.review.approvedAtUtc='2026-11-03T12:00:00Z'
    $lock.review.approvalReference='https://github.com/orzujon/sentinel-ai-platform/pull/99'
    Save-Lock
    $approved = Get-SentinelFreshArtifactSelection @argsForTest -RequireApproval
    if (-not $approved.Approved -or $approved.LockSHA256 -ceq $candidate.LockSHA256) {
        throw 'BLOCKED: independently labelled approval fixture did not resolve or change the lock digest'
    }
    $lock.profile='sentinel-l1-sandbox'
    Save-Lock
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    $lock.profile='sentinel-fresh-cluster-v1'
    $lock.image.sourceUrl='https://example.com/image.img'
    Save-Lock
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    $lock.image.sourceUrl=$sourceUrl
    $lock.flannel.sha256='latest'
    Save-Lock
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    $lock.flannel.sha256='a'*64
    Save-Lock
    $metadata.sourceUrl='https://example.com/other.img'
    Save-Metadata
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    $metadata.sourceUrl=$sourceUrl
    Save-Metadata
    [IO.File]::WriteAllBytes($imagePath,[Text.Encoding]::ASCII.GetBytes('tampered'))
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    [IO.File]::WriteAllBytes($imagePath,$bytes)
    [IO.File]::Delete($metaPath)
    Expect-Blocked { Get-SentinelFreshArtifactSelection @argsForTest }
    Save-Metadata
    $good = Get-SentinelFreshArtifactSelection @argsForTest -RequireApproval
    if (-not $good.Approved) { throw 'BLOCKED: final fixture recovery failed' }
    Write-Host 'PASS: offline profile selection, lock digest, pending approval block, provenance/cache checks, tamper and invalid-source rejection'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}
