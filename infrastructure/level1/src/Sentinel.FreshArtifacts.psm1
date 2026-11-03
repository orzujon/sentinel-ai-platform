#Requires -Version 5.1
# Offline profile resolver. A digest match is NOT publisher signature verification.
# The reviewed profile lock is never inferred from a downloaded file or a live VM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SentinelFreshFields {
    param([object]$Object,[string[]]$Expected,[string]$Context)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) {
        throw "BLOCKED: malformed $Context object"
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or (@(Compare-Object $actual $wanted).Count -ne 0)) {
        throw "BLOCKED: unexpected $Context schema fields"
    }
}

function Get-SentinelFreshArtifactSelection {
    [CmdletBinding()]
    param(
        [ValidateSet('sentinel-fresh-cluster-v1')][string]$Profile = 'sentinel-fresh-cluster-v1',
        [string]$LockPath = (Join-Path $PSScriptRoot '..\config\fresh-artifacts.lock.json'),
        [string]$CacheRoot = 'C:\Sentinel\ImageCache',
        [switch]$RequireApproval,
        [switch]$VerifyImageCache
    )
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw 'BLOCKED: approved-profile artifact lock missing'
    }
    $lockItem = Get-Item -LiteralPath $LockPath -Force -ErrorAction Stop
    if ($lockItem.Length -gt 8192 -or ($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCKED: artifact lock is oversized or a reparse point'
    }
    $raw = [IO.File]::ReadAllBytes($lockItem.FullName)
    $lockDigest = [BitConverter]::ToString(
        ([Security.Cryptography.SHA256]::Create()).ComputeHash($raw)
    ).Replace('-','').ToLowerInvariant()
    try {
        $lock = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'BLOCKED: invalid artifact profile JSON'
    }
    Assert-SentinelFreshFields $lock @('schemaVersion','profile','review','image','flannel') 'profile lock'
    Assert-SentinelFreshFields $lock.review @('status','approvedBy','approvedAtUtc','approvalReference') 'approval'
    Assert-SentinelFreshFields $lock.image @('imageRef','buildId','sourceUrl','sha256') 'image'
    Assert-SentinelFreshFields $lock.flannel @('version','sourceUrl','sha256') 'Flannel'
    if ($lock.schemaVersion -isnot [int] -or [int]$lock.schemaVersion -ne 1 -or
        [string]$lock.profile -cne $Profile) {
        throw 'BLOCKED: unsupported profile version or mismatched environment'
    }
    if ([string]$lock.image.imageRef -cne ('ubuntu-26.04-' + [string]$lock.image.buildId) -or
        [string]$lock.image.buildId -cnotmatch '^20[0-9]{6}$' -or
        [string]$lock.image.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$lock.image.sourceUrl -cne (
            'https://cloud-images.ubuntu.com/releases/26.04/release-' +
            [string]$lock.image.buildId + '/ubuntu-26.04-server-cloudimg-amd64.img'
        )) {
        throw 'BLOCKED: image profile source/build/SHA256 policy mismatch'
    }
    if ([string]$lock.flannel.version -cne 'v0.28.10' -or
        [string]$lock.flannel.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$lock.flannel.sourceUrl -cne (
            'https://github.com/flannel-io/flannel/releases/download/' +
            [string]$lock.flannel.version + '/kube-flannel.yml'
        )) {
        throw 'BLOCKED: Flannel profile source/version/SHA256 policy mismatch'
    }
    $approved = $false
    if ([string]$lock.review.status -ceq 'approved') {
        if ([string]$lock.review.approvedBy -cnotmatch '^[a-zA-Z0-9._-]{3,64}$' -or
            [string]$lock.review.approvedAtUtc -cnotmatch '^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$' -or
            [string]$lock.review.approvalReference -cnotmatch '^https://github[.]com/orzujon/sentinel-ai-platform/pull/[1-9][0-9]*$') {
            throw 'BLOCKED: approved profile has no review attribution'
        }
        $approved = $true
    } elseif ([string]$lock.review.status -ceq 'pending-review') {
        if ($null -ne $lock.review.approvedBy -or $null -ne $lock.review.approvedAtUtc -or
            $null -ne $lock.review.approvalReference) {
            throw 'BLOCKED: pending profile must not carry inconsistent approval'
        }
    } else {
        throw 'BLOCKED: unknown artifact approval state'
    }
    if ($RequireApproval -and -not $approved) {
        throw 'BLOCKED: artifact profile is pending independent review; no deployment is permitted'
    }
    # Path is derived from pinned build and checksum: never read a path supplied by the lock.
    if ([IO.Path]::GetFullPath($CacheRoot).TrimEnd('\') -cne 'C:\Sentinel\ImageCache' -and
        -not $PSBoundParameters.ContainsKey('CacheRoot')) {
        throw 'BLOCKED: unexpected Stage2 cache root'
    }
    $buildFolder = Join-Path (Join-Path (Join-Path $CacheRoot 'ubuntu') '26.04') ([string]$lock.image.buildId)
    $image = Join-Path $buildFolder ([string]$lock.image.sha256 + '.img')
    if ($VerifyImageCache) {
        $candidateDirs = @($CacheRoot,(Join-Path $CacheRoot 'ubuntu'),
            (Join-Path $CacheRoot 'ubuntu\26.04'),$buildFolder)
        foreach ($dir in $candidateDirs) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                throw 'BLOCKED: pinned Stage2 image cache directory missing'
            }
            if (((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'BLOCKED: symlinked image cache directory'
            }
        }
        $sidecar = [IO.Path]::ChangeExtension($image,'.json')
        foreach ($file in @($image,$sidecar)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'BLOCKED: missing or symlinked pinned image/Stage2 metadata'
            }
        }
        $actual = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne [string]$lock.image.sha256) {
            throw 'BLOCKED: approved image cache bytes differ from pinned digest'
        }
        $metaFile = Get-Item -LiteralPath $sidecar
        if ($metaFile.Length -gt 8192) { throw 'BLOCKED: oversized image metadata sidecar' }
        try {
            $meta = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw 'BLOCKED: invalid image metadata sidecar'
        }
        if ([string]$meta.buildId -cne [string]$lock.image.buildId -or
            [string]$meta.sha256 -cne [string]$lock.image.sha256 -or
            [string]$meta.sourceUrl -cne [string]$lock.image.sourceUrl -or
            [long]$meta.sizeBytes -ne (Get-Item -LiteralPath $image).Length) {
            throw 'BLOCKED: image metadata does not match reviewed profile or file'
        }
    }
    return [pscustomobject]@{
        Profile = $Profile
        LockSHA256 = $lockDigest
        ReviewStatus = [string]$lock.review.status
        Approved = $approved
        ImageRef = [string]$lock.image.imageRef
        ImagePath = $image
        ImageSHA256 = [string]$lock.image.sha256
        ImageSourceURL = [string]$lock.image.sourceUrl
        FlannelVersion = [string]$lock.flannel.version
        FlannelSHA256 = [string]$lock.flannel.sha256
        FlannelSourceURL = [string]$lock.flannel.sourceUrl
        ImageCacheVerified = [bool]$VerifyImageCache
    }
}
Export-ModuleMember -Function Get-SentinelFreshArtifactSelection
