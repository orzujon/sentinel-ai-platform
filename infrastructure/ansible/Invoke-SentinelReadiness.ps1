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
    [string]$ApprovalToken,
    [switch]$RebootValidate,
    [string]$RebootApprovalToken,
    [switch]$DiscoverKubernetes,
    [switch]$PlanKubernetesPackages,
    [switch]$ConfigureKubernetesRepo,
    [switch]$PlanKubernetesInstall,
    [switch]$InstallKubernetesPackages,
    [switch]$Reconcile,
    [switch]$NetworkTest,
    [string]$ReconcileApprovalToken,
    [switch]$PlanFlannel,
    [switch]$ApplyFlannel,
    [string]$FlannelApprovalToken,
    [string]$FlannelSha256,
    [switch]$PlanControlPlane,
    [switch]$InitControlPlane,
    [string]$ControlPlaneApprovalToken,
    [string]$InstallApprovalToken,
    [string]$RepositoryApprovalToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail before contacting any VM when options are ambiguous or approval is missing.
# Arithmetic preserves an integer when no mode or exactly one mode is selected.
# Avoid pipeline scalar-unwrapping under Set-StrictMode -Version Latest.
$selectedModeCount = [int]$PlanBaseline.IsPresent +
    [int]$ApplyBaseline.IsPresent +
    [int]$RebootValidate.IsPresent +
    [int]$DiscoverKubernetes.IsPresent +
    [int]$PlanKubernetesPackages.IsPresent +
    [int]$ConfigureKubernetesRepo.IsPresent +
    [int]$PlanKubernetesInstall.IsPresent +
    [int]$InstallKubernetesPackages.IsPresent +
    [int]$PlanControlPlane.IsPresent +
    [int]$InitControlPlane.IsPresent +
    [int]$PlanFlannel.IsPresent +
    [int]$ApplyFlannel.IsPresent +
    [int]$Reconcile.IsPresent
if ($selectedModeCount -gt 1) {
    throw 'BLOCKED: choose exactly one Stage 4.2 or 4.3 mode'
}
if ($NetworkTest.IsPresent -and (-not $Reconcile.IsPresent -or $ReconcileApprovalToken -cne 'DEPLOY_SENTINEL_LEVEL1_LAB')) {
    throw 'BLOCKED: -NetworkTest requires -Reconcile and the explicit lab deployment approval'
}
if ($Reconcile.IsPresent) {
    if ($ReconcileApprovalToken -and $ReconcileApprovalToken -cne 'DEPLOY_SENTINEL_LEVEL1_LAB') {
        throw 'BLOCKED: invalid Level 1 deployment approval'
    }
} elseif ($ReconcileApprovalToken) {
    throw 'BLOCKED: deployment approval only valid with -Reconcile'
}
if ($ApplyFlannel.IsPresent) {
    if ($FlannelApprovalToken -cne 'APPLY_SENTINEL_STAGE434_FLANNEL_02810') {
        throw 'BLOCKED: separate Flannel deployment approval is missing'
    }
    if ($FlannelSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'BLOCKED: exact reviewed Flannel SHA256 is required'
    }
} elseif ($FlannelApprovalToken -or $FlannelSha256) {
    throw 'BLOCKED: Flannel approval and checksum only valid with -ApplyFlannel'
}
if ($InitControlPlane.IsPresent) {
    if ($ControlPlaneApprovalToken -cne 'INITIALIZE_SENTINEL_STAGE433_CONTROL_PLANE') {
        throw 'BLOCKED: separate Stage 4.3.3 initialization approval missing'
    }
} elseif ($ControlPlaneApprovalToken) {
    throw 'BLOCKED: initialization token only valid with -InitControlPlane'
}
if ($InstallKubernetesPackages.IsPresent) {
    if ($InstallApprovalToken -cne 'INSTALL_SENTINEL_STAGE432_K8S_1372') {
        throw 'BLOCKED: separate Kubernetes package installation approval missing'
    }
} elseif ($InstallApprovalToken) {
    throw 'BLOCKED: installation token only valid with -InstallKubernetesPackages'
}
if ($ConfigureKubernetesRepo.IsPresent) {
    if ($RepositoryApprovalToken -cne 'CONFIGURE_SENTINEL_STAGE432_K8S_REPO') {
        throw 'BLOCKED: separate Stage 4.3.2 repository approval is missing'
    }
} elseif ($RepositoryApprovalToken) {
    throw 'BLOCKED: repository approval token only applies to -ConfigureKubernetesRepo'
}
if ($RebootValidate.IsPresent) {
    if ($RebootApprovalToken -cne 'REBOOT_SENTINEL_STAGE42_SANDBOX') {
        throw 'BLOCKED: explicit sandbox reboot approval is missing'
    }
} elseif ($RebootApprovalToken) {
    throw 'BLOCKED: reboot approval token only applies to -RebootValidate'
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
} elseif ($RebootValidate.IsPresent) {
    Write-Host 'APPROVED REBOOT MODE: Stage 4.2 will reboot both sandbox VMs sequentially.'
} elseif ($Reconcile.IsPresent -and $ReconcileApprovalToken) {
    Write-Host 'APPROVED DESIRED-STATE RECONCILIATION: only declared sandbox resources may change.'
} elseif ($ApplyFlannel.IsPresent) {
    Write-Host 'APPROVED FLANNEL APPLY: reviewed SHA256-pinned release will modify the control-plane cluster.'
} elseif ($InitControlPlane.IsPresent) {
    Write-Host 'APPROVED CONTROL-PLANE INIT: only the sandbox control-plane guest will be initialized.'
} elseif ($InstallKubernetesPackages.IsPresent) {
    Write-Host 'APPROVED PACKAGE INSTALL: pinned kubeadm, kubelet and kubectl will be installed and held on both sandbox guests.'
} elseif ($ConfigureKubernetesRepo.IsPresent) {
    Write-Host 'APPROVED REPOSITORY MODE: Stage 4.3.2 will add the signed Kubernetes APT source and refresh package indexes. Kubernetes packages will not be installed.'
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
if ($RebootValidate.IsPresent) {
    $wslArgs += @('--reboot-validate', '--reboot-approval-token', $RebootApprovalToken)
}
if ($DiscoverKubernetes.IsPresent) {
    $wslArgs += '--discover-kubernetes'
}
if ($PlanKubernetesPackages.IsPresent) {
    $wslArgs += '--plan-kubernetes-packages'
}
if ($Reconcile.IsPresent) {
    $wslArgs += '--reconcile'
    if ($NetworkTest.IsPresent) {
        $wslArgs += '--network-test'
    }
    if ($ReconcileApprovalToken) {
        $wslArgs += @('--reconcile-approval-token', $ReconcileApprovalToken)
    }
}
if ($ApplyFlannel.IsPresent) {
    $wslArgs += @('--apply-flannel', '--flannel-approval-token', $FlannelApprovalToken, '--flannel-sha256', $FlannelSha256)
}
if ($PlanFlannel.IsPresent) {
    $wslArgs += '--plan-flannel'
}
if ($PlanControlPlane.IsPresent) {
    $wslArgs += '--plan-control-plane'
}
if ($InitControlPlane.IsPresent) {
    $wslArgs += @('--init-control-plane', '--control-plane-approval-token', $ControlPlaneApprovalToken)
}
if ($PlanKubernetesInstall.IsPresent) {
    $wslArgs += '--plan-kubernetes-install'
}
if ($InstallKubernetesPackages.IsPresent) {
    $wslArgs += @('--install-kubernetes-packages', '--install-approval-token', $InstallApprovalToken)
}
if ($ConfigureKubernetesRepo.IsPresent) {
    $wslArgs += @('--configure-kubernetes-repo', '--repository-approval-token', $RepositoryApprovalToken)
}
$priorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & wsl.exe @wslArgs 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $priorPreference
}
if ($exitCode -ne 0) {
    throw "BLOCKED: Stage 4.1 validation failed (exit $exitCode)"
}
if ($ApplyBaseline.IsPresent) {
    Write-Host 'PASS: Stage 4.2 approved apply returned successfully. Check recap for changes.'
} elseif ($RebootValidate.IsPresent) {
    Write-Host 'PASS: Stage 4.2 reboot persistence verification completed on both sandbox guests.'
} elseif ($DiscoverKubernetes.IsPresent) {
    Write-Host 'PASS: Stage 4.3.1 Kubernetes discovery completed without modifying guests.'
} elseif ($Reconcile.IsPresent) {
    Write-Host 'PASS: Level 1 desired-state reconciliation finished.'
} elseif ($ApplyFlannel.IsPresent) {
    Write-Host 'PASS: Stage 4.3.4 pinned Flannel release applied and control plane Ready.'
} elseif ($PlanFlannel.IsPresent) {
    Write-Host 'PASS: Stage 4.3.4 release plan checked without Kubernetes changes.'
} elseif ($PlanControlPlane.IsPresent) {
    Write-Host 'PASS: Stage 4.3.3 kubeadm configuration validated; no cluster initialized.'
} elseif ($InitControlPlane.IsPresent) {
    Write-Host 'PASS: Stage 4.3.3 approved control plane initialization completed.'
} elseif ($PlanKubernetesInstall.IsPresent) {
    Write-Host 'PASS: Stage 4.3.2 read-only pinned package installation simulation passed.'
} elseif ($InstallKubernetesPackages.IsPresent) {
    Write-Host 'PASS: Stage 4.3.2 Kubernetes packages installed and held; cluster not initialized.'
} elseif ($PlanKubernetesPackages.IsPresent) {
    Write-Host 'PASS: Stage 4.3.2 read-only Kubernetes package-source plan complete.'
} elseif ($ConfigureKubernetesRepo.IsPresent) {
    Write-Host 'PASS: Stage 4.3.2 signed Kubernetes APT repository configured. Kubernetes not installed.'
} elseif ($PlanBaseline.IsPresent) {
    Write-Host 'PASS: Stage 4.2 read-only baseline plan complete.'
} else {
    Write-Host 'PASS: Sentinel readiness/discovery checks succeeded.'
}
