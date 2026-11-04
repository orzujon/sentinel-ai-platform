#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SentinelFreshNode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('control-plane','worker')][string]$Node)
    $name = if ($Node -eq 'control-plane') { 'cp01' } else { 'w01' }
    $suffix = if ($Node -eq 'control-plane') { '30' } else { '31' }
    [pscustomobject]@{
        Name=$name; Role=$Node; IP=('10.78.0.'+$suffix)
        ManagementMAC=('02AA780001'+$suffix); PrivateMAC=('02AA780000'+$suffix)
        Folder=('C:\Sentinel\FreshCluster\VMs\'+$name)
        PodCIDR='10.245.0.0/16'; ServiceCIDR='10.112.0.0/16'
    }
}

function Assert-SentinelFreshPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ine 'C:\Sentinel\FreshCluster' -and
        -not $full.StartsWith('C:\Sentinel\FreshCluster\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'BLOCKED: path outside fresh-cluster root'
    }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'BLOCKED: reparse point in fresh-cluster path ancestry'
            }
        }
        $current = Split-Path $current -Parent
    }
}

function Assert-SentinelFreshVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)]$NodeSpec)
    $expected = Get-SentinelFreshNode -Node $NodeSpec.Role
    if ($VM.Name -cne $expected.Name -or $NodeSpec.Folder -cne $expected.Folder) {
        throw 'BLOCKED: VM does not belong to the fixed fresh-cluster profile'
    }
    Assert-SentinelFreshPath -Path $expected.Folder
    $path = [IO.Path]::GetFullPath([string]$VM.Path).TrimEnd('\')
    if ($path -ine $expected.Folder -and
        -not $path.StartsWith($expected.Folder+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'BLOCKED: fresh VM configuration path changed'
    }
    $disks = @(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop)
    if ($disks.Count -ne 1 -or $disks[0].Path -ine ($expected.Folder+'\os.vhdx')) {
        throw 'BLOCKED: fresh VM disk identity changed'
    }
    $nics = @(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)
    if ($nics.Count -ne 2 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Default Switch' -and $_.MacAddress -ceq $expected.ManagementMAC }).Count -ne 1 -or
        @($nics | Where-Object { $_.SwitchName -ceq 'Sentinel-L1' -and $_.MacAddress -ceq $expected.PrivateMAC }).Count -ne 1) {
        throw 'BLOCKED: fresh VM NIC identity changed'
    }
    $manifestPath = $expected.Folder+'\provisioning.json'
    Assert-SentinelFreshPath -Path $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($manifest.schema -ne 3 -or $manifest.purpose -cne 'sentinel-fresh-cluster-v1' -or
        $manifest.node -cne $expected.Name -or $manifest.vmId -ine ([string]$VM.Id) -or
        $manifest.privateIP -cne $expected.IP -or $manifest.managementMAC -cne $expected.ManagementMAC -or
        $manifest.privateMAC -cne $expected.PrivateMAC) {
        throw 'BLOCKED: existing node is not independently bound to its fresh manifest'
    }
}

function Assert-SentinelFreshHost {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('control-plane','worker')][string]$Node, [switch]$ForCreation)
    $nodeSpec = Get-SentinelFreshNode -Node $Node
    Assert-SentinelFreshPath -Path $nodeSpec.Folder
    $vms = @(Get-VM -ErrorAction Stop)
    $switch = @(Get-VMSwitch -Name 'Sentinel-L1' -ErrorAction Stop)
    if ($switch.Count -ne 1 -or $switch[0].SwitchType -ne 'Internal') { throw 'BLOCKED: existing internal switch missing/drifted' }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
    if (@($addresses | Where-Object { $_.IPAddress -eq '10.78.0.1' -and $_.PrefixLength -eq 24 -and $_.InterfaceAlias -eq 'vEthernet (Sentinel-L1)' }).Count -ne 1) {
        throw 'BLOCKED: existing host interface differs from reviewed topology'
    }
    # Any non-default route covering either proposed overlay is a blocker.
    # Broader/private routes are rejected too, not only exact CIDR matches.
    foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)) {
        $parts = ([string]$route.DestinationPrefix).Split('/')
        $bits = [int]$parts[1]
        if ($bits -eq 0) { continue }
        $bytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $number = ([long]$bytes[0]*16777216)+([long]$bytes[1]*65536)+([long]$bytes[2]*256)+$bytes[3]
        $size = [long][math]::Pow(2,32-$bits)
        $start = [long]([math]::Floor($number/$size)*$size)
        $end = $start+$size-1
        foreach ($base in @('10.245.0.0','10.112.0.0')) {
            $b = [Net.IPAddress]::Parse($base).GetAddressBytes()
            $first = ([long]$b[0]*16777216)+([long]$b[1]*65536)
            if ($start -le ($first+65535) -and $first -le $end) { throw 'BLOCKED: host route overlaps proposed Kubernetes CIDRs' }
        }
    }
    if ($ForCreation) {
        if (@($addresses | Where-Object { $_.IPAddress -eq $nodeSpec.IP }).Count -gt 0) {
            throw 'BLOCKED: proposed node IP is assigned to the Windows host'
        }
        if (@($vms | Where-Object { $_.Name -ieq $nodeSpec.Name }).Count -gt 0 -or (Test-Path -LiteralPath $nodeSpec.Folder)) {
            throw 'BLOCKED: target exists; creation never adopts or overwrites partial state'
        }
        $peerRole = if ($Node -eq 'control-plane') { 'worker' } else { 'control-plane' }
        $peer = Get-SentinelFreshNode -Node $peerRole
        $peers = @($vms | Where-Object { $_.Name -ieq $peer.Name })
        if ($peers.Count -gt 1) { throw 'BLOCKED: ambiguous peer VM' }
        if ($peers.Count -eq 1) { Assert-SentinelFreshVM -VM $peers[0] -NodeSpec $peer }
        elseif (Test-Path -LiteralPath $peer.Folder) { throw 'BLOCKED: partial peer storage requires inspection' }
        $remaining = if ($peers.Count -eq 1) { 1 } else { 2 }
        $free = [long](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory*1KB
        if ($free -lt (($remaining*4GB)+6GB)) { throw 'BLOCKED: insufficient current RAM for remaining guests and 6 GiB host reserve' }
        if ([long](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining -lt (($remaining*60GB)+20GB)) {
            throw 'BLOCKED: insufficient disk capacity for remaining guests and reserve'
        }
        foreach ($nic in @(Get-VMNetworkAdapter -All -ErrorAction Stop)) {
            # -All can include management-OS adapters without IPAddresses.
            # Check MACs on every adapter; host IPs come from Get-NetIPAddress
            # above. Guest-reported addresses are supplementary observations,
            # not proof that an unreported address is available.
            $ipProperty = $nic.PSObject.Properties['IPAddresses']
            $observedIPs = @()
            if ($null -ne $ipProperty) { $observedIPs = @($ipProperty.Value) }
            if ($nic.MacAddress -in @($nodeSpec.ManagementMAC,$nodeSpec.PrivateMAC) -or $nodeSpec.IP -in $observedIPs) {
                throw 'BLOCKED: proposed IP or MAC belongs to an existing adapter'
            }
        }
    }
}

Export-ModuleMember -Function Get-SentinelFreshNode, Assert-SentinelFreshPath, Assert-SentinelFreshVM, Assert-SentinelFreshHost
