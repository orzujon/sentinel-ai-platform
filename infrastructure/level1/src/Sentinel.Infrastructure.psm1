#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Stage3Specification {
    param([Parameter(Mandatory)][object]$Config)
    if ($Config.mode -cne 'isolated-sandbox' -or $Config.lab -cne 'sentinel-l1-sandbox') { throw 'Wrong lab/mode; isolated sandbox only.' }
    if (@($Config.vms).Count -ne 2) { throw 'Exactly two sandbox VMs are expected.' }
    if ([string]$Config.paths.vmRoot -cne 'C:\Sentinel\Level1-Sandbox\VMs') { throw 'VM root path outside dedicated sandbox.' }
    if ([string]$Config.network.switch -cne 'Sentinel-L1' -or [string]$Config.network.type -cne 'Internal') { throw 'Unexpected sandbox switch/type.' }
    if ([string]$Config.network.subnet -cne '10.78.0.0/24' -or [string]$Config.network.hostIP -cne '10.78.0.1') { throw 'Unexpected sandbox subnet/host IP.' }
    $names = @($Config.vms | ForEach-Object { [string]$_.name })
    $ips = @($Config.vms | ForEach-Object { [string]$_.staticIP })
    if (@($names | Select-Object -Unique).Count -ne 2 -or @($ips | Select-Object -Unique).Count -ne 2) { throw 'Duplicated VM name or IP.' }
    foreach ($vm in @($Config.vms)) {
        if ([string]$vm.name -notin @('sentinel-l1-cp01','sentinel-l1-w01')) { throw "Forbidden VM name: $($vm.name)" }
        if ([string]$vm.name -in @($Config.protection.vmNames)) { throw 'VM is protected by Stage 1.' }
        if ([string]$vm.staticIP -notin @('10.78.0.10','10.78.0.11')) { throw 'Unexpected sandbox IP.' }
        if ([int]$vm.virtualProcessors -ne 2 -or [int]$vm.memoryStartupGB -ne 4 -or [int]$vm.diskGB -ne 60) { throw 'VM allocations differ from reviewed Level 1 contract.' }
    }
    if (@($Config.protection.vmNames | Where-Object { $_ -eq 'k8s-cp01' }).Count -eq 0 -or @($Config.protection.vmNames | Where-Object { $_ -eq 'k8s-w01' }).Count -eq 0) {
        throw 'Existing protected VM list has been changed.'
    }
    if ([string]$Config.image.expectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Stage 2 approved SHA256 is missing.' }
    if ([string]$Config.image.buildId -notmatch '^20[0-9]{6}$' -or [string]$Config.image.fileName -cne 'ubuntu-26.04-server-cloudimg-amd64.img') { throw 'Unexpected image identity.' }
    $cacheRoot = [string]$Config.paths.imageCache
    if ($cacheRoot -cne 'C:\Sentinel\ImageCache') { throw 'Unexpected Stage 2 image cache location.' }
    $approvedDigest = ([string]$Config.image.expectedSha256).ToLowerInvariant()
    $expectedImage = Join-Path $cacheRoot ('ubuntu\26.04\' + [string]$Config.image.buildId + '\' + $approvedDigest + '.img')
    return [pscustomobject]@{ Vms = @($Config.vms); Switch = 'Sentinel-L1'; Network = '10.78.0.0/24'; HostIP = '10.78.0.1'; VMRoot = 'C:\Sentinel\Level1-Sandbox\VMs'; Image = $expectedImage; ExpectedHash = ([string]$Config.image.expectedSha256).ToLowerInvariant() }
}

function Test-Stage3RouteOverlap {
    param([string]$CIDR)
    if ($CIDR -eq '0.0.0.0/0') { return $false }
    $parts = $CIDR -split '/'
    if ($parts.Count -ne 2) { throw "Unparseable IPv4 route: $CIDR" }
    $addr = [System.Net.IPAddress]::Parse($parts[0])
    if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw "Non-IPv4 route: $CIDR" }
    $prefix = [int]$parts[1]
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "Invalid IPv4 route: $CIDR" }
    $bytes = $addr.GetAddressBytes()
    [double]$number = [double]$bytes[0]*16777216 + [double]$bytes[1]*65536 + [double]$bytes[2]*256 + [double]$bytes[3]
    [double]$span = [math]::Pow(2,32-$prefix)
    [double]$start = [math]::Floor($number/$span)*$span
    [double]$end = $start+$span-1
    [double]$target = 10*16777216 + 78*65536  # 10.78.0.0
    return ($start -le ($target+255) -and $target -le $end)
}

function Test-Stage3Tcp {
    param([string]$IP,[int]$Port=22,[int]$TimeoutMs=800)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $handle = $client.BeginConnect($IP, $Port, $null, $null)
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($handle)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

function Convert-Stage3WindowsPath {
    param([string]$WindowsPath,[string]$Distro)
    $output = & wsl.exe -d $Distro --exec wslpath -u $WindowsPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL path translation failed for $WindowsPath`: $output" }
    $result = ($output | Out-String).Trim()
    if ($result -notmatch '^/mnt/[a-z]/') { throw "Unexpected WSL path: $result" }
    return $result
}

function Invoke-Stage3WslTool {
    param([string]$Distro,[string]$ScriptPath,[string[]]$ToolArguments)
    $scriptLinux = Convert-Stage3WindowsPath $ScriptPath $Distro
    $translated = @()
    foreach ($arg in $ToolArguments) {
        if ($arg -match '^[A-Za-z]:\\') { $translated += (Convert-Stage3WindowsPath $arg $Distro) }
        else { $translated += $arg }
    }
    & wsl.exe -d $Distro --exec bash $scriptLinux @translated | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "WSL tool $($ToolArguments[0]) failed (exit code $LASTEXITCODE)." }
}

# SENTINEL_STAGE3_QUALITY_GATE_V2
Import-Module (Join-Path $PSScriptRoot 'Sentinel.GuestHealth.psm1') -Force -ErrorAction Stop

function Invoke-SentinelInfrastructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][ValidateSet('plan','apply','verify')][string]$Operation,
        [Parameter(Mandatory)][string]$ToolsPath,
        [string]$WSLDistro = 'Ubuntu-26.04'
    )
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    $started = [datetime]::UtcNow
    $events = Join-Path $RunDirectory 'events.jsonl'
    $report = Join-Path $RunDirectory 'infra.json'
    $steps = [System.Collections.Generic.List[object]]::new()
    $status = 'BLOCKED'
    $detail = ''
    $spec = $null
    function Record([string]$Task,[string]$State,[string]$Message) {
        $row = [pscustomobject]@{ utc=[datetime]::UtcNow.ToString('o'); task=$Task; status=$State; detail=$Message }
        $steps.Add($row)
        ($row | ConvertTo-Json -Compress) | Add-Content -LiteralPath $events -Encoding UTF8
        Write-Host ("[{0}] {1}: {2}" -f $State, $Task, $Message)
    }
    try {
        $spec = Assert-Stage3Specification $Config
        Record 'configuration' 'PASS' 'Strict sandbox allowlist matched.'
        if ($env:OS -ne 'Windows_NT') { throw 'Run from Windows PowerShell, not WSL.' }
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator PowerShell required for Stage 3.' }
        Import-Module Hyper-V -ErrorAction Stop
        [void](Get-VMHost -ErrorAction Stop)
        Record 'hyperv' 'PASS' 'Windows Hyper-V management available.'
        $vms = @(Get-VM -ErrorAction Stop)
        $switches = @(Get-VMSwitch -ErrorAction Stop)
        $existingSandboxVMs = @($vms | Where-Object { $_.Name -in @($spec.Vms | ForEach-Object {$_.name}) })
        $existingSandboxSwitch = @($switches | Where-Object { $_.Name -eq $spec.Switch })
        # Locally administered, static MACs avoid any first-boot dynamic-MAC ambiguity.
        $macLayout = @{
            'sentinel-l1-cp01' = @{ management = '02AA78000110'; private = '02AA78000010' }
            'sentinel-l1-w01'  = @{ management = '02AA78000111'; private = '02AA78000011' }
        }
        if (@($switches | Where-Object { $_.Name -eq 'Default Switch' }).Count -ne 1) { throw 'Hyper-V Default Switch is required for guest DHCP/Internet.' }
        if ($Operation -eq 'verify') {
            if ($existingSandboxVMs.Count -ne 2 -or $existingSandboxSwitch.Count -ne 1) { throw 'Sandbox VMs or switch missing.' }
            if ([string]$existingSandboxSwitch[0].SwitchType -ne 'Internal') { throw 'Sandbox switch is not internal.' }
            $hostIP = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (Sentinel-L1)' -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq '10.78.0.1' -and $_.PrefixLength -eq 24 })
            if ($hostIP.Count -ne 1) { throw 'Sandbox host IPv4 configuration missing or incorrect.' }
            $expectedPrefix = ($spec.VMRoot.TrimEnd('\') + '\')
            foreach ($vm in $spec.Vms) {
                $found = @($existingSandboxVMs | Where-Object { $_.Name -eq $vm.name })
                if ($found.Count -ne 1 -or (-not $found[0].Path.StartsWith($expectedPrefix,[System.StringComparison]::OrdinalIgnoreCase))) { throw "Unexpected VM identity or path: $($vm.name)" }
                $nics = @(Get-VMNetworkAdapter -VM $found[0])
                if (@($nics | Where-Object { $_.SwitchName -eq 'Sentinel-L1' }).Count -ne 1) { throw "Missing sandbox NIC: $($vm.name)" }
                if ($found[0].State -ne 'Running') { throw "VM not running: $($vm.name)" }
                Record 'vm-status' 'PASS' "$($vm.name) VM running, sandbox network adapter present."
            }
            foreach ($vm in $spec.Vms) {
                if (-not (Test-Stage3Tcp $vm.staticIP 22)) { throw "SSH TCP not reachable at $($vm.staticIP):22 (may still be booting)." }
                Record 'ssh-tcp' 'PASS' "TCP port 22 reachable on $($vm.staticIP). Authentication not tested."
            }
            $status = 'READY'; $detail = 'Both new sandbox guests are running and SSH TCP responds.'
        }
        else {
            if ($existingSandboxVMs.Count -ne 0) { throw 'Sandbox VM name already exists. Refusing to adopt, overwrite or delete an existing VM.' }
            if ($existingSandboxSwitch.Count -ne 0) { throw 'Sandbox switch already exists. Refusing automatic adoption after partial provisioning.' }
            $existingMacs = @(Get-VMNetworkAdapter -All -ErrorAction Stop | ForEach-Object { [string]$_.MacAddress })
            $plannedMacs = @($macLayout['sentinel-l1-cp01'].management,$macLayout['sentinel-l1-cp01'].private,$macLayout['sentinel-l1-w01'].management,$macLayout['sentinel-l1-w01'].private)
            if (@($existingMacs | Where-Object { $_ -in $plannedMacs }).Count -gt 0) { throw 'Proposed sandbox static MAC address already in use on Hyper-V host.' }
            foreach ($vm in $spec.Vms) {
                if (Test-Path -LiteralPath (Join-Path $spec.VMRoot $vm.name)) { throw "Existing VM directory found: $($vm.name). Refusing overwrite." }
            }
            $relatedRoutes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object { Test-Stage3RouteOverlap ([string]$_.DestinationPrefix) })
            if ($relatedRoutes.Count -gt 0) { throw ('Route overlap with 10.78.0.0/24: ' + (($relatedRoutes | ForEach-Object { $_.DestinationPrefix }) -join ', ')) }
            Record 'resource-collisions' 'PASS' 'No sandbox VM, switch, directory or exact-subnet route collision.'
            if (-not (Test-Path -LiteralPath $spec.Image -PathType Leaf)) { throw "Stage 2 verified image cache missing: $($spec.Image)" }
            $actual = (Get-FileHash -LiteralPath $spec.Image -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actual -ne $spec.ExpectedHash) { throw 'Stage 2 cached image SHA256 mismatch. Do not use it.' }
            Record 'image-hash' 'PASS' 'Cached image matches the approved SHA256.'
            $pubPath = Join-Path $HOME '.ssh\id_ed25519.pub'
            if (-not (Test-Path -LiteralPath $pubPath -PathType Leaf)) { throw "SSH public key missing: $pubPath" }
            $pubkey = (Get-Content -LiteralPath $pubPath -Raw).Trim()
            if ($pubkey -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( [^\r\n]*)?$' -or $pubkey.Contains("`n")) { throw 'Expected a single-line valid-format SSH ed25519 public key.' }
            Record 'ssh-public-key' 'PASS' 'Windows SSH public key available; no private key is copied into guests.'
            if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is unavailable.' }
            $script = Join-Path $ToolsPath 'prepare-disk-and-seed.sh'
            if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "WSL helper missing: $script" }
            Invoke-Stage3WslTool -Distro $WSLDistro -ScriptPath $script -ToolArguments @('check')
            Record 'wsl-tools' 'PASS' "$WSLDistro provides qemu-img and cloud-localds."
            $os = Get-CimInstance Win32_OperatingSystem
            $free = [double]$os.FreePhysicalMemory / 1MB
            $required = [double](($spec.Vms | Measure-Object -Property memoryStartupGB -Sum).Sum) + [double]$Config.capacity.hostRAMReserveGB
            if ($free -lt $required) { throw "Host free RAM ${free} GiB < required ${required} GiB. Shut down other workloads yourself and rerun plan." }
            Record 'ram-budget' 'PASS' "Free RAM $([math]::Round($free,2)) GiB >= $required GiB startup+reserve."
            $driveRoot = [System.IO.Path]::GetPathRoot($spec.VMRoot)
            $drive = [System.IO.DriveInfo]::new($driveRoot)
            $freeDisk = [double]$drive.AvailableFreeSpace / 1GB
            $budget = [double](($spec.Vms | Measure-Object -Property diskGB -Sum).Sum) + [double]$Config.capacity.diskReserveGB
            if ($freeDisk -lt $budget) { throw "Disk free $([math]::Round($freeDisk,2)) GiB < conservative budget $budget GiB." }
            Record 'disk-budget' 'PASS' "Free disk $([math]::Round($freeDisk,2)) GiB >= $budget GiB conservative budget."
            if ($Operation -eq 'plan') {
                $status = 'READY'; $detail = 'Read-only plan passed. No resources were changed.'
            }
            else {
                $confirmation = Read-Host 'Type CREATE SENTINEL-L1 to create exactly two NEW sandbox VMs'
                if ($confirmation -cne 'CREATE SENTINEL-L1') { throw 'User did not approve provisioning.' }
                # Build disks first. Existing working VMs have not been read or changed beyond inventory checks.
                foreach ($vm in $spec.Vms) {
                    $dir = Join-Path $spec.VMRoot $vm.name
                    [void](New-Item -ItemType Directory -Path $dir -Force)
                    $disk = Join-Path $dir 'os.vhdx'
                    Invoke-Stage3WslTool -Distro $WSLDistro -ScriptPath $script -ToolArguments @('disk',$spec.Image,$disk)
                    Resize-VHD -Path $disk -SizeBytes ([uint64]$vm.diskGB * 1GB) -ErrorAction Stop
                    Record 'vm-disk' 'PASS' "$($vm.name): verified source converted into a private dynamic 60 GB VHDX."
                }
                [void](New-VMSwitch -Name $spec.Switch -SwitchType Internal -ErrorAction Stop)
                $alias = 'vEthernet (' + $spec.Switch + ')'
                $attempts = 0
                while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) -and $attempts++ -lt 20) { Start-Sleep -Milliseconds 400 }
                if (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) { throw 'Host internal adapter did not appear.' }
                [void](New-NetIPAddress -InterfaceAlias $alias -IPAddress $spec.HostIP -PrefixLength 24 -ErrorAction Stop)
                Record 'hyperv-switch' 'PASS' "Created $($spec.Switch) internal switch, host $($spec.HostIP)/24."
                foreach ($vm in $spec.Vms) {
                    $dir = Join-Path $spec.VMRoot $vm.name
                    $disk = Join-Path $dir 'os.vhdx'
                    $existing = @(Get-VM -Name $vm.name -ErrorAction SilentlyContinue)
                    if ($existing.Count -ne 0) { throw "Target VM appeared unexpectedly: $($vm.name)." }
                    $newVM = New-VM -Name $vm.name -Generation 2 -MemoryStartupBytes ([uint64]$vm.memoryStartupGB * 1GB) -VHDPath $disk -Path $dir -SwitchName 'Default Switch' -ErrorAction Stop
                    Set-VMMemory -VMName $vm.name -DynamicMemoryEnabled $false -StartupBytes ([uint64]$vm.memoryStartupGB * 1GB)
                    [void](Set-VMProcessor -VM $newVM -Count ([int]$vm.virtualProcessors))
                    [void](Add-VMNetworkAdapter -VM $newVM -SwitchName $spec.Switch -Name 'K8s-Internal' -StaticMacAddress $macLayout[$vm.name].private)
                    $nicMgmt = @(Get-VMNetworkAdapter -VM $newVM | Where-Object { $_.SwitchName -eq 'Default Switch' })
                    $nicLab = @(Get-VMNetworkAdapter -VM $newVM | Where-Object { $_.SwitchName -eq $spec.Switch })
                    if ($nicMgmt.Count -ne 1 -or $nicLab.Count -ne 1) { throw "Unexpected NIC layout for $($vm.name)." }
                    Set-VMNetworkAdapter -VMNetworkAdapter $nicMgmt[0] -StaticMacAddress $macLayout[$vm.name].management
                    # Cloud-init matches the explicit stable MACs; no first-boot guesswork.
                    $m1 = $macLayout[$vm.name].management.ToLowerInvariant() -replace '(..)(?=.)','$1:'
                    $m2 = $macLayout[$vm.name].private.ToLowerInvariant() -replace '(..)(?=.)','$1:'
                    $userPath = Join-Path $dir 'user-data'
                    $metaPath = Join-Path $dir 'meta-data'
                    $networkPath = Join-Path $dir 'network-config'
                    $seed = Join-Path $dir 'seed.iso'
                    # Only a public SSH key is placed in cloud-init. Do not write a private key or password.
                    $userData = @"
#cloud-config
hostname: $($vm.name)
manage_etc_hosts: true
disable_root: true
ssh_pwauth: false
users:
  - name: orzu
    lock_passwd: true
    shell: /bin/bash
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - $pubkey
packages: [openssh-server]
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
runcmd:
  - [systemctl, enable, --now, ssh]
"@
                    $meta = "instance-id: $($vm.name)-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: $($vm.name)`n"
                    $net = @"
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
      - '$($vm.staticIP)/24'
"@
                    [System.IO.File]::WriteAllText($userPath,$userData,[System.Text.UTF8Encoding]::new($false))
                    [System.IO.File]::WriteAllText($metaPath,$meta,[System.Text.UTF8Encoding]::new($false))
                    [System.IO.File]::WriteAllText($networkPath,$net,[System.Text.UTF8Encoding]::new($false))
                    Invoke-Stage3WslTool -Distro $WSLDistro -ScriptPath $script -ToolArguments @('seed',$userPath,$metaPath,$networkPath,$seed)
                    [void](Add-VMDvdDrive -VM $newVM -Path $seed)
                    $hdd = @(Get-VMHardDiskDrive -VM $newVM)
                    if ($hdd.Count -ne 1) { throw 'Unexpected number of VM hard disks.' }
                    Set-VMFirmware -VM $newVM -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -FirstBootDevice $hdd[0]
                    Record 'vm-registration' 'PASS' "$($vm.name) registered with distinct MACs, cloud-init seed and secure boot."
                }
                foreach ($vm in $spec.Vms) { [void](Start-VM -Name $vm.name); Record 'vm-start' 'PASS' "Started $($vm.name)" }
                $deadline = (Get-Date).AddMinutes(6)
                foreach ($vm in $spec.Vms) {
                    while ((Get-Date) -lt $deadline -and -not (Test-Stage3Tcp $vm.staticIP 22 1000)) { Start-Sleep -Seconds 5 }
                    if (-not (Test-Stage3Tcp $vm.staticIP 22 1000)) { throw "VM started, but SSH not yet reachable: $($vm.name) $($vm.staticIP). Inspect Hyper-V console and cloud-init logs." }
                    Record 'vm-ssh' 'PASS' "$($vm.name): SSH TCP reachable on $($vm.staticIP):22."
                }
                $status = 'READY'; $detail = 'Provisioned two isolated Ubuntu VMs; SSH TCP is reachable. Ansible and Kubernetes are Stage 4+.'
            }
        }
    }
    catch {
        $detail = $_.Exception.Message
        Record 'failure' 'BLOCK' $detail
        $status = 'BLOCKED'
    }
    finally {
        # SENTINEL_STAGE3_GUEST_HEALTH_V2
        # A prior TCP-only READY is provisional until every guest passes these checks.
        if ($status -eq 'READY' -and $Operation -in @('verify','apply')) {
            try {
                foreach ($vm in $spec.Vms) {
                    $ram = Get-VMMemory -VMName $vm.name -ErrorAction Stop
                    $guestVM = Get-VM -Name $vm.name -ErrorAction Stop
                    if ($ram.DynamicMemoryEnabled -or [uint64]$ram.Startup -ne 4GB -or [uint64]$guestVM.MemoryAssigned -lt (4GB - 64MB)) {
                        throw "VM $($vm.name): expected 4 GiB fixed RAM, with Dynamic Memory disabled."
                    }
                    Record 'vm-memory' 'PASS' "$($vm.name): 4 GiB fixed RAM verified."
                    $guest = Assert-SentinelGuestHealth -VMName $vm.name -IPAddress $vm.staticIP
                    Record 'guest-health' 'PASS' "$($guest.VMName): SSH authenticated, hostname verified, cloud-init done, sudo available, guest RAM $($guest.MemoryKiB) KiB."
                }
                $detail = 'Both sandbox guests passed fixed memory and authenticated SSH/cloud-init/sudo health checks.'
            }
            catch {
                $status = 'BLOCKED'
                $detail = 'Guest quality gate failed: ' + $_.Exception.Message
                Record 'guest-health' 'BLOCK' $detail
            }
        }
        $ended = [datetime]::UtcNow
        $data = [ordered]@{
            schemaVersion='1.0'; stage='30-40-hyperv-provision'; operation=$Operation
            runId=(Split-Path $RunDirectory -Leaf); startedUtc=$started.ToString('o'); finishedUtc=$ended.ToString('o')
            durationSeconds=[math]::Round(($ended-$started).TotalSeconds,3); result=$status; reason=$detail
            vmNames=@('sentinel-l1-cp01','sentinel-l1-w01'); protectedVmNames=@('k8s-cp01','k8s-w01')
            steps=@($steps.ToArray()); reportVersion='1.0'
        }
        ($data | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $report -Encoding UTF8
        Record 'stage-end' $status $detail
    }
    return [pscustomobject]@{Result=$status;Reason=$detail;ReportPath=$report;Steps=@($steps.ToArray())}
}
Export-ModuleMember -Function Invoke-SentinelInfrastructure, Assert-Stage3Specification
