#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.4 - build a fresh isolated disposable Hyper-V Ubuntu VM with
  cloud-init's KVP public-host-key publisher installed before any SSH.
.DESCRIPTION
  PLAN is read-only; CREATE requires explicit approval. Never adopts existing
  VMs, deletes anything, edits switches, or connects with provisional SSH.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','CREATE')][string]$Mode = 'PLAN',
    [ValidateRange(20,29)][int]$Slot = 20,
    [Parameter(Mandatory)][string]$ImagePath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ImageSHA256,
    [ValidateSet('Ubuntu-26.04')][string]$Distribution = 'Ubuntu-26.04',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'CREATE' -and $Approval -cne 'CREATE_FRESH_DISPOSABLE_SENTINEL_STAGE54') {
    throw 'BLOCKED: explicit fresh-VM CREATE approval required'
}
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.WslPaths.psm1') -Force
$name = 'sentinel-e2e-auto' + $Slot
$ip = '10.78.0.' + $Slot
$macManagement = '02AA780001' + $Slot
$macPrivate = '02AA780000' + $Slot
$root = 'C:\Sentinel\Stage54'
$folder = Join-Path $root $name
$helper = Join-Path $PSScriptRoot '..\src\prepare-disk-and-seed.sh'
$publisher = Join-Path $PSScriptRoot '..\src\publish_firstboot_kvp.py'
$setup = Join-Path $PSScriptRoot '..\src\firstboot-kvp-setup.sh'

function Invoke-Helper([string[]]$argsList) {
    & wsl.exe -d $Distribution --exec bash (ConvertTo-SentinelWslMountPath $helper) @argsList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: WSL disk/seed helper failed; inspect without deleting state' }
}
function Protect-NewDirectory([string]$path) {
    if (Test-Path -LiteralPath $path) { throw 'BLOCKED: existing state folder cannot be overwritten' }
    [void][IO.Directory]::CreateDirectory($path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($owner)
    $principals = @(
        $owner,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    )
    foreach ($sid in $principals) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($path,$acl)
    if (-not ([IO.Directory]::GetAccessControl($path)).AreAccessRulesProtected) {
        throw 'BLOCKED: private provisioning directory ACL could not be established'
    }
}
function To-B64([string]$source) {
    return [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($source))
}
function Assert-ExistingStateRoot {
    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'BLOCKED: Stage54 parent folder is not a normal directory'
        }
        if (-not ([IO.Directory]::GetAccessControl($root)).AreAccessRulesProtected) {
            throw 'BLOCKED: Stage54 parent folder ACL not protected'
        }
    }
}
function Assert-NewSlot {
    # One disposable firstboot test at a time: previous test VMs require an
    # independently approved CLEANUP PLAN/REMOVE before another CREATE.
    # Never reuse a VM's nonce, UUID, private IP, or trust material.
    $priorDisposable = @(Get-VM -ErrorAction Stop | Where-Object {
        $_.Name -cmatch '^sentinel-e2e-(w02|ssh01|auto2[0-9])
        (Test-Path -LiteralPath $folder)) {
        throw 'BLOCKED: disposable slot already occupied; never adopt or overwrite existing VM'
    }
    Assert-ExistingStateRoot
    $switches = @(Get-VMSwitch -ErrorAction Stop | Select-Object -ExpandProperty Name)
    if ('Default Switch' -notin $switches -or 'Sentinel-L1' -notin $switches) {
        throw 'BLOCKED: required pre-existing switches missing; do not create/change switches'
    }
    $used = @(Get-VMNetworkAdapter -All -ErrorAction Stop |
        Where-Object { $_.MacAddress -in @($macManagement,$macPrivate) })
    if ($used.Count -ne 0) { throw 'BLOCKED: static MAC already allocated' }
    if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip }).Count -ne 0) {
        throw 'BLOCKED: disposable IP used by Windows host'
    }
    if (@(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip -and $_.State -notin @('Incomplete','Unreachable') }).Count -ne 0) {
        throw 'BLOCKED: disposable IP seen in neighbour table'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([long]$os.FreePhysicalMemory * 1KB -lt 4GB) { throw 'BLOCKED: host RAM headroom below 4GiB' }
    if (-not (Get-Command Resize-VHD -ErrorAction SilentlyContinue) -or
        -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'BLOCKED: Hyper-V VHD/WSL tools unavailable'
    }
    foreach ($src in @($helper,$publisher,$setup)) {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "BLOCKED: bundled guest source missing: $src" }
    }
}
function Assert-Stage2Source {
    $image = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path
    $parent = Split-Path $image -Parent
    $build = Split-Path $parent -Leaf
    $cache = Split-Path $parent -Parent
    if ([IO.Path]::GetFileName($image) -cne ($ImageSHA256.ToLowerInvariant()+'.img') -or
        $cache -cne 'C:\Sentinel\ImageCache\ubuntu\26.04' -or
        $build -cnotmatch '^20[0-9]{6}$') {
        throw 'BLOCKED: image outside approved Stage 2 SHA256 cache'
    }
    $sha = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
    if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: image digest mismatch' }
    $sidecar = [IO.Path]::ChangeExtension($image,'.json')
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { throw 'BLOCKED: image sidecar missing' }
    $meta = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-' + $build + '/ubuntu-26.04-server-cloudimg-amd64.img'
    if ([string]$meta.sha256 -ine $sha -or [string]$meta.buildId -cne $build -or
        [string]$meta.sourceUrl -cne $sourceUrl -or
        [long]$meta.sizeBytes -ne (Get-Item -LiteralPath $image).Length) {
        throw 'BLOCKED: reviewed image source metadata mismatch'
    }
    return $image
}
Assert-NewSlot
$image = Assert-Stage2Source
$loginKeyFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $loginKeyFile -PathType Leaf)) { throw 'BLOCKED: SSH login public key missing' }
$loginKey = (Get-Content -LiteralPath $loginKeyFile -Raw -Encoding ASCII).Trim()
if ($loginKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or
    $loginKey.Contains([char]10)) {
    throw 'BLOCKED: invalid or multiple SSH login public keys'
}
Invoke-Helper -argsList @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "STAGE54_CREATE_PLAN_READY: VM=$name IP=$ip MACs=$macManagement,$macPrivate; image SHA256 validated."
    Write-Host 'PLAN_ONLY: no VMs, disks, switches, trust stores or Ansible state changed.'
    Write-Host 'FIRSTBOOT_DEPENDENCY: guest needs signed APT access to install matching KVP tools; DNS failure blocks safely.'
    return
}
# The approval authorises a new cloud image and FIRST-BOOT publication only.
# No network-first SSH trust is required or permitted.
$nonceBytes = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($nonceBytes) } finally { $rng.Dispose() }
$nonce = ([BitConverter]::ToString($nonceBytes) -replace '-','').ToLowerInvariant()
$guestConfig = [ordered]@{schema=2;node=$name;ip=$ip;nonce=$nonce} | ConvertTo-Json -Compress
$guestPublisher = Get-Content -LiteralPath $publisher -Raw -Encoding UTF8
$guestSetup = Get-Content -LiteralPath $setup -Raw -Encoding UTF8
if (-not (Test-Path -LiteralPath $root)) { Protect-NewDirectory $root }
Protect-NewDirectory $folder
$userDataFile = Join-Path $folder 'user-data'
$metaDataFile = Join-Path $folder 'meta-data'
$networkFile = Join-Path $folder 'network-config'
$disk = Join-Path $folder 'os.vhdx'
$seed = Join-Path $folder 'seed.iso'
$configB64 = To-B64 $guestConfig
$publisherB64 = To-B64 $guestPublisher
$setupB64 = To-B64 $guestSetup
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
      - $loginKey
packages: [openssh-server]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /etc/sentinel/bootstrap.json
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: $configB64
  - path: /usr/local/lib/sentinel/publish_firstboot_kvp.py
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $publisherB64
  - path: /usr/local/sbin/sentinel-firstboot-kvp.sh
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $setupB64
runcmd:
  - [systemctl, enable, --now, ssh]
  - [bash, /usr/local/sbin/sentinel-firstboot-kvp.sh]
"@
$m1 = ($macManagement.ToLowerInvariant() -replace '(..)(?=.)','$1:')
$m2 = ($macPrivate.ToLowerInvariant() -replace '(..)(?=.)','$1:')
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
    addresses: ['$ip/24']
"@
$nl = [string][char]10
$metaData = 'instance-id: ' + $name + '-' + [guid]::NewGuid().ToString('N') + $nl + 'local-hostname: ' + $name + $nl
foreach ($item in @(@($userDataFile,$userData),@($metaDataFile,$metaData),@($networkFile,$network))) {
    [IO.File]::WriteAllText([string]$item[0],[string]$item[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -argsList @('disk',(ConvertTo-SentinelWslMountPath $image),(ConvertTo-SentinelWslMountPath $disk))
Resize-VHD -Path $disk -SizeBytes (24GB)
Invoke-Helper -argsList @('seed',(ConvertTo-SentinelWslMountPath $userDataFile),(ConvertTo-SentinelWslMountPath $metaDataFile),(ConvertTo-SentinelWslMountPath $networkFile),(ConvertTo-SentinelWslMountPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (2GB) -ErrorAction Stop
Set-VM -Name $name -AutomaticCheckpointsEnabled $false
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (2GB)
Set-VMProcessor -VMName $name -Count 2
Add-VMNetworkAdapter -VMName $name -SwitchName 'Sentinel-L1' -Name 'K8s-Internal' -StaticMacAddress $macPrivate | Out-Null
$nics = @(Get-VMNetworkAdapter -VMName $name)
$management = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' })
if ($nics.Count -ne 2 -or $management.Count -ne 1) { throw 'BLOCKED: created NIC topology unexpected; do not boot' }
Set-VMNetworkAdapter -VMNetworkAdapter $management[0] -StaticMacAddress $macManagement
$nics = @(Get-VMNetworkAdapter -VMName $name)
if (@($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $macManagement }).Count -ne 1 -or
    @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $macPrivate }).Count -ne 1) {
    throw 'BLOCKED: VM NIC identity does not match plan; do not boot'
}
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1 -or (Get-VM -Name $name).AutomaticCheckpointsEnabled) {
    throw 'BLOCKED: unsafe disk or automatic checkpoint; do not boot'
}
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema=2; purpose='sentinel-stage54-disposable-bootstrap'; node=$name;
    privateIP=$ip; vmId=[string]$vm.Id; nonce=$nonce;
    managementMAC=$macManagement; privateMAC=$macPrivate;
    sourceImageSHA256=$ImageSHA256.ToLowerInvariant();
    kubernetesInstall=$false; createdUtc=[datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $folder 'provisioning.json'),($manifest | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "STAGE54_VM_CREATED: $name VM-ID=$($vm.Id); public KVP host-key publication seeded before SSH."
Write-Host 'No SSH connection made; await KVP identity using Invoke-SentinelStage54Trust.ps1 -Mode VERIFY.'

    })
    if ($priorDisposable.Count -ne 0) {
        $priorNames = ($priorDisposable | Select-Object -ExpandProperty Name) -join ', '
        throw "BLOCKED: STAGE54_CLEANUP_REQUIRED: old disposable VMs exist: $priorNames. Run the separate exact-UUID cleanup PLAN and approved REMOVE first; never auto-delete."
    }
    foreach ($priorPath in @(
        'C:\Sentinel\E2E-WorkerReplica\sentinel-e2e-w02',
        'C:\Sentinel\E2E-Disposable\sentinel-e2e-ssh01'
    )) {
        if (Test-Path -LiteralPath $priorPath) {
            throw "BLOCKED: STAGE54_CLEANUP_REQUIRED: old disposable storage remains at $priorPath; inspect before new VM creation"
        }
    }
    if (Test-Path -LiteralPath 'C:\Sentinel\Stage54') {
        $staleSlots = @(Get-ChildItem -LiteralPath 'C:\Sentinel\Stage54' -Force -ErrorAction Stop |
            Where-Object { $_.Name -cmatch '^sentinel-e2e-auto2[0-9]
        (Test-Path -LiteralPath $folder)) {
        throw 'BLOCKED: disposable slot already occupied; never adopt or overwrite existing VM'
    }
    Assert-ExistingStateRoot
    $switches = @(Get-VMSwitch -ErrorAction Stop | Select-Object -ExpandProperty Name)
    if ('Default Switch' -notin $switches -or 'Sentinel-L1' -notin $switches) {
        throw 'BLOCKED: required pre-existing switches missing; do not create/change switches'
    }
    $used = @(Get-VMNetworkAdapter -All -ErrorAction Stop |
        Where-Object { $_.MacAddress -in @($macManagement,$macPrivate) })
    if ($used.Count -ne 0) { throw 'BLOCKED: static MAC already allocated' }
    if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip }).Count -ne 0) {
        throw 'BLOCKED: disposable IP used by Windows host'
    }
    if (@(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip -and $_.State -notin @('Incomplete','Unreachable') }).Count -ne 0) {
        throw 'BLOCKED: disposable IP seen in neighbour table'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([long]$os.FreePhysicalMemory * 1KB -lt 4GB) { throw 'BLOCKED: host RAM headroom below 4GiB' }
    if (-not (Get-Command Resize-VHD -ErrorAction SilentlyContinue) -or
        -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'BLOCKED: Hyper-V VHD/WSL tools unavailable'
    }
    foreach ($src in @($helper,$publisher,$setup)) {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "BLOCKED: bundled guest source missing: $src" }
    }
}
function Assert-Stage2Source {
    $image = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path
    $parent = Split-Path $image -Parent
    $build = Split-Path $parent -Leaf
    $cache = Split-Path $parent -Parent
    if ([IO.Path]::GetFileName($image) -cne ($ImageSHA256.ToLowerInvariant()+'.img') -or
        $cache -cne 'C:\Sentinel\ImageCache\ubuntu\26.04' -or
        $build -cnotmatch '^20[0-9]{6}$') {
        throw 'BLOCKED: image outside approved Stage 2 SHA256 cache'
    }
    $sha = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
    if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: image digest mismatch' }
    $sidecar = [IO.Path]::ChangeExtension($image,'.json')
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { throw 'BLOCKED: image sidecar missing' }
    $meta = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-' + $build + '/ubuntu-26.04-server-cloudimg-amd64.img'
    if ([string]$meta.sha256 -ine $sha -or [string]$meta.buildId -cne $build -or
        [string]$meta.sourceUrl -cne $sourceUrl -or
        [long]$meta.sizeBytes -ne (Get-Item -LiteralPath $image).Length) {
        throw 'BLOCKED: reviewed image source metadata mismatch'
    }
    return $image
}
Assert-NewSlot
$image = Assert-Stage2Source
$loginKeyFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $loginKeyFile -PathType Leaf)) { throw 'BLOCKED: SSH login public key missing' }
$loginKey = (Get-Content -LiteralPath $loginKeyFile -Raw -Encoding ASCII).Trim()
if ($loginKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or
    $loginKey.Contains([char]10)) {
    throw 'BLOCKED: invalid or multiple SSH login public keys'
}
Invoke-Helper -argsList @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "STAGE54_CREATE_PLAN_READY: VM=$name IP=$ip MACs=$macManagement,$macPrivate; image SHA256 validated."
    Write-Host 'PLAN_ONLY: no VMs, disks, switches, trust stores or Ansible state changed.'
    Write-Host 'FIRSTBOOT_DEPENDENCY: guest needs signed APT access to install matching KVP tools; DNS failure blocks safely.'
    return
}
# The approval authorises a new cloud image and FIRST-BOOT publication only.
# No network-first SSH trust is required or permitted.
$nonceBytes = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($nonceBytes) } finally { $rng.Dispose() }
$nonce = ([BitConverter]::ToString($nonceBytes) -replace '-','').ToLowerInvariant()
$guestConfig = [ordered]@{schema=2;node=$name;ip=$ip;nonce=$nonce} | ConvertTo-Json -Compress
$guestPublisher = Get-Content -LiteralPath $publisher -Raw -Encoding UTF8
$guestSetup = Get-Content -LiteralPath $setup -Raw -Encoding UTF8
if (-not (Test-Path -LiteralPath $root)) { Protect-NewDirectory $root }
Protect-NewDirectory $folder
$userDataFile = Join-Path $folder 'user-data'
$metaDataFile = Join-Path $folder 'meta-data'
$networkFile = Join-Path $folder 'network-config'
$disk = Join-Path $folder 'os.vhdx'
$seed = Join-Path $folder 'seed.iso'
$configB64 = To-B64 $guestConfig
$publisherB64 = To-B64 $guestPublisher
$setupB64 = To-B64 $guestSetup
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
      - $loginKey
packages: [openssh-server]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /etc/sentinel/bootstrap.json
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: $configB64
  - path: /usr/local/lib/sentinel/publish_firstboot_kvp.py
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $publisherB64
  - path: /usr/local/sbin/sentinel-firstboot-kvp.sh
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $setupB64
runcmd:
  - [systemctl, enable, --now, ssh]
  - [bash, /usr/local/sbin/sentinel-firstboot-kvp.sh]
"@
$m1 = ($macManagement.ToLowerInvariant() -replace '(..)(?=.)','$1:')
$m2 = ($macPrivate.ToLowerInvariant() -replace '(..)(?=.)','$1:')
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
    addresses: ['$ip/24']
"@
$nl = [string][char]10
$metaData = 'instance-id: ' + $name + '-' + [guid]::NewGuid().ToString('N') + $nl + 'local-hostname: ' + $name + $nl
foreach ($item in @(@($userDataFile,$userData),@($metaDataFile,$metaData),@($networkFile,$network))) {
    [IO.File]::WriteAllText([string]$item[0],[string]$item[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -argsList @('disk',(ConvertTo-SentinelWslMountPath $image),(ConvertTo-SentinelWslMountPath $disk))
Resize-VHD -Path $disk -SizeBytes (24GB)
Invoke-Helper -argsList @('seed',(ConvertTo-SentinelWslMountPath $userDataFile),(ConvertTo-SentinelWslMountPath $metaDataFile),(ConvertTo-SentinelWslMountPath $networkFile),(ConvertTo-SentinelWslMountPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (2GB) -ErrorAction Stop
Set-VM -Name $name -AutomaticCheckpointsEnabled $false
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (2GB)
Set-VMProcessor -VMName $name -Count 2
Add-VMNetworkAdapter -VMName $name -SwitchName 'Sentinel-L1' -Name 'K8s-Internal' -StaticMacAddress $macPrivate | Out-Null
$nics = @(Get-VMNetworkAdapter -VMName $name)
$management = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' })
if ($nics.Count -ne 2 -or $management.Count -ne 1) { throw 'BLOCKED: created NIC topology unexpected; do not boot' }
Set-VMNetworkAdapter -VMNetworkAdapter $management[0] -StaticMacAddress $macManagement
$nics = @(Get-VMNetworkAdapter -VMName $name)
if (@($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $macManagement }).Count -ne 1 -or
    @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $macPrivate }).Count -ne 1) {
    throw 'BLOCKED: VM NIC identity does not match plan; do not boot'
}
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1 -or (Get-VM -Name $name).AutomaticCheckpointsEnabled) {
    throw 'BLOCKED: unsafe disk or automatic checkpoint; do not boot'
}
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema=2; purpose='sentinel-stage54-disposable-bootstrap'; node=$name;
    privateIP=$ip; vmId=[string]$vm.Id; nonce=$nonce;
    managementMAC=$macManagement; privateMAC=$macPrivate;
    sourceImageSHA256=$ImageSHA256.ToLowerInvariant();
    kubernetesInstall=$false; createdUtc=[datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $folder 'provisioning.json'),($manifest | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "STAGE54_VM_CREATED: $name VM-ID=$($vm.Id); public KVP host-key publication seeded before SSH."
Write-Host 'No SSH connection made; await KVP identity using Invoke-SentinelStage54Trust.ps1 -Mode VERIFY.'
 })
        if ($staleSlots.Count -ne 0) {
            throw 'BLOCKED: STAGE54_CLEANUP_REQUIRED: previous Stage54 disposable slot directory still exists'
        }
    }
    if (@(Get-VM -Name $name -ErrorAction SilentlyContinue).Count -ne 0 -or
        (Test-Path -LiteralPath $folder)) {
        throw 'BLOCKED: disposable slot already occupied; never adopt or overwrite existing VM'
    }
    Assert-ExistingStateRoot
    $switches = @(Get-VMSwitch -ErrorAction Stop | Select-Object -ExpandProperty Name)
    if ('Default Switch' -notin $switches -or 'Sentinel-L1' -notin $switches) {
        throw 'BLOCKED: required pre-existing switches missing; do not create/change switches'
    }
    $used = @(Get-VMNetworkAdapter -All -ErrorAction Stop |
        Where-Object { $_.MacAddress -in @($macManagement,$macPrivate) })
    if ($used.Count -ne 0) { throw 'BLOCKED: static MAC already allocated' }
    if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip }).Count -ne 0) {
        throw 'BLOCKED: disposable IP used by Windows host'
    }
    if (@(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ceq $ip -and $_.State -notin @('Incomplete','Unreachable') }).Count -ne 0) {
        throw 'BLOCKED: disposable IP seen in neighbour table'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([long]$os.FreePhysicalMemory * 1KB -lt 4GB) { throw 'BLOCKED: host RAM headroom below 4GiB' }
    if (-not (Get-Command Resize-VHD -ErrorAction SilentlyContinue) -or
        -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'BLOCKED: Hyper-V VHD/WSL tools unavailable'
    }
    foreach ($src in @($helper,$publisher,$setup)) {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "BLOCKED: bundled guest source missing: $src" }
    }
}
function Assert-Stage2Source {
    $image = (Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop).Path
    $parent = Split-Path $image -Parent
    $build = Split-Path $parent -Leaf
    $cache = Split-Path $parent -Parent
    if ([IO.Path]::GetFileName($image) -cne ($ImageSHA256.ToLowerInvariant()+'.img') -or
        $cache -cne 'C:\Sentinel\ImageCache\ubuntu\26.04' -or
        $build -cnotmatch '^20[0-9]{6}$') {
        throw 'BLOCKED: image outside approved Stage 2 SHA256 cache'
    }
    $sha = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
    if ($sha -cne $ImageSHA256.ToUpperInvariant()) { throw 'BLOCKED: image digest mismatch' }
    $sidecar = [IO.Path]::ChangeExtension($image,'.json')
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { throw 'BLOCKED: image sidecar missing' }
    $meta = Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceUrl = 'https://cloud-images.ubuntu.com/releases/26.04/release-' + $build + '/ubuntu-26.04-server-cloudimg-amd64.img'
    if ([string]$meta.sha256 -ine $sha -or [string]$meta.buildId -cne $build -or
        [string]$meta.sourceUrl -cne $sourceUrl -or
        [long]$meta.sizeBytes -ne (Get-Item -LiteralPath $image).Length) {
        throw 'BLOCKED: reviewed image source metadata mismatch'
    }
    return $image
}
Assert-NewSlot
$image = Assert-Stage2Source
$loginKeyFile = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $loginKeyFile -PathType Leaf)) { throw 'BLOCKED: SSH login public key missing' }
$loginKey = (Get-Content -LiteralPath $loginKeyFile -Raw -Encoding ASCII).Trim()
if ($loginKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or
    $loginKey.Contains([char]10)) {
    throw 'BLOCKED: invalid or multiple SSH login public keys'
}
Invoke-Helper -argsList @('check')
if ($Mode -eq 'PLAN') {
    Write-Host "STAGE54_CREATE_PLAN_READY: VM=$name IP=$ip MACs=$macManagement,$macPrivate; image SHA256 validated."
    Write-Host 'PLAN_ONLY: no VMs, disks, switches, trust stores or Ansible state changed.'
    Write-Host 'FIRSTBOOT_DEPENDENCY: guest needs signed APT access to install matching KVP tools; DNS failure blocks safely.'
    return
}
# The approval authorises a new cloud image and FIRST-BOOT publication only.
# No network-first SSH trust is required or permitted.
$nonceBytes = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($nonceBytes) } finally { $rng.Dispose() }
$nonce = ([BitConverter]::ToString($nonceBytes) -replace '-','').ToLowerInvariant()
$guestConfig = [ordered]@{schema=2;node=$name;ip=$ip;nonce=$nonce} | ConvertTo-Json -Compress
$guestPublisher = Get-Content -LiteralPath $publisher -Raw -Encoding UTF8
$guestSetup = Get-Content -LiteralPath $setup -Raw -Encoding UTF8
if (-not (Test-Path -LiteralPath $root)) { Protect-NewDirectory $root }
Protect-NewDirectory $folder
$userDataFile = Join-Path $folder 'user-data'
$metaDataFile = Join-Path $folder 'meta-data'
$networkFile = Join-Path $folder 'network-config'
$disk = Join-Path $folder 'os.vhdx'
$seed = Join-Path $folder 'seed.iso'
$configB64 = To-B64 $guestConfig
$publisherB64 = To-B64 $guestPublisher
$setupB64 = To-B64 $guestSetup
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
      - $loginKey
packages: [openssh-server]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /etc/sentinel/bootstrap.json
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: $configB64
  - path: /usr/local/lib/sentinel/publish_firstboot_kvp.py
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $publisherB64
  - path: /usr/local/sbin/sentinel-firstboot-kvp.sh
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: $setupB64
runcmd:
  - [systemctl, enable, --now, ssh]
  - [bash, /usr/local/sbin/sentinel-firstboot-kvp.sh]
"@
$m1 = ($macManagement.ToLowerInvariant() -replace '(..)(?=.)','$1:')
$m2 = ($macPrivate.ToLowerInvariant() -replace '(..)(?=.)','$1:')
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
    addresses: ['$ip/24']
"@
$nl = [string][char]10
$metaData = 'instance-id: ' + $name + '-' + [guid]::NewGuid().ToString('N') + $nl + 'local-hostname: ' + $name + $nl
foreach ($item in @(@($userDataFile,$userData),@($metaDataFile,$metaData),@($networkFile,$network))) {
    [IO.File]::WriteAllText([string]$item[0],[string]$item[1],[Text.UTF8Encoding]::new($false))
}
Invoke-Helper -argsList @('disk',(ConvertTo-SentinelWslMountPath $image),(ConvertTo-SentinelWslMountPath $disk))
Resize-VHD -Path $disk -SizeBytes (24GB)
Invoke-Helper -argsList @('seed',(ConvertTo-SentinelWslMountPath $userDataFile),(ConvertTo-SentinelWslMountPath $metaDataFile),(ConvertTo-SentinelWslMountPath $networkFile),(ConvertTo-SentinelWslMountPath $seed))
$vm = New-VM -Name $name -Generation 2 -Path $folder -VHDPath $disk -SwitchName 'Default Switch' -MemoryStartupBytes (2GB) -ErrorAction Stop
Set-VM -Name $name -AutomaticCheckpointsEnabled $false
Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes (2GB)
Set-VMProcessor -VMName $name -Count 2
Add-VMNetworkAdapter -VMName $name -SwitchName 'Sentinel-L1' -Name 'K8s-Internal' -StaticMacAddress $macPrivate | Out-Null
$nics = @(Get-VMNetworkAdapter -VMName $name)
$management = @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' })
if ($nics.Count -ne 2 -or $management.Count -ne 1) { throw 'BLOCKED: created NIC topology unexpected; do not boot' }
Set-VMNetworkAdapter -VMNetworkAdapter $management[0] -StaticMacAddress $macManagement
$nics = @(Get-VMNetworkAdapter -VMName $name)
if (@($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $macManagement }).Count -ne 1 -or
    @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $macPrivate }).Count -ne 1) {
    throw 'BLOCKED: VM NIC identity does not match plan; do not boot'
}
Add-VMDvdDrive -VMName $name -Path $seed | Out-Null
$hdd = @(Get-VMHardDiskDrive -VMName $name)
if ($hdd.Count -ne 1 -or (Get-VM -Name $name).AutomaticCheckpointsEnabled) {
    throw 'BLOCKED: unsafe disk or automatic checkpoint; do not boot'
}
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $hdd[0]
$manifest = [ordered]@{
    schema=2; purpose='sentinel-stage54-disposable-bootstrap'; node=$name;
    privateIP=$ip; vmId=[string]$vm.Id; nonce=$nonce;
    managementMAC=$macManagement; privateMAC=$macPrivate;
    sourceImageSHA256=$ImageSHA256.ToLowerInvariant();
    kubernetesInstall=$false; createdUtc=[datetime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText((Join-Path $folder 'provisioning.json'),($manifest | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
Start-VM -Name $name | Out-Null
Write-Host "STAGE54_VM_CREATED: $name VM-ID=$($vm.Id); public KVP host-key publication seeded before SSH."
Write-Host 'No SSH connection made; await KVP identity using Invoke-SentinelStage54Trust.ps1 -Mode VERIFY.'
