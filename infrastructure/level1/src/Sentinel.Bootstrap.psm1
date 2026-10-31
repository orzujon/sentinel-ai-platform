#Requires -Version 5.1
# Level 1 Stage 5: non-mutating orchestration preflight. No VM operations.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SentinelBootstrapRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ExpectedVMNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExistingVMNames,
        [Parameter(Mandatory)][bool]$ExpectedSwitchExists,
        [Parameter(Mandatory)][bool]$ExpectedVMRootExists
    )
    $expected = @($ExpectedVMNames | Sort-Object -Unique)
    $present = @($ExistingVMNames | Where-Object { $_ -in $expected } | Sort-Object -Unique)
    if ($expected.Count -ne 2 -or $expected[0] -cne 'sentinel-l1-cp01' -or $expected[1] -cne 'sentinel-l1-w01') {
        throw 'BLOCKED: bootstrap routing only supports the pinned two-node sandbox'
    }
    if ($present.Count -eq 2 -and $ExpectedSwitchExists) { return 'verify-existing' }
    if ($present.Count -eq 0 -and -not $ExpectedSwitchExists -and -not $ExpectedVMRootExists) { return 'new-sandbox' }
    return 'blocked-partial'
}

function Invoke-SentinelBootstrapPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $started = [datetime]::UtcNow
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    $reportPath = Join-Path $RunDirectory 'bootstrap-plan.json'
    $route = 'blocked'
    $message = ''
    $stages = @(
        [pscustomobject]@{ id='00-preflight'; action='inspect-host'; implemented=$true },
        [pscustomobject]@{ id='20-image-cache'; action='verify-locked-image'; implemented=$true },
        [pscustomobject]@{ id='30-50-hyperv-guests'; action='verify-or-create-approved-only'; implemented=$true },
        [pscustomobject]@{ id='60-linux-baseline'; action='separate-stage4-operator'; implemented=$false },
        [pscustomobject]@{ id='70-kubernetes-bootstrap'; action='separate-stage4-operator'; implemented=$false },
        [pscustomobject]@{ id='80-validate'; action='existing-reconciler-on-joined-cluster'; implemented=$true },
        [pscustomobject]@{ id='90-publish'; action='aggregate-future-run'; implemented=$false }
    )
    try {
        if ($Config.lab -cne 'sentinel-l1-sandbox' -or $Config.mode -cne 'isolated-sandbox') {
            throw 'Only the dedicated isolated Sentinel sandbox is permitted'
        }
        if ([string]$Config.network.switch -cne 'Sentinel-L1' -or [string]$Config.network.type -cne 'Internal') {
            throw 'Lab switch contract does not match the protected provisioning profile'
        }
        if ([string]$Config.paths.vmRoot -cne 'C:\Sentinel\Level1-Sandbox\VMs') {
            throw 'Sandbox VM storage path changed'
        }
        $expected = @($Config.vms | ForEach-Object { [string]$_.name })
        if ($expected.Count -ne 2 -or @($expected | Where-Object { $_ -in @($Config.protection.vmNames) }).Count -gt 0) {
            throw 'Expected VM inventory conflicts with protection list'
        }
        if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue) -or -not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) {
            throw 'Hyper-V management commands unavailable; run from Windows with Hyper-V enabled'
        }
        $allVMs = @(Get-VM -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        $switches = @(Get-VMSwitch -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        $route = Get-SentinelBootstrapRoute -ExpectedVMNames $expected -ExistingVMNames $allVMs -ExpectedSwitchExists ($switches -contains 'Sentinel-L1') -ExpectedVMRootExists (Test-Path -LiteralPath $Config.paths.vmRoot)
        if ($route -eq 'blocked-partial') {
            throw 'Partial sandbox detected; no automatic adoption, reset or destructive replacement permitted'
        }
        if ($route -eq 'new-sandbox') {
            $message = 'Clean sandbox route: image, host prerequisites, explicit Hyper-V provisioning approval, guest trust and fresh Kubernetes bootstrap remain separate operations'
        } else {
            $message = 'Existing sandbox route: verify VMs, SSH identity and Kubernetes desired-state; never run VM creation or kubeadm init against joined nodes'
        }
    } catch {
        $message = [string]$_.Exception.Message
        $route = 'blocked'
    }
    $outcome = if ($route -eq 'blocked') { 'BLOCKED' } else { 'PLANNED' }
    $record = [ordered]@{
        schemaVersion = 1
        stage = 'level1-stage5'
        runId = Split-Path $RunDirectory -Leaf
        startedUtc = $started.ToString('o')
        completedUtc = [datetime]::UtcNow.ToString('o')
        sourceConfig = [IO.Path]::GetFileName($ConfigPath)
        result = $outcome
        route = $route
        reason = $message
        guestMutation = $false
        completeBootstrapSupported = $false
        stages = $stages
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    return [pscustomobject]@{ Result=$outcome; Route=$route; Reason=$message; ReportPath=$reportPath }
}
Export-ModuleMember -Function Invoke-SentinelBootstrapPlan, Get-SentinelBootstrapRoute
