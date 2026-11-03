#Requires -Version 5.1
<#
.SYNOPSIS
Explicit operator-run steps for the separate fresh Kubernetes cluster.
.DESCRIPTION
No automatic shutdown, deletion, reset or replay. PLAN observes host only.
CREATE and TRUST require a Node. Subsequent stages require both KVP-pinned
identities, then reuse the existing Ansible playbooks through a scoped runner.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','BOOTSTRAP','CREATE','TRUST','READINESS','BASELINE','REPOSITORY','PACKAGES','INIT','CNI','JOIN','VERIFY','NETWORK-TEST')]
    [string]$Stage = 'PLAN',
    [ValidateSet('control-plane','worker')][string]$Node,
    [string]$ImagePath,
    [string]$ImageSHA256,
    [string]$WSLPrivateKey = '/home/orzu/.ssh/id_ed25519',
    [string]$FlannelSHA256,
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Check approval and arguments BEFORE any access to Hyper-V or WSL.
$Stage = $Stage.ToUpperInvariant()
$readOnly = @('PLAN','READINESS','VERIFY')
$expectedApproval = 'FRESH_'+$Stage.Replace('-','_')
if ($Stage -in @('CREATE','TRUST')) {
    if (-not $Node) { throw 'BLOCKED: exact new Node role required' }
    $expectedApproval += '_'+$Node.ToUpperInvariant().Replace('-','_')
} elseif ($Node) { throw 'BLOCKED: Node is only valid for CREATE or TRUST' }
if ($Stage -notin $readOnly -and $Approval -cne $expectedApproval) {
    throw "BLOCKED: this stage requires -Approval $expectedApproval"
}
if ($Stage -in $readOnly -and $Approval) { throw 'BLOCKED: read-only stage accepts no approval' }
if ($Stage -in @('CREATE','BOOTSTRAP') -and (-not $ImagePath -or $ImageSHA256 -cnotmatch '^[a-f0-9]{64}$')) {
    throw 'BLOCKED: CREATE requires exact reviewed Stage2 ImagePath and ImageSHA256'
}
if ($Stage -in @('CNI','BOOTSTRAP') -and $FlannelSHA256 -cnotmatch '^[a-f0-9]{64}$') {
    throw 'BLOCKED: CNI requires reviewed upstream Flannel v0.28.10 SHA256'
}
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.FreshCluster.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.WslPaths.psm1') -Force
if ($Stage -eq 'PLAN') {
    & (Join-Path $PSScriptRoot 'Get-SentinelFreshClusterPlan.ps1')
    Assert-SentinelFreshHost -Node control-plane -ForCreation
    Assert-SentinelFreshHost -Node worker -ForCreation
    Write-Host 'FRESH_HOST_PLAN_PASS: current capacity and observed host topology pass; image/controller/guest gates remain.'
    return
}
function Assert-FreshController {
    if ($WSLPrivateKey -cnotmatch '^/home/[a-z][a-z0-9_-]*/\.ssh/id_ed25519$') {
        throw 'BLOCKED: unsupported existing WSL key path'
    }
    $public = (Get-Content -LiteralPath (Join-Path $HOME '.ssh\id_ed25519.pub') -Raw -ErrorAction Stop).Trim() -split '\s+'
    $derived = @(& wsl.exe -d Ubuntu-26.04 --exec timeout 8s ssh-keygen -y -f $WSLPrivateKey)
    if ($LASTEXITCODE -ne 0 -or $derived.Count -ne 1) { throw 'BLOCKED: cannot derive WSL public login key' }
    $parts = $derived[0].Trim() -split '\s+'
    if ($public.Count -lt 2 -or $parts.Count -lt 2 -or $public[0] -cne 'ssh-ed25519' -or
        $public[0] -cne $parts[0] -or $public[1] -cne $parts[1]) {
        throw 'BLOCKED: WSL login key does not match the public key seeded by Windows'
    }
    & wsl.exe -d Ubuntu-26.04 --exec ansible-playbook --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: WSL Ansible unavailable' }
}
Assert-FreshController
if ($Stage -eq 'BOOTSTRAP') {
    # Both target plans must pass before creating either VM. This is a clean
    # build only; a later invocation refuses occupied names rather than replaying.
    $creator = Join-Path $PSScriptRoot 'New-SentinelFreshVM.ps1'
    foreach ($role in @('control-plane','worker')) {
        & $creator -Mode PLAN -Node $role -ImagePath $ImagePath -ImageSHA256 $ImageSHA256
    }
    $self = $PSCommandPath
    foreach ($role in @('control-plane','worker')) {
        $roleToken = $role.ToUpperInvariant().Replace('-','_')
        & $self -Stage CREATE -Node $role -ImagePath $ImagePath -ImageSHA256 $ImageSHA256 `
            -WSLPrivateKey $WSLPrivateKey -Approval ('FRESH_CREATE_'+$roleToken)
        $ready = $false
        $waitClock = [Diagnostics.Stopwatch]::StartNew()
        $lastWaitReason = ''
        for ($attempt=0; $attempt -lt 120; $attempt++) {
            try {
                & (Join-Path $PSScriptRoot 'Invoke-SentinelFreshTrust.ps1') -Mode VERIFY -Node $role
                $ready = $true
                break
            } catch {
                # Show the actual host verification failure, not a misleading
                # guest-progress claim. Do not dump guest payloads or credentials.
                $reason = ($_.Exception.Message -replace '[\r\n\x00-\x1f]+',' ').Trim()
                if ($reason.Length -gt 500) { $reason = $reason.Substring(0,500)+'...' }
                if ($reason -cne $lastWaitReason -or $attempt % 6 -eq 0) {
                    Write-Host ("FRESH_KVP_WAIT: node={0}; elapsed={1}s; attempt={2}/120; reason={3}" -f
                        $role,[int]$waitClock.Elapsed.TotalSeconds,($attempt+1),$reason)
                }
                $lastWaitReason = $reason
                Start-Sleep -Seconds 5
            }
        }
        $waitClock.Stop()
        if (-not $ready) { throw "BLOCKED: KVP not verified for $role. Last check: $lastWaitReason. Preserve partial build and inspect console; do not rerun BOOTSTRAP." }
        & $self -Stage TRUST -Node $role -WSLPrivateKey $WSLPrivateKey -Approval ('FRESH_TRUST_'+$roleToken)
    }
    foreach ($next in @('READINESS','BASELINE','REPOSITORY','PACKAGES','INIT','CNI','JOIN','VERIFY','NETWORK-TEST')) {
        $argsForStage = @{Stage=$next; WSLPrivateKey=$WSLPrivateKey}
        if ($next -notin $readOnly) { $argsForStage.Approval = 'FRESH_'+$next.Replace('-','_') }
        if ($next -eq 'CNI') { $argsForStage.FlannelSHA256 = $FlannelSHA256 }
        & $self @argsForStage
    }
    Write-Host 'FRESH_BOOTSTRAP_E2E_PASS: both fresh nodes, KVP, pinned SSH, packages, Kubernetes and active network checks passed'
    return
}
if ($Stage -eq 'CREATE') {
    & (Join-Path $PSScriptRoot 'New-SentinelFreshVM.ps1') -Mode CREATE -Node $Node `
        -ImagePath $ImagePath -ImageSHA256 $ImageSHA256 -Approval CREATE_SENTINEL_FRESH_CLUSTER_NODE
    return
}
$trust = Join-Path $PSScriptRoot 'Invoke-SentinelFreshTrust.ps1'
if ($Stage -eq 'TRUST') {
    & $trust -Mode VERIFY -Node $Node
    & $trust -Mode REGISTER -Node $Node -Approval REGISTER_KVP_VERIFIED_SENTINEL_FRESH_HOST_KEY
    & $trust -Mode ACCEPT -Node $Node
    & $trust -Mode ANSIBLE -Node $Node -WSLPrivateKey $WSLPrivateKey
    return
}
# Re-read KVP and NIC/UUID/disk bindings for BOTH nodes before any guest stage.
$identities = @()
foreach ($role in @('control-plane','worker')) {
    $identities += & $trust -Mode EVIDENCE -Node $role
}
if ($identities.Count -ne 2 -or $identities[0].vmId -eq $identities[1].vmId -or
    $identities[0].fingerprint -ceq $identities[1].fingerprint) {
    throw 'BLOCKED: two independent guest identities required'
}
$runner = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\ansible\fresh_cluster.py'))
$arguments = @('-d','Ubuntu-26.04','--exec','python3', (ConvertTo-SentinelWslMountPath $runner),
    '--stage',$Stage.ToLowerInvariant(),'--key',$WSLPrivateKey)
if ($Stage -notin $readOnly) { $arguments += @('--approval',$Approval) }
if ($Stage -eq 'CNI') { $arguments += @('--flannel-sha256',$FlannelSHA256) }
& wsl.exe @arguments
if ($LASTEXITCODE -ne 0) { throw "BLOCKED: fresh stage $Stage failed; no automatic retry, rollback or deletion" }
