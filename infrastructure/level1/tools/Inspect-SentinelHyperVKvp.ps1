#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only Hyper-V KVP capability discovery for Sentinel's two pinned Ubuntu guests.
.DESCRIPTION
  Queries the host-side Hyper-V Data Exchange integration service and its
  guest-published custom key. Never connects over SSH, edits VMs, or writes trust.
  This is discovery ONLY: KVP data is guest-controlled and must be tied to a
  fresh provisioning instance before it can be accepted as identity attestation.
#>
[CmdletBinding()]
param(
    [ValidateSet('sentinel-l1-cp01','sentinel-l1-w01')]
    [string[]]$VMName = @('sentinel-l1-cp01','sentinel-l1-w01')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$namespace = 'root/virtualization/v2'
$keyName = 'Sentinel.SSHHostKey.Ed25519'
$expected = @{
    'sentinel-l1-cp01' = '10.78.0.10'
    'sentinel-l1-w01'  = '10.78.0.11'
}
$results = @()
foreach ($name in $VMName) {
    $record = [ordered]@{
        name = $name
        expectedIP = $expected[$name]
        result = 'UNAVAILABLE'
        vmId = $null
        kvpEnabled = $false
        publishedKeyPresent = $false
        reason = ''
        trustEstablished = $false
    }
    try {
        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
            throw 'Hyper-V management is unavailable'
        }
        $vm = Get-VM -Name $name -ErrorAction Stop
        if ($vm.State -ne 'Running') { throw 'VM is not running' }
        $record.vmId = [string]$vm.Id
        $services = @(Get-VMIntegrationService -VMName $name -ErrorAction Stop |
            Where-Object { $_.Name -eq 'Key-Value Pair Exchange' -or $_.Name -eq 'Data Exchange' })
        if ($services.Count -ne 1) { throw 'Hyper-V Data Exchange integration service was not uniquely identified' }
        $record.kvpEnabled = [bool]$services[0].Enabled
        if (-not $record.kvpEnabled) { throw 'Data Exchange integration is disabled' }
        $vmCim = @(Get-CimInstance -Namespace $namespace -ClassName Msvm_ComputerSystem -Filter ("Name='{0}'" -f $vm.Id))
        if ($vmCim.Count -ne 1) { throw 'VM ID not uniquely found via Hyper-V WMI' }
        $exchange = @(Get-CimAssociatedInstance -InputObject $vmCim[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
        if ($exchange.Count -ne 1) { throw 'Guest KVP exchange component not available' }
        $items = @($exchange[0].GuestExchangeItems)
        foreach ($xmlText in $items) {
            if (-not $xmlText) { continue }
            [xml]$entry = [string]$xmlText
            $key = $entry.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE")
            $value = $entry.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE")
            if ($null -ne $key -and $key.InnerText -ceq $keyName -and $null -ne $value -and $value.InnerText) {
                # Never export the reported key here: treat it as UNTRUSTED
                # until checked against independent provisioning evidence.
                $record.publishedKeyPresent = $true
            }
        }
        $record.result = 'INSPECTED'
        $record.reason = if ($record.publishedKeyPresent) {
            'Guest KVP identity evidence exists but is not independently authenticated'
        } else {
            'KVP channel accessible; no Sentinel host-key evidence has been published'
        }
    } catch {
        $record.reason = [string]$_.Exception.Message
    }
    $results += [pscustomobject]$record
}
$results | Format-Table name,result,kvpEnabled,publishedKeyPresent,reason -AutoSize -Wrap
Write-Host 'READ_ONLY: Hyper-V KVP capability inspection; no VM, SSH or trust changes.'
if (@($results | Where-Object { $_.result -ne 'INSPECTED' }).Count -gt 0) { exit 2 }
