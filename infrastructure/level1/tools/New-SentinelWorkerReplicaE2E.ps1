#Requires -Version 5.1
<#
.SYNOPSIS
  Approved provisioning of ONE small two-NIC worker-shaped disposable Ubuntu VM.
.DESCRIPTION
  Uses the SAME Stage 3 two-NIC layout, cloud-init MAC matching and SSH base as the worker.
  No Kubernetes installed. Existing lab nodes, switches and trusted SSH files are untouched.
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
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.WslPaths.psm1') -Force -ErrorAction Stop
$name = 'sentinel-e2e-w02'
$root = 'C:\Sentinel\E2E-WorkerReplica'
$helper = Join-Path $PSScriptRoot '..\src\prepare-disk-and-seed.sh'
$expectedApproval = 'CREATE_DISPOSABLE_SENTINEL_E2E_W02'
# Reserved extension of Stage 3's two-adapter worker addressing.
$privateIP = '10.78.0.12'
$managementMAC = '02AA78000112'
$privateMAC = '02AA78000012'

function Invoke-Helper([string[]]$arguments) {
    # --exec invokes bash directly. Avoid PowerShell passing backslashes
    # into a Linux shell where they can be silently stripped.
    & wsl.exe -d $Distribution --exec bash (ConvertTo-SentinelWslMountPath $helper) @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "BLOCKED: WSL helper failed (exit $LASTEXITCODE). Review WSL stderr above."
    }
}
$preflight = Join-Path $PSScriptRoot 'Test-SentinelWorkerReplicaE2E.ps1'
# Preflight uses exit, so call as a fresh PowerShell process.
$psExe = (Get-Process -Id $PID).Path
& $psExe -NoProfile -File $preflight | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: disposable VM host isolation and capacity preflight failed' }
if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw 'BLOCKED: approved Ubuntu source image is missing' }
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'BLOCKED: Stage 3 WSL helper missing' }
$imageFile = (Resolve-Path -LiteralPath $ImagePath).Path
# Stage 2 intentionally stores SHA256-named files rather than upstream filenames.
$expectedFileName = $ImageSHA256.ToLowerInvariant() + '.img'
$buildDirectory = Split-Path -Path $imageFile -Parent
$buildId = Split-Path -Path $buildDirectory -Leaf
$approvedCacheBase = 'C:\Sentinel\ImageCache\ubuntu\26.04'
$cacheBase = Split-Path -Path $buildDirectory -Parent
if ([IO.Path]::GetFileName($imageFile) -cne $expectedFileName -or
    $buildId -notmatch '^20[0-9]{6}$' -or
    $cacheBase -cne $approvedCacheBase) {
    throw 'BLOCKED: expected Stage 2 cached artifact under ubuntu\\26.04\\YYYYMMDD\\<sha256>.img'
}
$sha = (Get-FileHash -LiteralPath $imageFile -Algorithm SHA256).Hash
if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: approved image SHA256 mismatch' }
# Cross-check the Stage 2 cache-side metadata; a filename match alone
# does not establish provenance. The independent Stage 2 approval process
# remains the source of the reviewed digest.
$metadataPath = [IO.Path]::ChangeExtension($imageFile, '.json')
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw 'BLOCKED: Stage 2 cache metadata .json is missing; cannot verify cached image provenance'
}
$metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-' + $buildId + '/ubuntu-26.04-server-cloudimg-amd64.img'
$imageSize = (Get-Item -LiteralPath $imageFile).Length
if ([string]$metadata.sha256 -ine $sha -or
    [string]$metadata.buildId -cne $buildId -or
    [string]$metadata.sourceUrl -cne $expectedUrl -or
    [long]$metadata.sizeBytes -ne [long]$imageSize) {
    throw 'BLOCKED: Stage 2 metadata does not match expected Ubuntu source, build, digest and size'
}
$pubFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $pubFile -PathType Leaf)) { throw 'BLOCKED: local SSH public key unavailable' }
$pub = (Get-Content -LiteralPath $pubFile -Raw).Trim()
if ($pub -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or $pub.Contains("`n")) {
    throw 'BLOCKED: one valid ED25519 SSH login public key required'
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'BLOCKED: WSL unavailable' }
Invoke-Helper -arguments @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "WORKER_REPLICA_PLAN_READY: Stage 2 cache metadata and image SHA256 match; SHA256=$($sha.ToLowerInvariant()); VM=$name; memory=2GiB; disk=24GiB"
    Write-Host "PLAN_ONLY: same two-NIC worker topology proposed; no new VM, disks, files, network or SSH trust were modified."
    return
}
if ($Approval -cne $expectedApproval) { throw 'BLOCKED: explicit approval token required to create exactly one worker-shaped disposable VM' }
# The one reviewed approval token is sufficient: never prompt between pipeline steps.
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
# Follow Stage 3 startup: SSH is the only package dependency.
# KVP is deliberately installed in a later, separately gated stage AFTER DNS readiness.
packages: [openssh-server]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /var/lib/sentinel/provisioning-nonce
    permissions: '0600'
    owner: root:root
    content: $nonce
runcmd:
  - [systemctl, enable, --now, ssh]
"@
$meta = "instance-id: $name-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: $name`n"
# Mirror Stage 3 exactly: management via Default Switch DHCP, private
# via the existing Sentinel-L1 switch with stable MAC-based cloud-init matching.
$m1 = $managementMAC.ToLowerInvariant() -replace '(..)(?=.)','$1:'
$m2 = $privateMAC.ToLowerInvariant() -replace '(..)(?=.)','$1:'
$network = @"
version: 2
ethernets:
  management:
    match:
      macaddress: '$m1'
    dhcp4: true
    dhcp6: false
  private:
    match:
      macaddress: '$m2'
    dhcp4: false
    dhcp6: false
    addresses:
      - '$privateIP/24'
"@
foreach ($pair in @(@($userPath,$userData),@($metaPath,$meta),@($netPath,$network))) {
    [IO.File]::WriteAllText([string]$pair[0],[string]$pair[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -arguments @('disk',(ConvertTo-SentinelWslMountPath $imageFile),(ConvertTo-SentinelWslMountPath $disk))
Resize-VHD -Path $disk -SizeBytes (24GB) -ErrorAction Stop
Invoke-Helper -arguments @('seed',(ConvertTo-SentinelWslMountPath $userPath),(ConvertTo-SentinelWslMountPath $metaPath),(ConvertTo-SentinelWslMountPath $netPath),(ConvertTo-SentinelWslMountPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (2GB) -ErrorAction Stop
# This is a reproducible disposable test; don't auto-create differencing AVHDX disks.
Set-VM -Name $name -AutomaticCheckpointsEnabled $false -ErrorAction Stop
if ((Get-VM -Name $name -ErrorAction Stop).AutomaticCheckpointsEnabled) {
    throw 'BLOCKED: automatic Hyper-V checkpoints remain enabled; refuse first boot'
}
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (2GB)
Set-VMProcessor -VMName $name -Count 2
# Same Hyper-V NIC ordering as Stage 3. Never create or modify switches.
Add-VMNetworkAdapter -VMName $name -SwitchName 'Sentinel-L1' -Name 'K8s-Internal' -StaticMacAddress $privateMAC | Out-Null
$vmNics = @(Get-VMNetworkAdapter -VMName $name)
$mgmtNics = @($vmNics | Where-Object { $_.SwitchName -eq 'Default Switch' })
$privateNics = @($vmNics | Where-Object { $_.SwitchName -eq 'Sentinel-L1' })
if ($vmNics.Count -ne 2 -or $mgmtNics.Count -ne 1 -or $privateNics.Count -ne 1) {
    throw 'BLOCKED: replica NIC topology unexpected; do not boot; inspect manually'
}
Set-VMNetworkAdapter -VMNetworkAdapter $mgmtNics[0] -StaticMacAddress $managementMAC
$actualNics = @(Get-VMNetworkAdapter -VMName $name)
if (@($actualNics | Where-Object { $_.MacAddress -eq $managementMAC -and $_.SwitchName -eq 'Default Switch' }).Count -ne 1 -or
    @($actualNics | Where-Object { $_.MacAddress -eq $privateMAC -and $_.SwitchName -eq 'Sentinel-L1' }).Count -ne 1) {
    throw 'BLOCKED: replica stable MAC assignment not confirmed; do not boot'
}
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1) { throw 'BLOCKED: unexpected VM disk layout; inspect before first boot' }
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema = 1
    purpose = 'disposable-worker-replica-e2e'
    replicaOf = 'sentinel-l1-w01'
    privateIP = $privateIP
    managementMAC = $managementMAC
    privateMAC = $privateMAC
    kubernetesInstall = $false
    node = $name
    vmId = ([string]$vm.Id)
    nonce = $nonce
    sourceImageSHA256 = $sha.ToLowerInvariant()
    createdUtc = [datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "WORKER_REPLICA_CREATED: $name; ID=$($vm.Id); manifest=$manifestPath"
Write-Host 'Booting: same two-NIC Stage 3 networking; verify DHCP, static private IP, DNS and cloud-init before any KVP installation.'
Write-Host 'Do not delete the VM automatically or trust its SSH key without separate attestation.'
