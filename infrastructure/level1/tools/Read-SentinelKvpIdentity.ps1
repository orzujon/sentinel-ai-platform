#Requires -Version 5.1
<#
.SYNOPSIS
  Collect and validate a guest-published Hyper-V KVP SSH identity report.
.DESCRIPTION
  Strictly read-only. The manifest must be produced independently by the
  provisioner, not copied from guest-published KVP data. Never touches SSH
  known_hosts, guest files, VM settings or networking.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ManifestPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.KvpEvidence.psm1') -Force
$manifestFile = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
if ((Get-Item -LiteralPath $manifestFile).Length -gt 8192) { throw 'BLOCKED: provisioning manifest is oversized' }
$manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = @($manifest.vms)
if ([int]$manifest.schema -ne 1 -or $entries.Count -ne 2 -or
    (@($entries | ForEach-Object { [string]$_.node } | Sort-Object) -join ',') -cne 'sentinel-l1-cp01,sentinel-l1-w01') {
    throw 'BLOCKED: require an exact two-guest provisioning manifest'
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'BLOCKED: Hyper-V management unavailable' }

$results = @()
foreach ($entry in $entries) {
    $node = [string]$entry.node
    $vm = Get-VM -Name $node -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "BLOCKED: VM is not running: $node" }
    $service = @(Get-VMIntegrationService -VMName $node -ErrorAction Stop |
        Where-Object { $_.Name -in @('Key-Value Pair Exchange','Data Exchange') })
    if ($service.Count -ne 1 -or -not $service[0].Enabled) { throw "BLOCKED: KVP is not enabled for $node" }
    # Binding must start with the actual Hyper-V VM UUID.
    $actualId = [string]$vm.Id
    $system = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter ("Name='{0}'" -f $actualId))
    if ($system.Count -ne 1) { throw "BLOCKED: cannot resolve Hyper-V VM identity for $node" }
    $exchange = @(Get-CimAssociatedInstance -InputObject $system[0] -ResultClassName Msvm_KvpExchangeComponent -ErrorAction Stop)
    if ($exchange.Count -ne 1) { throw "BLOCKED: guest KVP component unavailable for $node" }
    $data = ConvertFrom-SentinelKvpXml -Items @($exchange[0].GuestExchangeItems)
    # Emit one structured record per VM, with no private nonce in output.
    $results += Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $actualId -GuestData $data
}
if (@($results | Select-Object -ExpandProperty fingerprint | Sort-Object -Unique).Count -ne 2) {
    throw 'BLOCKED: two VMs cannot share an SSH host identity'
}
$results | Select-Object node,ip,vmId,fingerprint,result,trusted | Format-Table -AutoSize
Write-Host 'EVIDENCE_ONLY: KVP identities matched the supplied provisioning manifest; no SSH trust established.'
Write-Host 'No VMs, SSH settings, KVP pools or known_hosts files were modified.'
