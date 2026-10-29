#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
  Starts, stops, or inspects the existing Sentinel Kubernetes lab VMs.
.DESCRIPTION
  This is lifecycle management of EXISTING VMs, not a fresh cluster deployment.
  Start: starts cp01 and w01, then verifies both Kubernetes nodes are Ready.
  Stop: requests guest OS shutdown on worker first, then control plane.
  Status: shows VM allocations and (if possible) Kubernetes nodes.
  Never calls Remove-VM, kubeadm reset, or deletes disks.
.EXAMPLE
  .\Sentinel-Lab.ps1 Start
.EXAMPLE
  .\Sentinel-Lab.ps1 Stop -ShutdownWSL
.EXAMPLE
  .\Sentinel-Lab.ps1 Status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Status')]
    [string] $Action,

    [switch] $ShutdownWSL,

    [ValidateRange(30, 1800)]
    [int] $TimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedNodes = [ordered]@{
    'k8s-cp01' = '10.77.0.10'
    'k8s-w01'  = '10.77.0.11'
}

if ($Action -ne 'Stop' -and $ShutdownWSL) {
    throw '-ShutdownWSL is only supported with the Stop action.'
}

# Resolve each VM by its unique Hyper-V ID. Never operate on ambiguous names.
$vms = @{}
foreach ($name in $expectedNodes.Keys) {
    $found = @(Get-VM -Name $name -ErrorAction SilentlyContinue)
    if ($found.Count -ne 1) {
        throw "Expected exactly one VM named '$name', found $($found.Count). No changes made."
    }
    $vms[$name] = $found[0]
}

function Get-SentinelKubeconfig {
    $candidates = @(
        (Join-Path $HOME '.kube\sentinel-admin.conf'),
        (Join-Path $HOME '.kube\config')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Test-SentinelKubernetesReady {
    param([string] $Kubeconfig)
    try {
        $raw = & kubectl "--kubeconfig=$Kubeconfig" get nodes -o json 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $cluster = (($raw -join "`n") | ConvertFrom-Json)
        foreach ($name in $expectedNodes.Keys) {
            $found = @($cluster.items | Where-Object { $_.metadata.name -eq $name })
            if ($found.Count -ne 1) { return $false }
            $ready = @($found[0].status.conditions | Where-Object {
                $_.type -eq 'Ready' -and $_.status -eq 'True'
            })
            if ($ready.Count -eq 0) { return $false }
            $ips = @($found[0].status.addresses | Where-Object {
                $_.type -eq 'InternalIP'
            } | ForEach-Object { $_.address })
            if ($expectedNodes[$name] -notin $ips) { return $false }
        }
        return $true
    }
    catch { return $false }
}

switch ($Action) {
    'Status' {
        foreach ($name in $expectedNodes.Keys) {
            $vm = Get-VM -Id $vms[$name].Id
            [pscustomobject]@{
                Name        = $vm.Name
                State       = $vm.State.ToString()
                MemoryGB    = [math]::Round($vm.MemoryAssigned / 1GB, 2)
                ExpectedIP  = $expectedNodes[$name]
            }
        }
        $config = Get-SentinelKubeconfig
        if ($config -and (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Host "`nKubernetes node status:"
            & kubectl "--kubeconfig=$config" get nodes -o wide
        }
        else {
            Write-Warning 'kubectl or local kubeconfig not found. VM status is shown; Kubernetes readiness not checked.'
        }
    }

    'Stop' {
        # Stop worker first, control plane last; do not hard-power-off either VM.
        foreach ($name in @('k8s-w01', 'k8s-cp01')) {
            $vm = Get-VM -Id $vms[$name].Id
            if ($vm.State.ToString() -eq 'Off') {
                Write-Host "Already off: $name"
            }
            elseif ($vm.State.ToString() -eq 'Running') {
                Write-Host "Gracefully shutting down $name ..."
                Stop-VM -VM $vm -Confirm:$false
            }
            else {
                Write-Warning "Skipping $name in state $($vm.State). Manual inspection may be needed."
            }
        }
        if ($ShutdownWSL) {
            Write-Host 'Stopping all WSL distributions (including Docker Desktop if running)...'
            & wsl.exe --shutdown
            if ($LASTEXITCODE -ne 0) { Write-Warning 'WSL shutdown returned a non-zero exit code.' }
        }
        Write-Host 'Shutdown requests completed. VM disks and Kubernetes state were not deleted.'
        foreach ($name in $expectedNodes.Keys) {
            $vm = Get-VM -Id $vms[$name].Id
            Write-Host ('{0}: {1}' -f $name, $vm.State)
        }
    }

    'Start' {
        foreach ($name in @('k8s-cp01', 'k8s-w01')) {
            $vm = Get-VM -Id $vms[$name].Id
            if ($vm.State.ToString() -eq 'Running') {
                Write-Host "Already running: $name"
            }
            elseif ($vm.State.ToString() -in @('Off', 'Saved')) {
                Write-Host "Starting $name ..."
                Start-VM -VM $vm
            }
            else {
                throw "Cannot safely start '$name' from state $($vm.State)."
            }
        }

        $config = Get-SentinelKubeconfig
        if (-not $config -or -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            Write-Warning 'VMs started, but kubectl or kubeconfig is missing. Kubernetes readiness was not verified.'
            break
        }

        Write-Host "Waiting up to $TimeoutSeconds seconds for BOTH nodes to become Ready with expected IP addresses..."
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $verified = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-SentinelKubernetesReady -Kubeconfig $config) {
                $verified = $true
                break
            }
            Start-Sleep -Seconds 5
        }
        if (-not $verified) {
            Write-Warning 'VMs started, but the Kubernetes Ready check did not pass before the deadline.'
            Write-Host 'Inspect: kubectl get nodes -o wide; kubectl get pods -A'
            throw 'Cluster readiness not confirmed. No resources were deleted.'
        }
        Write-Host 'Cluster Ready: k8s-cp01 (10.77.0.10), k8s-w01 (10.77.0.11)'
        & kubectl "--kubeconfig=$config" get nodes -o wide
    }
}
