#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigRepo,
    [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')][string]$Environment = 'lab',
    [ValidateNotNullOrEmpty()][string]$Distribution = 'Ubuntu-26.04',
    [string]$TrustedKnownHosts = (Join-Path $HOME '.ssh\known_hosts'),
    [switch]$DiscoverBaseline,
    [switch]$PlanBaseline,
    [switch]$ApplyBaseline,
    [string]$ApprovalToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail before contacting any VM when options are ambiguous or approval is missing.
if ($PlanBaseline.IsPresent -and $ApplyBaseline.IsPresent) {
    throw 'BLOCKED: use either -PlanBaseline or -ApplyBaseline'
}
if ($ApplyBaseline.IsPresent) {
    if ($ApprovalToken -cne 'APPLY_SENTINEL_STAGE42_TO_SANDBOX') {
        throw 'BLOCKED: explicit sandbox apply approval is missing'
    }
} elseif ($ApprovalToken) {
    throw 'BLOCKED: approval token only applies to -ApplyBaseline'
}

if (-not (Test-Path -LiteralPath $ConfigRepo -PathType Container)) {
    throw 'BLOCKED: private configuration clone is missing'
}
if (-not (Test-Path -LiteralPath $TrustedKnownHosts -PathType Leaf)) {
    throw 'BLOCKED: existing SSH known_hosts trust file is missing'
}
$runner = Join-Path $PSScriptRoot 'run_readiness.py'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw 'BLOCKED: Stage 4 runner is unavailable'
}

# This only reads an existing private Git commit; it does not fetch or checkout.
$revision = (& git.exe -C $ConfigRepo rev-parse --verify 'origin/main^{commit}' 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $revision) {
    throw 'BLOCKED: private origin/main commit could not be resolved'
}
$revision = ([string]$revision).Trim()
if ($revision -cnotmatch '^[0-9a-fA-F]{40}$') {
    throw 'BLOCKED: expected a full immutable Git commit revision'
}

function Convert-ToWslPath {
    param([Parameter(Mandatory)][string]$PathOnWindows)
    # wsl.exe forwards Windows native command arguments through Linux parsing.
    # Bare backslashes can be consumed, e.g. C:\Folder\File -> C:FolderFile.
    # Resolve first, then supply forward slashes to wslpath to preserve the path.
    $absolute = (Resolve-Path -LiteralPath $PathOnWindows -ErrorAction Stop).ProviderPath
    if ($absolute -cnotmatch '^[A-Za-z]:\\') {
        throw 'BLOCKED: Stage 4 paths must be on a local Windows drive'
    }
    $portable = $absolute.Replace([char]92, [char]47)
    $converted = & wsl.exe -d $Distribution -- wslpath -a -u $portable
    if ($LASTEXITCODE -ne 0 -or -not $converted) {
        throw 'BLOCKED: unable to convert a trusted local path for Ubuntu WSL'
    }
    $result = ([string]$converted).Trim()
    if (-not $result.StartsWith('/')) {
        throw 'BLOCKED: WSL path resolution did not return an absolute path'
    }
    return $result
}

$configLinux = Convert-ToWslPath -PathOnWindows $ConfigRepo
$knownHostsLinux = Convert-ToWslPath -PathOnWindows $TrustedKnownHosts
$runnerLinux = Convert-ToWslPath -PathOnWindows $runner

Write-Host 'Sentinel: validating private config, trusted SSH records and guest readiness.'
if ($ApplyBaseline.IsPresent) {
    Write-Host 'APPROVED APPLY MODE: Stage 4.2 will change the sandbox guests.'
} else {
    Write-Host 'READ-ONLY MODE: no guest configuration will be changed.'
}

$wslArgs = @(
    '-d', $Distribution, '--', 'python3', $runnerLinux,
    '--config-repo', $configLinux,
    '--revision', $revision,
    '--environment', $Environment,
    '--trusted-known-hosts', $knownHostsLinux
)
if ($DiscoverBaseline.IsPresent) {
    $wslArgs += '--discover-baseline'
}
if ($PlanBaseline.IsPresent) {
    $wslArgs += '--plan-baseline'
}
if ($ApplyBaseline.IsPresent) {
    $wslArgs += @('--apply-baseline', '--approval-token', $ApprovalToken)
}
& wsl.exe @wslArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "BLOCKED: Stage 4.1 validation failed (exit $exitCode)"
}
if ($ApplyBaseline.IsPresent) {
    Write-Host 'PASS: Stage 4.2 approved apply returned successfully. Check recap for changes.'
} elseif ($PlanBaseline.IsPresent) {
    Write-Host 'PASS: Stage 4.2 read-only baseline plan complete.'
} else {
    Write-Host 'PASS: Sentinel readiness/discovery checks succeeded.'
}
