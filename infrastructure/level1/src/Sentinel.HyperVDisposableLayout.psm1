#Requires -Version 5.1
# Pure, read-only validation of one exact Hyper-V VM configuration directory.
# No VM connections, no file changes. Used ONLY after the caller has matched
# the host-created provisioning manifest, VM.UUID and Hyper-V VM.Path.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SentinelHyperVConfigLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigDirectory,
        [Parameter(Mandatory)][guid]$ExpectedVMId
    )
    if ($ExpectedVMId -eq [guid]::Empty) {
        throw 'BLOCKED: expected VM configuration UUID must not be empty'
    }
    if (-not (Test-Path -LiteralPath $ConfigDirectory -PathType Container)) {
        throw 'BLOCKED: Hyper-V configuration directory missing'
    }
    $configItem = Get-Item -LiteralPath $ConfigDirectory -Force -ErrorAction Stop
    if (($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCKED: Hyper-V configuration folder is a symlink or reparse point'
    }

    $vmId = $ExpectedVMId.ToString('D')
    $validConfigFiles = @($vmId + '.vmcx', $vmId + '.vmrs', $vmId + '.vmgs')
    $configFiles = @(Get-ChildItem -LiteralPath $ConfigDirectory -Force -File -Filter '*.vmcx' -ErrorAction Stop)
    if ($configFiles.Count -ne 1 -or $configFiles[0].BaseName -ine $vmId) {
        Write-Host ("CLEANUP_CONFIG_FILE_CANDIDATES: {0}" -f
            (($configFiles | Select-Object -ExpandProperty Name) -join ','))
        throw 'BLOCKED: exact VM UUID .vmcx configuration file missing or duplicated'
    }

    # Hyper-V can create a VM-UUID-named runtime directory alongside the
    # GUID.vmcx, GUID.vmgs and GUID.vmrs files. Treat this as a candidate
    # ONLY if its name equals the independently verified host VM UUID.
    $configEntries = @(Get-ChildItem -LiteralPath $ConfigDirectory -Force -ErrorAction Stop)
    foreach ($entry in $configEntries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BLOCKED: reparse point inside Hyper-V configuration: $($entry.FullName)"
        }
        $valid = if ($entry.PSIsContainer) {
            $entry.Name -ieq $vmId
        } else {
            $entry.Name -in $validConfigFiles
        }
        if (-not $valid) {
            Write-Host ("CLEANUP_UNOWNED_CONFIG_ENTRY: {0}" -f $entry.FullName)
            throw 'BLOCKED: VM configuration includes unknown or foreign entries'
        }
    }

    $runtime = Join-Path $ConfigDirectory $vmId
    if (Test-Path -LiteralPath $runtime) {
        $runtimeItem = Get-Item -LiteralPath $runtime -Force -ErrorAction Stop
        if (-not $runtimeItem.PSIsContainer -or
            ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'BLOCKED: UUID runtime path is not a regular directory'
        }
        # Older Hyper-V configurations can leave VM-ID-named .bin/.vsv
        # runtime files here. No arbitrary names or further directories.
        $allowedRuntime = @($vmId + '.bin', $vmId + '.vsv')
        foreach ($entry in @(Get-ChildItem -LiteralPath $runtime -Force -ErrorAction Stop)) {
            if ($entry.PSIsContainer -or
                ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $entry.Name -notin $allowedRuntime) {
                Write-Host ("CLEANUP_UNRECOGNISED_RUNTIME_ENTRY: {0}" -f $entry.FullName)
                throw 'BLOCKED: UUID-named Hyper-V runtime directory contains unrecognised entries'
            }
        }
        Write-Host ("CLEANUP_VM_UUID_RUNTIME_VERIFIED: path={0}; vmId={1}" -f
            $runtime, $vmId)
    }
    Write-Host ("CLEANUP_VM_CONFIG_FILES_VERIFIED: vmId={0}; configPath={1}" -f
        $vmId, $ConfigDirectory)
    return 'VERIFIED'
}

Export-ModuleMember -Function Assert-SentinelHyperVConfigLayout
