#Requires -Version 5.1
<#
.SYNOPSIS
PLAN or remove the exact disposable fresh-cluster Hyper-V pair for clean rebuild.
.DESCRIPTION
Requires independently observed UUIDs for BOTH nodes. No target enumeration by
prefix or wildcard. PLAN is read-only. REMOVE requires explicit scoped approval,
re-checks both exact VM identities, storage/layout and exclusive ownership,
gracefully stops worker then control plane, unregisters exactly those two VMs,
and removes only their individually verified provisioning folders.
Never changes vSwitches, the Stage2 image cache or any other VM.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','REMOVE')][string]$Mode = 'PLAN',
    [Parameter(Mandatory)][guid]$ExpectedControlPlaneVMId,
    [Parameter(Mandatory)][guid]$ExpectedWorkerVMId,
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedApproval = 'REMOVE_EXACT_SENTINEL_FRESH_PAIR_FOR_REBUILD'
if ($Mode -eq 'REMOVE' -and $Approval -cne $expectedApproval) {
    throw "BLOCKED: REMOVE requires -Approval $expectedApproval"
}
if ($Mode -eq 'PLAN' -and $Approval) { throw 'BLOCKED: PLAN accepts no mutation approval' }
if ($ExpectedControlPlaneVMId -eq [guid]::Empty -or $ExpectedWorkerVMId -eq [guid]::Empty -or
    $ExpectedControlPlaneVMId -eq $ExpectedWorkerVMId) {
    throw 'BLOCKED: two different, non-empty exact Hyper-V UUIDs required'
}
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.HyperVDisposableLayout.psm1') -Force
$storageRoot = 'C:\Sentinel\FreshCluster\VMs'
$roles = @(
    [pscustomobject]@{Name='sentinel-fresh-cp01';Role='control-plane';Id=$ExpectedControlPlaneVMId;IP='10.78.0.30';Suffix='30'},
    [pscustomobject]@{Name='sentinel-fresh-w01';Role='worker';Id=$ExpectedWorkerVMId;IP='10.78.0.31';Suffix='31'}
)
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "BLOCKED: reparse point in owned target path: $Path"
    }
}
function Test-Under([string]$Candidate,[string]$Parent) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $path = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return ($path.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or
        $path.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase))
}
function Assert-ExactTarget([object]$Spec,[array]$AllVMs) {
    $name = $Spec.Name
    $id = [guid]$Spec.Id
    $folder = Join-Path $storageRoot $name
    $diskPath = Join-Path $folder 'os.vhdx'
    $seedPath = Join-Path $folder 'seed.iso'
    $manifestPath = Join-Path $folder 'provisioning.json'
    $matches = @($AllVMs | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1 -or $matches[0].Id -ne $id) {
        throw "BLOCKED: exact name/VM UUID not found: $name"
    }
    $vm = $matches[0]
    if ($vm.State -notin @('Running','Off')) {
        throw "BLOCKED: unexpected state for $name"
    }
    foreach ($path in @('C:\Sentinel','C:\Sentinel\FreshCluster',$storageRoot,
            $folder,$manifestPath,$diskPath,$seedPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "BLOCKED: expected owned storage missing: $path"
        }
        Assert-NoReparse $path
    }
    if (-not ((Get-Item -LiteralPath $folder).PSIsContainer) -or
        -not ([IO.Directory]::GetAccessControl($folder)).AreAccessRulesProtected) {
        throw "BLOCKED: fresh provisioning folder ACL or directory type mismatch: $name"
    }
    $manifestFile = Get-Item -LiteralPath $manifestPath -Force
    if ($manifestFile.Length -gt 8192 -or $manifestFile.PSIsContainer) {
        throw "BLOCKED: invalid provisioning manifest for $name"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mgmt = '02AA780001' + $Spec.Suffix
    $private = '02AA780000' + $Spec.Suffix
    if ([string]$manifest.purpose -cne 'sentinel-fresh-cluster-v1' -or
        [int]$manifest.schema -ne 3 -or [string]$manifest.node -cne $name -or
        [string]$manifest.privateIP -cne $Spec.IP -or
        [string]$manifest.managementMAC -cne $mgmt -or
        [string]$manifest.privateMAC -cne $private -or
        [string]$manifest.vmId -ine [string]$id -or
        [string]$manifest.nonce -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$manifest.sourceImageSHA256 -cnotmatch '^[a-f0-9]{64}$' -or
        $manifest.kubernetesInstall -ne $false) {
        throw "BLOCKED: manifest does not bind exact fresh VM identity: $name"
    }
    if (-not (Test-Under ([string]$vm.Path) $folder)) {
        throw "BLOCKED: Hyper-V configuration outside owned folder: $name"
    }
    # Require exact fixed top-level files and exact GUID-checked Hyper-V config.
    $nested = Join-Path $folder $name
    $topAllowed = @('os.vhdx','seed.iso','user-data','meta-data',
        'network-config','provisioning.json','provisioning-nonce',
        'diagnostic_known_hosts','trusted_known_hosts','ansible-inventory.ini',
        'Virtual Machines','Snapshots','Smart Paging','Virtual Hard Disks')
    if (Test-Path -LiteralPath $nested) {
        Assert-NoReparse $nested
        if (-not (Test-Path -LiteralPath $nested -PathType Container) -or
            -not (Test-Under ([string]$vm.Path) $nested)) {
            throw "BLOCKED: nested VM configuration is not Hyper-V owned: $name"
        }
        $topAllowed += $name
        $nestedAllowed = @('Virtual Machines','Snapshots','Smart Paging','Virtual Hard Disks')
        foreach ($entry in @(Get-ChildItem -LiteralPath $nested -Force -ErrorAction Stop)) {
            if ($entry.Name -cnotin $nestedAllowed -or -not $entry.PSIsContainer) {
                throw "BLOCKED: unexpected nested Hyper-V entry: $($entry.FullName)"
            }
        }
        $configDir = Join-Path $nested 'Virtual Machines'
        if ((Assert-SentinelHyperVConfigLayout -ConfigDirectory $configDir -ExpectedVMId $id) -cne 'VERIFIED') {
            throw 'BLOCKED: VM UUID layout unverified'
        }
        foreach ($empty in @('Snapshots','Smart Paging','Virtual Hard Disks')) {
            $p = Join-Path $nested $empty
            if (Test-Path -LiteralPath $p) {
                Assert-NoReparse $p
                if (-not (Test-Path -LiteralPath $p -PathType Container) -or
                    @(Get-ChildItem -LiteralPath $p -Force).Count -ne 0) {
                    throw "BLOCKED: unexpected nested Hyper-V files: $p"
                }
            }
        }
    } else {
        $configDir = Join-Path $folder 'Virtual Machines'
        if ((Assert-SentinelHyperVConfigLayout -ConfigDirectory $configDir -ExpectedVMId $id) -cne 'VERIFIED') {
            throw 'BLOCKED: VM UUID layout unverified'
        }
        foreach ($empty in @('Snapshots','Smart Paging','Virtual Hard Disks')) {
            $p = Join-Path $folder $empty
            if (Test-Path -LiteralPath $p) {
                Assert-NoReparse $p
                if (-not (Test-Path -LiteralPath $p -PathType Container) -or
                    @(Get-ChildItem -LiteralPath $p -Force).Count -ne 0) {
                    throw "BLOCKED: unexpected Hyper-V files: $p"
                }
            }
        }
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)) {
        if ($entry.Name -cnotin $topAllowed) {
            throw "BLOCKED: unknown file in cleanup target: $($entry.FullName)"
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCKED: linked file under cleanup target: $($item.FullName)"
        }
    }
    if (@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.avhdx').Count -ne 0) {
        throw "BLOCKED: checkpoints or differencing disks present for $name"
    }
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -ne 1 -or
        -not [string]::Equals([string]$drives[0].Path,$diskPath,[StringComparison]::OrdinalIgnoreCase)) {
        throw "BLOCKED: unexpected VM OS disk for $name"
    }
    $vhd = Get-VHD -Path $diskPath -ErrorAction Stop
    if ([string]$vhd.VhdType -notin @('Dynamic','Fixed') -or
        -not [string]::IsNullOrWhiteSpace([string]$vhd.ParentPath)) {
        throw "BLOCKED: unexpected parent/differencing disk for $name"
    }
    $dvds = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($dvds.Count -ne 1 -or
        -not [string]::Equals([string]$dvds[0].Path,$seedPath,[StringComparison]::OrdinalIgnoreCase)) {
        throw "BLOCKED: unexpected VM seed attachment for $name"
    }
    $nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $mgmt }).Count -ne 1 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $private }).Count -ne 1) {
        throw "BLOCKED: exact network identity mismatch for $name"
    }
    foreach ($other in @($AllVMs | Where-Object { $_.Id -ne $id })) {
        if (Test-Under ([string]$other.Path) $folder) {
            throw "BLOCKED: foreign VM configuration overlaps $name folder"
        }
        foreach ($drive in @(Get-VMHardDiskDrive -VM $other -ErrorAction Stop)) {
            if (Test-Under ([string]$drive.Path) $folder) {
                throw "BLOCKED: foreign VM disk references $name folder"
            }
        }
        foreach ($dvd in @(Get-VMDvdDrive -VM $other -ErrorAction Stop)) {
            if (Test-Under ([string]$dvd.Path) $folder) {
                throw "BLOCKED: foreign VM ISO references $name folder"
            }
        }
    }
    return $vm
}
function Assert-BothTargets {
    $allVMs = @(Get-VM -ErrorAction Stop)
    $resolved = @()
    foreach ($spec in $roles) {
        $resolved += Assert-ExactTarget -Spec $spec -AllVMs $allVMs
    }
    if ($resolved.Count -ne 2 -or $resolved[0].Id -eq $resolved[1].Id) {
        throw 'BLOCKED: must resolve both exact independent fresh VMs'
    }
    return $resolved
}
foreach ($command in @('Get-VM','Get-VMHardDiskDrive','Get-VMDvdDrive','Get-VMSnapshot',
    'Get-VMNetworkAdapter','Get-VHD','Stop-VM','Remove-VM')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "BLOCKED: missing required Hyper-V command: $command"
    }
}
$targets = @(Assert-BothTargets)
foreach ($vm in $targets) {
    Write-Host ("FRESH_REMOVE_TARGET: name={0} id={1} state={2} folder={3}" -f
        $vm.Name,$vm.Id,$vm.State,(Join-Path $storageRoot $vm.Name))
}
if ($Mode -eq 'PLAN') {
    Write-Host 'FRESH_REMOVE_PLAN_READY: only the exact fresh pair and their owned folders; no changes.'
    Write-Host 'DATA_LOSS: all guest Kubernetes data on both VHDX files would be permanently discarded.'
    return
}
# Re-validate the exact pair immediately before any mutation. Worker first.
[void]@(Assert-BothTargets)
foreach ($spec in @($roles[1],$roles[0])) {
    $vm = Assert-ExactTarget -Spec $spec -AllVMs @(Get-VM -ErrorAction Stop)
    if ($vm.State -eq 'Running') {
        # Normal Hyper-V guest shutdown; no -Force or -TurnOff fallback.
        Stop-VM -VM $vm -ErrorAction Stop
        $off = $false
        for ($i=0; $i -lt 30; $i++) {
            $current = @(Get-VM -Name $spec.Name -ErrorAction Stop)
            if ($current.Count -ne 1 -or $current[0].Id -ne $spec.Id) {
                throw 'BLOCKED: identity changed during orderly shutdown'
            }
            if ($current[0].State -eq 'Off') { $off = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $off) { throw 'BLOCKED: graceful stop timed out; no force-off or delete' }
    }
}
# Both guests must have stopped and passed fresh safety review before ANY VM unregister.
$stopped = @(Assert-BothTargets)
if (@($stopped | Where-Object { $_.State -ne 'Off' }).Count -ne 0) {
    throw 'BLOCKED: both fresh VMs must be Off before unregister'
}
# Remove worker then control plane. If one unregister fails, stop immediately:
# no rollback or blind retry. Other VMs and switches are never altered.
foreach ($spec in @($roles[1],$roles[0])) {
    $vm = Assert-ExactTarget -Spec $spec -AllVMs @(Get-VM -ErrorAction Stop)
    Remove-VM -VM $vm -Force -ErrorAction Stop
    if (@(Get-VM -Name $spec.Name -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'BLOCKED: VM still registered; preserve files'
    }
    $folder = Join-Path $storageRoot $spec.Name
    Assert-NoReparse $folder
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $folder) {
        throw "BLOCKED: VM directory still present; inspect manually: $folder"
    }
    Write-Host ("FRESH_REMOVE_COMPLETE: {0} UUID={1}" -f $spec.Name,$spec.Id)
}
Write-Host 'FRESH_PAIR_REMOVAL_PASS: exact former pair removed; old clusters, switches, caches untouched.'
