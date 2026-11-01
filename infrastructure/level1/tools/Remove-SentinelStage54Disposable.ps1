#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.4: inspect/remove ONE explicitly identified disposable lab VM.
.DESCRIPTION
  PLAN is read-only; REMOVE is destructive and requires a separate explicit
  approval, exact Hyper-V VM UUID, manifest, disk/ISO ownership and snapshot
  safety checks. Only two target types: the previously tested w02 replica and
  Stage54 auto20..auto29. Never modifies the Kubernetes VMs, vSwitches, Stage 2
  image cache or any other VM. No automatic cleanup during provisioning.
.EXAMPLE
  .\Remove-SentinelStage54Disposable.ps1 -Mode PLAN -Target w02 -ExpectedVMId 7ce061eb-ac7a-43d6-bddb-a22070d2c6f9
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','REMOVE')][string]$Mode = 'PLAN',
    [ValidateSet('w02','stage54')][string]$Target = 'w02',
    [ValidateRange(20,29)][int]$Slot = 20,
    [Parameter(Mandatory)][guid]$ExpectedVMId,
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.HyperVDisposableLayout.psm1') -Force -ErrorAction Stop

# Enforce mutation permission before querying Hyper-V, reading storage or
# calling any removable cmdlet. Approval is scoped to the target family.
$w02Token = 'REMOVE_EXACT_SENTINEL_E2E_W02'
$stage54Token = 'REMOVE_EXACT_SENTINEL_STAGE54_DISPOSABLE'
if ($Mode -eq 'REMOVE') {
    $expectedToken = if ($Target -eq 'w02') { $w02Token } else { $stage54Token }
    if ($Approval -cne $expectedToken) {
        throw 'BLOCKED: explicit target-scoped disposable cleanup approval required'
    }
}
if ($ExpectedVMId -eq [guid]::Empty) { throw 'BLOCKED: explicit nonempty Hyper-V VM UUID required' }
$protectedVMs = @('sentinel-l1-cp01','sentinel-l1-w01','k8s-cp01','k8s-w01')
if ($Target -eq 'w02') {
    $name = 'sentinel-e2e-w02'
    $root = 'C:\Sentinel\E2E-WorkerReplica'
    $expectedPurpose = 'disposable-worker-replica-e2e'
    $schema = 1
    $expectedIP = '10.78.0.12'
    $mgmtMac = '02AA78000112'
    $privateMac = '02AA78000012'
    if ($ExpectedVMId -ne [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9') {
        throw 'BLOCKED: w02 is pinned to its known, previously verified Hyper-V UUID'
    }
} else {
    $name = 'sentinel-e2e-auto' + $Slot
    $root = 'C:\Sentinel\Stage54'
    $expectedPurpose = 'sentinel-stage54-disposable-bootstrap'
    $schema = 2
    $expectedIP = '10.78.0.' + $Slot
    $mgmtMac = '02AA780001' + $Slot
    $privateMac = '02AA780000' + $Slot
}
if ($name -in $protectedVMs) { throw 'BLOCKED: target resolves to protected Kubernetes VM' }

$folder = Join-Path $root $name
$manifestPath = Join-Path $folder 'provisioning.json'
$expectedDisk = Join-Path $folder 'os.vhdx'
$expectedSeed = Join-Path $folder 'seed.iso'
function Test-InFolder([string]$Candidate,[string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    $full = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    return ($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase))
}
function Assert-NotReparse([string]$Path) {
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "BLOCKED: reparse point under disposable storage: $Path"
    }
}
function Assert-CurrentSafety {
    foreach ($cmd in @('Get-VM','Get-VMHardDiskDrive','Get-VMDvdDrive','Get-VMSnapshot',
                       'Get-VMNetworkAdapter','Get-VHD','Stop-VM','Remove-VM')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "BLOCKED: missing Hyper-V command $cmd"
        }
    }
    foreach ($path in @($root,$folder,$manifestPath,$expectedDisk,$expectedSeed)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "BLOCKED: expected private disposable file/directory absent: $path"
        }
        Assert-NotReparse $path
    }
    $parent = Get-Item -LiteralPath $root -Force
    $directory = Get-Item -LiteralPath $folder -Force
    if (-not $parent.PSIsContainer -or -not $directory.PSIsContainer) {
        throw 'BLOCKED: disposable directory layout invalid'
    }
    # Inspect links throughout the exact target, not other VM directories.
    foreach ($item in @(Get-ChildItem -LiteralPath $folder -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCKED: junction or symlink under proposed deletion scope: $($item.FullName)"
        }
    }
    $manifestFile = Get-Item -LiteralPath $manifestPath -Force
    if ($manifestFile.Length -gt 8192 -or $manifestFile.PSIsContainer) {
        throw 'BLOCKED: manifest is too large or not a regular file'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestVMId = [guid]::Empty
    if (-not [guid]::TryParse([string]$manifest.vmId,[ref]$manifestVMId) -or
        $manifestVMId -ne $ExpectedVMId -or
        [int]$manifest.schema -ne $schema -or
        [string]$manifest.node -cne $name -or
        [string]$manifest.purpose -cne $expectedPurpose -or
        [string]$manifest.privateIP -cne $expectedIP -or
        [string]$manifest.managementMAC -cne $mgmtMac -or
        [string]$manifest.privateMAC -cne $privateMac -or
        [string]$manifest.nonce -cnotmatch '^[0-9a-f]{64}$' -or
        $manifest.kubernetesInstall -ne $false) {
        throw 'BLOCKED: independently created manifest is not the exact disposable target'
    }
    $all = @(Get-VM -ErrorAction Stop)
    $matches = @($all | Where-Object { $_.Name -ceq $name })
    if ($matches.Count -ne 1 -or $matches[0].Id -ne $ExpectedVMId) {
        throw 'BLOCKED: exact Hyper-V VM name and UUID do not match cleanup request'
    }
    $vm = $matches[0]
    if ($vm.State -notin @('Running','Off')) {
        throw 'BLOCKED: unexpected VM state; refuse cleanup'
    }
    if (-not (Test-InFolder ([string]$vm.Path) $folder)) {
        throw 'BLOCKED: Hyper-V VM configuration is outside the disposable directory'
    }
    # A New-VM -Path <folder> invocation can create an additional
    # <folder>\<VM-name>\Virtual Machines configuration subtree.
    # Its NAME is not enough to own it: bind its exact path and VM UUID
    # to the live Hyper-V object before admitting it to the removal scope.
    $nested = Join-Path $folder $name
    $allowNested = $false
    if (Test-Path -LiteralPath $nested) {
        $nestedItem = Get-Item -LiteralPath $nested -Force -ErrorAction Stop
        if (-not $nestedItem.PSIsContainer -or
            ($nestedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'BLOCKED: same-name nested VM entry is not a real directory'
        }
        if (-not (Test-InFolder -Candidate ([string]$vm.Path) -Directory $nested)) {
            Write-Host ("CLEANUP_NESTED_PATH_MISMATCH: nested={0}; hypervPath={1}" -f
                $nested, [string]$vm.Path)
            throw 'BLOCKED: nested VM directory is not Hyper-V configuration for the exact UUID'
        }
        $nestedAllowlist = @('Virtual Machines','Snapshots','Smart Paging','Virtual Hard Disks')
        $unexpectedNested = @(Get-ChildItem -LiteralPath $nested -Force -ErrorAction Stop |
            Where-Object { $_.Name -cnotin $nestedAllowlist -or -not $_.PSIsContainer })
        if ($unexpectedNested.Count -ne 0) {
            foreach ($entry in $unexpectedNested) {
                Write-Host ("CLEANUP_UNRECOGNISED_NESTED_ENTRY: {0}" -f $entry.FullName)
            }
            throw 'BLOCKED: nested Hyper-V configuration contains unknown top-level entries'
        }
        # Verify exactly one GUID.vmcx and only GUID.vmrs/.vmgs plus an
        # optional GUID-named runtime directory with strictly permitted
        # contents. This is an offline, read-only layout validator.
        $configDir = Join-Path $nested 'Virtual Machines'
        if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
            throw 'BLOCKED: nested VM configuration directory missing'
        }
        $layoutStatus = Assert-SentinelHyperVConfigLayout -ConfigDirectory $configDir -ExpectedVMId $ExpectedVMId
        if ($layoutStatus -cne 'VERIFIED') {
            throw 'BLOCKED: exact Hyper-V VM UUID configuration layout not verified'
        }
        # The disk is located at the outer folder, and this lab has no
        # checkpoints. Therefore other nested Hyper-V folders must be empty.
        foreach ($childName in @('Snapshots','Smart Paging','Virtual Hard Disks')) {
            $childPath = Join-Path $nested $childName
            if (Test-Path -LiteralPath $childPath) {
                if (-not (Test-Path -LiteralPath $childPath -PathType Container) -or
                    @(Get-ChildItem -LiteralPath $childPath -Force -ErrorAction Stop).Count -ne 0) {
                    throw "BLOCKED: nested Hyper-V $childName directory is not empty/valid"
                }
            }
        }
        $allowNested = $true
        Write-Host ("CLEANUP_NESTED_HYPERV_CONFIG_VERIFIED: directory={0}; vmId={1}" -f
            $nested, [string]$vm.Id)
    }
    # Compare exact filenames, not a wildcard. The one extra directory is
    # allowed only AFTER the live Hyper-V path and UUID-backed vmcx validation.
    $topAllowed = @(
        'os.vhdx','seed.iso','user-data','meta-data','network-config',
        'provisioning.json','provisioning-nonce','diagnostic_known_hosts',
        'trusted_known_hosts','ansible-inventory.ini',
        'Virtual Machines','Snapshots','Smart Paging','Virtual Hard Disks'
    )
    if ($allowNested) { $topAllowed += $name }
    $unexpected = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop |
        Where-Object { $_.Name -cnotin $topAllowed })
    if ($unexpected.Count -ne 0) {
        Write-Warning ("CLEANUP_UNRECOGNISED_ENTRIES: count={0}; no deletion performed." -f $unexpected.Count)
        foreach ($item in $unexpected) {
            $kind = if ($item.PSIsContainer) { 'directory' } else { 'file' }
            $bytes = if ($item.PSIsContainer) { 'n/a' } else { [string]$item.Length }
            Write-Host ("CLEANUP_UNRECOGNISED_ENTRY: type={0}; bytes={1}; attributes={2}; path={3}" -f
                $kind, $bytes, [string]$item.Attributes, [string]$item.FullName)
        }
        throw ("BLOCKED: {0} unrecognised disposable top-level entries; review each path before changing allowlist or deleting anything." -f $unexpected.Count)
    }
    $disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
    if ($disks.Count -ne 1 -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$disks[0].Path),
                             [IO.Path]::GetFullPath($expectedDisk),
                             [StringComparison]::OrdinalIgnoreCase)) {
        throw 'BLOCKED: VM attached disk is not exactly the expected standalone OS VHDX'
    }
    $vhd = Get-VHD -Path $expectedDisk -ErrorAction Stop
    if ([string]$vhd.VhdType -notin @('Dynamic','Fixed') -or
        -not [string]::IsNullOrWhiteSpace([string]$vhd.ParentPath)) {
        throw 'BLOCKED: original guest disk unexpectedly differs or has a parent'
    }
    if (@(Get-ChildItem -LiteralPath $folder -Recurse -Force -File -Filter '*.avhdx').Count -ne 0) {
        throw 'BLOCKED: differencing disks found; refuse implicit checkpoint deletion'
    }
    if (@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count -ne 0) {
        throw 'BLOCKED: VM checkpoints exist; inspect and clean separately'
    }
    $dvds = @(Get-VMDvdDrive -VM $vm -ErrorAction Stop)
    if ($dvds.Count -ne 1 -or
        -not [string]::Equals([string]$dvds[0].Path,$expectedSeed,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'BLOCKED: unexpected guest NoCloud ISO attachment'
    }
    $nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $mgmtMac }).Count -ne 1 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $privateMac }).Count -ne 1) {
        throw 'BLOCKED: VM network topology is not the approved disposable layout'
    }
    # Ownership exclusion: no other VM is allowed to point into our target,
    # including disk/ISO or the Hyper-V VM configuration root.
    foreach ($other in @($all | Where-Object { $_.Id -ne $ExpectedVMId })) {
        if (Test-InFolder ([string]$other.Path) $folder) {
            throw "BLOCKED: foreign VM configuration in disposable directory: $($other.Name)"
        }
        foreach ($drive in @(Get-VMHardDiskDrive -VM $other -ErrorAction Stop)) {
            if (Test-InFolder ([string]$drive.Path) $folder) {
                throw "BLOCKED: foreign VM VHD attached inside cleanup scope: $($other.Name)"
            }
        }
        foreach ($drive in @(Get-VMDvdDrive -VM $other -ErrorAction Stop)) {
            if (Test-InFolder ([string]$drive.Path) $folder) {
                throw "BLOCKED: foreign VM DVD attached inside cleanup scope: $($other.Name)"
            }
        }
    }
    return $vm
}

$vm = Assert-CurrentSafety
[pscustomobject]@{
    Result = 'EXACT_DISPOSABLE_CLEANUP_TARGET'
    Mode = $Mode
    Name = $name
    VMId = [string]$vm.Id
    VMState = [string]$vm.State
    DirectoryToDelete = $folder
    OSDisk = $expectedDisk
    Seed = $expectedSeed
    ProtectedKubernetesVMsUntouched = $true
    Stage2CacheUntouched = $true
} | Format-List
if ($Mode -eq 'PLAN') {
    Write-Host 'STAGE54_CLEANUP_PLAN_READY: read-only proof of exclusive disposable VM/disk ownership.'
    return
}
# A second exact check before any destructive command. Never delete unrelated
# VMs or force-off a running Linux guest.
$again = Assert-CurrentSafety
if ($again.Id -ne $ExpectedVMId) { throw 'BLOCKED: VM changed after cleanup PLAN' }
if ($again.State -ne 'Off') {
    Stop-VM -VM $again -Shutdown -ErrorAction Stop
    $stopped = $false
    for ($attempt=0; $attempt -lt 30; $attempt++) {
        $state = @(Get-VM -Name $name -ErrorAction Stop)
        if ($state.Count -ne 1 -or $state[0].Id -ne $ExpectedVMId) {
            throw 'BLOCKED: VM identity changed during graceful stop'
        }
        if ($state[0].State -eq 'Off') { $stopped = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $stopped) {
        throw 'BLOCKED: graceful shutdown not complete; no forced power-off or deletion'
    }
}
# Final identity + disk-attachment check, then remove ONLY that Hyper-V VM.
$stoppedVM = Assert-CurrentSafety
if ($stoppedVM.Id -ne $ExpectedVMId -or $stoppedVM.State -ne 'Off') {
    throw 'BLOCKED: unexpected VM state after shutdown'
}
Remove-VM -VM $stoppedVM -Force -ErrorAction Stop
if (@(Get-VM -Name $name -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'BLOCKED: VM is still registered; preserve original files'
}
# Files remain untouched until after the Hyper-V VM is unregistered.
# All paths have been previously checked for links and foreign attachments.
Assert-NotReparse $folder
Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
if (Test-Path -LiteralPath $folder) {
    throw 'BLOCKED: target directory not removed; investigate manually'
}
Write-Host "STAGE54_DISPOSABLE_CLEANUP_COMPLETE: removed exact VM $name ($ExpectedVMId) and its own files only."
Write-Host 'No other VMs, Hyper-V switches or cached OS images were modified.'
