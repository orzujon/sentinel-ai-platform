#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
 Create a new Ubuntu 26.04 cloud-image-backed Hyper-V worker with cloud-init.
.DESCRIPTION
 Lab-only: uses the Windows Hyper-V Default Switch, an existing SSH public key,
 Canonical's signed release image checksum listing, and WSL tools qemu-img and
 cloud-localds. Refuses to modify existing VMs or disk paths. No passwords stored.
 The output VM is NOT automatically a Kubernetes cluster member.
.EXAMPLE
 .\New-SentinelWorker.ps1 -Name k8s-w01
#>
[CmdletBinding()]
param(
    [ValidatePattern('^k8s-w0[1-9]$')]
    [string]$Name = 'k8s-w01',
    [string]$PublicKeyPath = "$HOME\.ssh\id_ed25519.pub",
    [string]$SwitchName = 'Default Switch'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fixed lab directories reduce opportunities to overwrite an unexpected disk.
$vmRoot = 'C:\Sentinel\VMs'
$imageRoot = 'C:\Sentinel\Images'
$vmDir = Join-Path $vmRoot $Name
$vhdPath = Join-Path $vmDir 'os.vhdx'
$seedDir = Join-Path $vmDir 'seed'
$seedIso = Join-Path $vmDir 'cidata.iso'
$imageName = 'ubuntu-26.04-server-cloudimg-amd64.img'
$imagePath = Join-Path $imageRoot $imageName
$checksumPath = Join-Path $imageRoot 'SHA256SUMS'
$cloudRoot = 'https://cloud-images.ubuntu.com/releases/26.04/release'

function Assert-LastExit([string]$Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed (exit code $LASTEXITCODE). No further provisioning attempted."
    }
}
function WindowsToWsl([string]$Path) {
    $wslPath = (& wsl.exe --exec wslpath -a $Path | Out-String).Trim()
    Assert-LastExit "Converting Windows path $Path to WSL path"
    if (-not $wslPath.StartsWith('/mnt/')) {
        throw "WSL did not return an expected mounted Windows path: $wslPath"
    }
    return $wslPath
}
function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

Write-Host "Checking prerequisites for $Name" -ForegroundColor Cyan
$existing = @(Get-VM -Name $Name -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    throw "Refusing to create '$Name': $($existing.Count) VM registration(s) already exist. No changes made."
}
if (Test-Path -LiteralPath $vmDir) {
    throw "Refusing to overwrite existing directory: $vmDir. Inspect it first."
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V virtual switch '$SwitchName' does not exist."
}
if (-not (Test-Path -LiteralPath $PublicKeyPath)) {
    throw "SSH public key missing at '$PublicKeyPath'. Create one with: ssh-keygen -t ed25519 -f `"$HOME\.ssh\id_ed25519`""
}
$pubkey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
if ($pubkey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+(?:\s+[^\r\n]*)?$') {
    throw 'Public key file is not a single supported OpenSSH public key.'
}

# Verify an installed WSL distro and required tools. Do not install packages
# or change WSL automatically; prerequisite installation is an explicit step.
& wsl.exe --exec sh -c 'command -v qemu-img >/dev/null && command -v cloud-localds >/dev/null'
Assert-LastExit 'Checking WSL packages qemu-img and cloud-localds'

New-Item -ItemType Directory -Path $imageRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $imagePath)) {
    Write-Host "Downloading official Ubuntu cloud image from $cloudRoot" -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$cloudRoot/$imageName" -OutFile $imagePath -UseBasicParsing
}
Write-Host 'Downloading Canonical SHA256 checksum listing and verifying image...' -ForegroundColor Cyan
Invoke-WebRequest -Uri "$cloudRoot/SHA256SUMS" -OutFile $checksumPath -UseBasicParsing
$sumLines = Get-Content -LiteralPath $checksumPath
$sumMatch = @($sumLines | Where-Object { $_ -match ('(?i)\b\*?' + [regex]::Escape($imageName) + '\s*$') })
if ($sumMatch.Count -ne 1) {
    throw 'Could not find an unambiguous SHA256 entry for the Ubuntu cloud image.'
}
if ($sumMatch[0] -match '^\s*([a-fA-F0-9]{64})\s+') {
    $expectedHash = $Matches[1]
} else {
    throw 'Published checksum entry did not contain a SHA256 value.'
}
$actualHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash
if ($actualHash -ine $expectedHash) {
    throw "Ubuntu image SHA256 does not match published checksum. Delete cached image $imagePath and retry after verification."
}
Write-Host "Checksum verified: $actualHash" -ForegroundColor Green

# Unique node path; do not reuse or overwrite the control plane's VHDX.
New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
$userData = @"
#cloud-config
hostname: $Name
manage_etc_hosts: true
users:
  - name: orzu
    gecos: Sentinel lab operator
    groups: [adm, sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $pubkey
ssh_pwauth: false
disable_root: true
package_update: true
packages:
  - openssh-server
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
"@
$metaData = "instance-id: $Name`nlocal-hostname: $Name`n"
$userDataPath = Join-Path $seedDir 'user-data'
$metaDataPath = Join-Path $seedDir 'meta-data'
Write-Utf8NoBom $userDataPath ($userData + "`n")
Write-Utf8NoBom $metaDataPath $metaData

Write-Host 'Creating cloud-init NoCloud seed ISO in WSL...' -ForegroundColor Cyan
$seedLinux = WindowsToWsl $seedIso
$userLinux = WindowsToWsl $userDataPath
$metaLinux = WindowsToWsl $metaDataPath
& wsl.exe --exec cloud-localds $seedLinux $userLinux $metaLinux
Assert-LastExit 'Creating NoCloud seed ISO'

Write-Host 'Converting Ubuntu cloud disk to dynamic Hyper-V VHDX...' -ForegroundColor Cyan
$imgLinux = WindowsToWsl $imagePath
$vhdLinux = WindowsToWsl $vhdPath
& wsl.exe --exec qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic $imgLinux $vhdLinux
Assert-LastExit 'Converting QCOW2 cloud image to VHDX'
Resize-VHD -Path $vhdPath -SizeBytes 60GB

Write-Host 'Registering Hyper-V virtual machine...' -ForegroundColor Cyan
# New-VM can create a nested configuration directory. It references our
# unique VHDX; the creation guard above prevents ambiguous duplicates.
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes 4GB -VHDPath $vhdPath -Path $vmDir -SwitchName $SwitchName
Set-VMProcessor -VM $vm -Count 2
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
Add-VMDvdDrive -VM $vm -Path $seedIso | Out-Null
$bootDisk = @(Get-VMHardDiskDrive -VM $vm)
if ($bootDisk.Count -ne 1) { throw 'Expected exactly one hard disk. VM left powered off for inspection.' }
Set-VMFirmware -VM $vm -FirstBootDevice $bootDisk[0]

Write-Host "Provisioned $Name. Starting now..." -ForegroundColor Green
Start-VM -VM $vm
$vm | Select-Object Name, Id, State, Path
Write-Host "`nVM created and started. Cloud-init runs on first boot; SSH is key-only." -ForegroundColor Yellow
Write-Host "Use: Get-VMNetworkAdapter -VMName $Name | Select VMName,IPAddresses"
Write-Host "Then: ssh -i `"$($PublicKeyPath -replace '\.pub$','')`" orzu@<VM-IP>"
Write-Host 'No Kubernetes components have been installed yet.'
