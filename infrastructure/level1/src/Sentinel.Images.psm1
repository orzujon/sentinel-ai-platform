Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stage 02 intentionally has no dependency on Hyper-V, Ansible, or VM state.
# This is a content-addressed image cache: we never overwrite a mismatching file.

function Assert-SentinelImageSpecification {
    param([Parameter(Mandatory)][pscustomobject]$Config)
    if (-not $Config.image) { throw 'Missing config.image.' }
    $sourceUrl = [string]$Config.image.sourceUrl
    $build = [string]$Config.image.buildId
    $name = [string]$Config.image.fileName
    $cache = [string]$Config.paths.imageCache
    if ($build -notmatch '^20[0-9]{6}$') { throw 'Image buildId must be YYYYMMDD.' }
    if ($name -cne 'ubuntu-26.04-server-cloudimg-amd64.img') { throw 'Unexpected image filename.' }
    $expectedUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-' + $build + '/' + $name
    if ($sourceUrl -cne $expectedUrl) { throw 'Source must be the pinned Canonical HTTPS image URL.' }
    if ($cache -notmatch '^[Cc]:\\Sentinel\\ImageCache(?:\\|$)') {
        throw 'Only C:\Sentinel\ImageCache is allowed for the download cache.'
    }
    if ([string]$Config.image.distribution -cne 'Ubuntu' -or [string]$Config.image.architecture -cne 'amd64') {
        throw 'Unsupported image distribution or architecture.'
    }
    return [pscustomobject]@{
        Url = $sourceUrl; Build = $build; Filename = $name
        CacheRoot = $cache
        Expected = [string]$Config.image.expectedSha256
    }
}

function Save-SentinelHttpsFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('cloud-images.ubuntu.com')][string]$AllowedHost = 'cloud-images.ubuntu.com'
    )
    # Redirects are followed only if they stay on the approved HTTPS host.
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(60)
    $response = $null
    $target = [Uri]$Uri
    $file = $null
    $stream = $null
    try {
        for ($i = 0; $i -lt 5; $i++) {
            if ($target.Scheme -cne 'https' -or $target.DnsSafeHost -cne $AllowedHost -or $target.Port -ne 443) {
                throw "Download redirected outside approved HTTPS host: $target"
            }
            $response = $client.GetAsync($target, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $code = [int]$response.StatusCode
            if ($code -in @(301,302,303,307,308)) {
                if (-not $response.Headers.Location) { throw 'Redirect has no Location header.' }
                $next = [Uri]::new($target, $response.Headers.Location)
                $response.Dispose(); $response = $null
                $target = $next
                continue
            }
            $response.EnsureSuccessStatusCode() | Out-Null
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $file = [System.IO.FileStream]::new($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] (1024 * 1024)
                [long]$written = 0
                $headerLength = $response.Content.Headers.ContentLength
                $total = if ($null -ne $headerLength) { [long]$headerLength } else { [long]0 }
                $last = -1
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $file.Write($buffer, 0, $read)
                    $written += $read
                    if ($total -gt 0) {
                        $percent = [int][math]::Floor(100 * ($written / $total))
                        if ($percent -ge ($last + 5) -or $percent -eq 100) {
                            Write-Progress -Activity 'Downloading approved Ubuntu cloud image' -Status "$percent%" -PercentComplete $percent
                            $last = $percent
                        }
                    }
                }
                if ($total -gt 0 -and $written -ne $total) { throw 'Download truncated (Content-Length mismatch).' }
            }
            finally {
                Write-Progress -Activity 'Downloading approved Ubuntu cloud image' -Completed
                if ($file) { $file.Dispose(); $file = $null }
                if ($stream) { $stream.Dispose() }
            }
            return $written
        }
        throw 'Too many redirects.'
    }
    finally {
        if ($response) { $response.Dispose() }
        $client.Dispose(); $handler.Dispose()
    }
}

function Invoke-SentinelImageStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateSet('discover','prepare','verify')][string]$Operation
    )
    New-Item -Path $RunDirectory -ItemType Directory -Force | Out-Null
    $eventsPath = Join-Path $RunDirectory 'events.jsonl'
    $reportPath = Join-Path $RunDirectory 'image.json'
    $start = [DateTime]::UtcNow
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $artifact = $null
    $candidateDigest = $null
    $result = 'BLOCKED'
    $reason = ''

    function Add-Event {
        param([string]$Type, [string]$Status, [string]$Detail)
        $evt = [ordered]@{
            utc = [DateTime]::UtcNow.ToString('o')
            stage = '20-image-cache'
            event = $Type
            level = $Status
            message = $Detail
        }
        ($evt | ConvertTo-Json -Compress -Depth 5) | Add-Content -LiteralPath $eventsPath -Encoding UTF8
        $checks.Add([pscustomobject]@{ Check = $Type; Status = $Status; Detail = $Detail })
    }

    try {
        $spec = Assert-SentinelImageSpecification -Config $Config
        Add-Event 'source-policy' 'PASS' 'Canonical HTTPS source, pinned date and allowlisted cache root confirmed.'
        $digest = $spec.Expected.ToLowerInvariant()

        if ($Operation -eq 'discover') {
            $base = $spec.Url.Substring(0, $spec.Url.LastIndexOf('/') + 1)
            $sums = Join-Path $RunDirectory 'SHA256SUMS'
            $signature = Join-Path $RunDirectory 'SHA256SUMS.gpg'
            if (Test-Path -LiteralPath $sums) { throw 'Run-directory collision for SHA256SUMS.' }
            [void](Save-SentinelHttpsFile -Uri ($base + 'SHA256SUMS') -Destination $sums)
            [void](Save-SentinelHttpsFile -Uri ($base + 'SHA256SUMS.gpg') -Destination $signature)
            $raw = Get-Content -LiteralPath $sums -Raw
            $pattern = '(?m)^(?<digest>[a-fA-F0-9]{64})[ \t]+\*?ubuntu-26\.04-server-cloudimg-amd64\.img\r?$'
            $matchesList = [regex]::Matches($raw, $pattern)
            if ($matchesList.Count -ne 1) { throw 'Expected exactly one matching image in Canonical checksum list.' }
            $candidateDigest = $matchesList[0].Groups['digest'].Value.ToLowerInvariant()
            Add-Event 'upstream-checksums' 'WARN' 'Downloaded upstream checksum list and signature; NOT yet signature-verified.'
            if ($digest -match '^[a-f0-9]{64}$' -and $digest -ne $candidateDigest) {
                throw 'Approved digest differs from listed upstream digest. No image download permitted.'
            }
            $result = 'NEEDS_APPROVAL'
            $reason = 'Verify SHA256SUMS.gpg with the trusted Ubuntu image signing key, then pin the approved digest in config/lab.json.'
        }
        else {
            if ($digest -notmatch '^[a-f0-9]{64}$') {
                throw 'No approved SHA256 pinned. Run image-discover, verify signature using trusted Canonical signing key, then set image.expectedSha256.'
            }
            $cacheDir = Join-Path $spec.CacheRoot ("ubuntu\26.04\" + $spec.Build)
            $artifact = Join-Path $cacheDir ($digest + '.img')
            $metadata = Join-Path $cacheDir ($digest + '.json')
            if (Test-Path -LiteralPath $artifact -PathType Leaf) {
                $actual = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $digest) { throw "Existing cached file checksum does not match. Quarantine manually, do not overwrite: $artifact" }
                Add-Event 'cache-verify' 'PASS' 'Cached artifact SHA256 matches approved digest; no download.'
                $result = 'READY'
                $reason = 'Verified cache HIT.'
            }
            elseif ($Operation -eq 'verify') {
                throw "Cache MISS: verified artifact is not present at $artifact"
            }
            else {
                $cacheRootDrive = [System.IO.Path]::GetPathRoot($spec.CacheRoot)
                $volume = [System.IO.DriveInfo]::new($cacheRootDrive)
                if (-not $volume.IsReady -or $volume.AvailableFreeSpace -lt 2GB) {
                    throw 'Insufficient free cache drive capacity: at least 2 GiB is required before download.'
                }
                [void](New-Item -ItemType Directory -Path $cacheDir -Force)
                $lockPath = Join-Path $cacheDir '.sentinel-image.lock'
                $lock = $null
                $partial = Join-Path $cacheDir ('.' + [guid]::NewGuid().ToString('N') + '.partial')
                try {
                    $lock = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    Add-Event 'download-start' 'PASS' 'Cache MISS; downloading from pinned Canonical HTTPS source.'
                    $length = Save-SentinelHttpsFile -Uri $spec.Url -Destination $partial
                    $downloadedDigest = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($downloadedDigest -ne $digest) { throw 'Downloaded image checksum mismatch. Untrusted partial download will be discarded.' }
                    Add-Event 'download-sha256' 'PASS' "Image checksum matched approved SHA256; $length bytes downloaded."
                    if (Test-Path -LiteralPath $artifact) { throw 'Cache destination appeared during download. No overwrite allowed.' }
                    [System.IO.File]::Move($partial, $artifact)
                    $info = [ordered]@{
                        schemaVersion = '1.0'
                        sourceUrl = $spec.Url
                        buildId = $spec.Build
                        sha256 = $digest
                        sizeBytes = $length
                        verifiedUtc = [DateTime]::UtcNow.ToString('o')
                        runId = (Split-Path $RunDirectory -Leaf)
                    }
                    ($info | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $metadata -Encoding UTF8
                    $result = 'READY'
                    $reason = 'Verified and published image in versioned, content-addressed cache.'
                }
                finally {
                    if ($lock) { $lock.Dispose(); Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
                    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
    catch {
        $reason = $_.Exception.Message
        $result = 'BLOCKED'
        Add-Event 'failure' 'BLOCK' $reason
    }
    finally {
        $end = [DateTime]::UtcNow
        $report = [ordered]@{
            schemaVersion = '1.0'
            stage = '20-image-cache'
            operation = $Operation
            runId = (Split-Path $RunDirectory -Leaf)
            startedUtc = $start.ToString('o')
            finishedUtc = $end.ToString('o')
            durationSeconds = [math]::Round(($end - $start).TotalSeconds,3)
            result = $result
            reason = $reason
            imageArtifact = if ($result -eq 'READY') { $artifact } else { $null }
            candidateSha256 = $candidateDigest
            hypervMutations = 0
            checks = @($checks.ToArray())
        }
        ($report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $reportPath -Encoding UTF8
        $finalEvent = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); stage = '20-image-cache'; event = 'stage-end'; level = $result; message = $reason }
        ($finalEvent | ConvertTo-Json -Compress) | Add-Content -LiteralPath $eventsPath -Encoding UTF8
    }
    return [pscustomobject]@{ Result = $result; Reason = $reason; Artifact = if ($result -eq 'READY') { $artifact } else { $null }; CandidateSha256 = $candidateDigest; Checks = @($checks.ToArray()); ReportPath = $reportPath }
}
Export-ModuleMember -Function Invoke-SentinelImageStage, Assert-SentinelImageSpecification
