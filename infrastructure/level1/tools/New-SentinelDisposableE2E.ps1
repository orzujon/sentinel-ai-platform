#Requires -Version 5.1
<#
.SYNOPSIS
  Explicitly approved, non-destructive provisioning of ONE disposable Ubuntu VM.
.DESCRIPTION
  This does not touch Sentinel Kubernetes VMs, existing switches or host SSH trust.
  Requires a reviewed Ubuntu 26.04 image and SHA256. NO cleanup/rollback on failure.
  This creates a VM for first-boot integration acceptance, NOT production bootstrap.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ImagePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ImageSHA256,
    [ValidateSet('Ubuntu-26.04')][string]$Distribution = 'Ubuntu-26.04',
    [ValidateSet('PLAN','CREATE')][string]$Mode = 'PLAN',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$name = 'sentinel-e2e-ssh01'
$root = 'C:\Sentinel\E2E-Disposable'
$helper = Join-Path $PSScriptRoot '..\src\prepare-disk-and-seed.sh'
$expectedApproval = 'CREATE_DISPOSABLE_SENTINEL_E2E_SSH01'
function To-WslPath([string]$path) {
    $result = & wsl.exe -d $Distribution -- wslpath -a $path
    if ($LASTEXITCODE -ne 0 -or @($result).Count -ne 1 -or -not [string]$result) {
        throw "BLOCKED: WSL could not translate the image or artifact path"
    }
    return ([string]$result).Trim()
}
function Invoke-Helper([string[]]$arguments) {
    $output = & wsl.exe -d $Distribution -- bash (To-WslPath $helper) @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "BLOCKED: WSL image/seed helper failed (exit $LASTEXITCODE): $($output -join '; ')" }
}
$preflight = Join-Path $PSScriptRoot 'Test-SentinelDisposableE2E.ps1'
# Preflight uses exit, so call as a fresh PowerShell process.
$psExe = (Get-Process -Id $PID).Path
& $psExe -NoProfile -File $preflight | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: disposable VM host isolation and capacity preflight failed' }
if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw 'BLOCKED: approved Ubuntu source image is missing' }
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'BLOCKED: Stage 3 WSL helper missing' }
$imageFile = (Resolve-Path -LiteralPath $ImagePath).Path
# Stage 2 intentionally stores content-addressed artifacts, not the upstream filename.
$expectedFileName = $ImageSHA256.ToLowerInvariant() + '.img'
$buildDirectory = Split-Path -Path $imageFile -Parent
$buildId = Split-Path -Path $buildDirectory -Leaf
$approvedCacheBase = 'C:\Sentinel\ImageCache\ubuntu\26.04'
$cacheBase = Split-Path -Path $buildDirectory -Parent
if ([IO.Path]::GetFileName($imageFile) -cne $expectedFileName -or
    $buildId -notmatch '^20[0-9]{6}
$sha = (Get-FileHash -LiteralPath $imageFile -Algorithm SHA256).Hash
if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: approved image SHA256 mismatch' }
$pubFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $pubFile -PathType Leaf)) { throw 'BLOCKED: local SSH public key unavailable' }
$pub = (Get-Content -LiteralPath $pubFile -Raw).Trim()
if ($pub -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or $pub.Contains("`n")) {
    throw 'BLOCKED: one valid ED25519 SSH login public key required'
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'BLOCKED: WSL unavailable' }
Invoke-Helper -arguments @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "E2E_PLAN_READY: reviewed image SHA256=$($sha.ToLowerInvariant()); VM=$name; memory=3GiB; disk=30GiB"
    Write-Host "PLAN_ONLY: no new VM, disks, files, network or SSH trust were modified."
    return
}
if ($Approval -cne $expectedApproval) { throw 'BLOCKED: explicit disposable VM approval token required' }
$typed = Read-Host "Type CREATE SENTINEL E2E SSH01 to create one disposable VM (no automatic cleanup)"
if ($typed -cne 'CREATE SENTINEL E2E SSH01') { throw 'BLOCKED: operator declined creation' }
# Re-check directly before first mutation.
if (@(Get-VM -Name $name -ErrorAction SilentlyContinue).Count -ne 0 -or
    (Test-Path -LiteralPath $root)) { throw 'BLOCKED: disposable target appeared; no adoption or replacement' }
$nonceBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonceBytes)
$nonce = ([BitConverter]::ToString($nonceBytes) -replace '-','').ToLowerInvariant()
# Manifest is intended for matching to Hyper-V VM ID; generation happens after VM creation.
$folder = Join-Path $root $name
[void](New-Item -Path $folder -ItemType Directory -Force)
$disk = Join-Path $folder 'os.vhdx'
$seed = Join-Path $folder 'seed.iso'
$userPath = Join-Path $folder 'user-data'
$metaPath = Join-Path $folder 'meta-data'
$netPath = Join-Path $folder 'network-config'
$noncePath = Join-Path $folder 'provisioning-nonce'
$manifestPath = Join-Path $folder 'provisioning.json'
# No secrets in git. These are host-local artifacts; nonce is not a credential.
[IO.File]::WriteAllText($noncePath, $nonce + "`n", [Text.UTF8Encoding]::new($false))
# Fresh image generates its own host identity, independent of our SSH login key.
$userData = @"
#cloud-config
hostname: $name
manage_etc_hosts: true
disable_root: true
ssh_pwauth: false
ssh_deletekeys: true
ssh_genkeytypes: [ed25519]
users:
  - name: orzu
    lock_passwd: true
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $pub
packages:
  - openssh-server
  - [linux-cloud-tools-common, '7.0.0-42.42']
write_files:
  - path: /var/lib/sentinel/provisioning-nonce
    permissions: '0600'
    owner: root:root
    content: $nonce
runcmd:
  - [systemctl, enable, --now, ssh]
  - [systemctl, enable, --now, hv-kvp-daemon.service]
"@
$meta = "instance-id: $name-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: $name`n"
$network = "version: 2`nethernets:`n  mgmt:`n    dhcp4: true`n    dhcp6: false`n"
foreach ($pair in @(@($userPath,$userData),@($metaPath,$meta),@($netPath,$network))) {
    [IO.File]::WriteAllText([string]$pair[0],[string]$pair[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -arguments @('disk',(To-WslPath $imageFile),(To-WslPath $disk))
Resize-VHD -Path $disk -SizeBytes (30GB) -ErrorAction Stop
Invoke-Helper -arguments @('seed',(To-WslPath $userPath),(To-WslPath $metaPath),(To-WslPath $netPath),(To-WslPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (3GB) -ErrorAction Stop
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (3GB)
Set-VMProcessor -VMName $name -Count 2
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1) { throw 'BLOCKED: unexpected VM disk layout; inspect before first boot' }
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema = 1
    purpose = 'disposable-ssh-kvp-e2e'
    node = $name
    vmId = ([string]$vm.Id)
    nonce = $nonce
    sourceImageSHA256 = $sha.ToLowerInvariant()
    createdUtc = [datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "E2E_VM_CREATED: $name; ID=$($vm.Id); manifest=$manifestPath"
Write-Host 'Booting: guest DHCP, cloud-init package install and KVP daemon are not yet verified.'
Write-Host 'Do not delete the VM automatically or trust its SSH key without separate attestation.'
 -or
    $cacheBase -cne $approvedCacheBase) {
    throw 'BLOCKED: image must be Stage 2 content-addressed cache artifact: ubuntu\\26.04\\YYYYMMDD\\<approved-sha256>.img'
}
$sha = (Get-FileHash -LiteralPath $imageFile -Algorithm SHA256).Hash
if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: approved image SHA256 mismatch' }
$pubFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $pubFile -PathType Leaf)) { throw 'BLOCKED: local SSH public key unavailable' }
$pub = (Get-Content -LiteralPath $pubFile -Raw).Trim()
if ($pub -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or $pub.Contains("`n")) {
    throw 'BLOCKED: one valid ED25519 SSH login public key required'
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'BLOCKED: WSL unavailable' }
Invoke-Helper -arguments @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "E2E_PLAN_READY: reviewed image SHA256=$($sha.ToLowerInvariant()); VM=$name; memory=3GiB; disk=30GiB"
    Write-Host "PLAN_ONLY: no new VM, disks, files, network or SSH trust were modified."
    return
}
if ($Approval -cne $expectedApproval) { throw 'BLOCKED: explicit disposable VM approval token required' }
$typed = Read-Host "Type CREATE SENTINEL E2E SSH01 to create one disposable VM (no automatic cleanup)"
if ($typed -cne 'CREATE SENTINEL E2E SSH01') { throw 'BLOCKED: operator declined creation' }
# Re-check directly before first mutation.
if (@(Get-VM -Name $name -ErrorAction SilentlyContinue).Count -ne 0 -or
    (Test-Path -LiteralPath $root)) { throw 'BLOCKED: disposable target appeared; no adoption or replacement' }
$nonceBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonceBytes)
$nonce = ([BitConverter]::ToString($nonceBytes) -replace '-','').ToLowerInvariant()
# Manifest is intended for matching to Hyper-V VM ID; generation happens after VM creation.
$folder = Join-Path $root $name
[void](New-Item -Path $folder -ItemType Directory -Force)
$disk = Join-Path $folder 'os.vhdx'
$seed = Join-Path $folder 'seed.iso'
$userPath = Join-Path $folder 'user-data'
$metaPath = Join-Path $folder 'meta-data'
$netPath = Join-Path $folder 'network-config'
$noncePath = Join-Path $folder 'provisioning-nonce'
$manifestPath = Join-Path $folder 'provisioning.json'
# No secrets in git. These are host-local artifacts; nonce is not a credential.
[IO.File]::WriteAllText($noncePath, $nonce + "`n", [Text.UTF8Encoding]::new($false))
# Fresh image generates its own host identity, independent of our SSH login key.
$userData = @"
#cloud-config
hostname: $name
manage_etc_hosts: true
disable_root: true
ssh_pwauth: false
ssh_deletekeys: true
ssh_genkeytypes: [ed25519]
users:
  - name: orzu
    lock_passwd: true
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $pub
packages:
  - openssh-server
  - [linux-cloud-tools-common, '7.0.0-42.42']
write_files:
  - path: /var/lib/sentinel/provisioning-nonce
    permissions: '0600'
    owner: root:root
    content: $nonce
runcmd:
  - [systemctl, enable, --now, ssh]
  - [systemctl, enable, --now, hv-kvp-daemon.service]
"@
$meta = "instance-id: $name-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: $name`n"
$network = "version: 2`nethernets:`n  mgmt:`n    dhcp4: true`n    dhcp6: false`n"
foreach ($pair in @(@($userPath,$userData),@($metaPath,$meta),@($netPath,$network))) {
    [IO.File]::WriteAllText([string]$pair[0],[string]$pair[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -arguments @('disk',(To-WslPath $imageFile),(To-WslPath $disk))
Resize-VHD -Path $disk -SizeBytes (30GB) -ErrorAction Stop
Invoke-Helper -arguments @('seed',(To-WslPath $userPath),(To-WslPath $metaPath),(To-WslPath $netPath),(To-WslPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (3GB) -ErrorAction Stop
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (3GB)
Set-VMProcessor -VMName $name -Count 2
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1) { throw 'BLOCKED: unexpected VM disk layout; inspect before first boot' }
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema = 1
    purpose = 'disposable-ssh-kvp-e2e'
    node = $name
    vmId = ([string]$vm.Id)
    nonce = $nonce
    sourceImageSHA256 = $sha.ToLowerInvariant()
    createdUtc = [datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "E2E_VM_CREATED: $name; ID=$($vm.Id); manifest=$manifestPath"
Write-Host 'Booting: guest DHCP, cloud-init package install and KVP daemon are not yet verified.'
Write-Host 'Do not delete the VM automatically or trust its SSH key without separate attestation.'
