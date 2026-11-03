#Requires -Version 5.1
# Host capacity/collision behavior with EVERY host/filesystem query mocked.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.FreshCluster.psm1') -Force -PassThru
& $module {
    $script:TestVMs=@()
    $script:TestNics=@()
    $script:TestAddresses=@([pscustomobject]@{IPAddress='10.78.0.1';PrefixLength=24;InterfaceAlias='vEthernet (Sentinel-L1)'})
    $script:TestFreeMemory=14GB
    $script:TestFreeDisk=140GB
    $script:TestRoutes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/0'},[pscustomobject]@{DestinationPrefix='10.78.0.0/24'})
    function script:Test-Path { [CmdletBinding()]param($LiteralPath) return $false }
    function script:Get-VM { [CmdletBinding()]param() $script:TestVMs }
    function script:Get-VMNetworkAdapter { [CmdletBinding()]param([switch]$All) $script:TestNics }
    function script:Get-VMSwitch { [CmdletBinding()]param($Name) [pscustomobject]@{SwitchType='Internal'} }
    function script:Get-NetIPAddress { [CmdletBinding()]param($AddressFamily) $script:TestAddresses }
    function script:Get-NetRoute { [CmdletBinding()]param($AddressFamily) $script:TestRoutes }
    function script:Get-CimInstance { [CmdletBinding()]param($ClassName) [pscustomobject]@{FreePhysicalMemory=($script:TestFreeMemory/1KB)} }
    function script:Get-Volume { [CmdletBinding()]param($DriveLetter) [pscustomobject]@{SizeRemaining=$script:TestFreeDisk} }
    function Expect-Blocked([scriptblock]$Action) {
        try { & $Action } catch { if ($_.Exception.Message -notmatch 'BLOCKED') { throw }; return }
        throw 'Expected BLOCKED'
    }
    Assert-SentinelFreshHost -Node control-plane -ForCreation
    $script:TestFreeMemory=6.81GB
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestFreeMemory=14GB
    $script:TestFreeDisk=139GB
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestFreeDisk=140GB
    foreach ($prefix in @('10.245.0.0/16','10.112.5.0/24','10.0.0.0/8')) {
        $script:TestRoutes=@([pscustomobject]@{DestinationPrefix=$prefix})
        Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    }
    $script:TestRoutes=@([pscustomobject]@{DestinationPrefix='10.244.0.0/16'},[pscustomobject]@{DestinationPrefix='10.96.0.0/12'})
    Assert-SentinelFreshHost -Node control-plane -ForCreation
    $script:TestVMs=@([pscustomobject]@{Name='SENTINEL-FRESH-CP01'})
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestVMs=@()
    # Regression: -All includes management-OS adapters without IPAddresses.
    $script:TestNics=@([pscustomobject]@{MacAddress='FFFFFFFFFFFF';IsManagementOs=$true})
    Assert-SentinelFreshHost -Node control-plane -ForCreation
    $script:TestNics=@([pscustomobject]@{MacAddress='02AA78000030';IsManagementOs=$true})
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestNics=@([pscustomobject]@{MacAddress='FFFFFFFFFFFF';IPAddresses=$null})
    Assert-SentinelFreshHost -Node control-plane -ForCreation
    $script:TestAddresses += [pscustomobject]@{IPAddress='10.78.0.30';PrefixLength=24;InterfaceAlias='some-host-adapter'}
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestAddresses=@($script:TestAddresses | Where-Object { $_.IPAddress -ne '10.78.0.30' })
    $script:TestNics=@([pscustomobject]@{MacAddress='02AA78000030';IPAddresses=@()})
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
    $script:TestNics=@([pscustomobject]@{MacAddress='FFFFFFFFFFFF';IPAddresses=@('10.78.0.30')})
    Expect-Blocked { Assert-SentinelFreshHost -Node control-plane -ForCreation }
}
Remove-Module $module.Name
Write-Host 'PASS: mocked fresh host capacity, route overlap, occupied names, MAC and IP collisions'
