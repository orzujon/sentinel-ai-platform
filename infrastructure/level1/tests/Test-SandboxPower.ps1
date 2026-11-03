#Requires -Version 5.1
# Function mocks intercept all VM actions; no Hyper-V module is imported.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tool=Join-Path $PSScriptRoot '..\tools\Invoke-SentinelSandboxPower.ps1'
$cp=[guid]::NewGuid(); $worker=[guid]::NewGuid()
$global:SentinelPowerFixture=@{
    'sentinel-l1-cp01'=[pscustomobject]@{Name='sentinel-l1-cp01';Id=$cp;State='Running';Path='C:\Sentinel\Level1-Sandbox\VMs\sentinel-l1-cp01';MemoryAssigned=4GB}
    'sentinel-l1-w01'=[pscustomobject]@{Name='sentinel-l1-w01';Id=$worker;State='Running';Path='C:\Sentinel\Level1-Sandbox\VMs\sentinel-l1-w01';MemoryAssigned=4GB}
}
$global:SentinelPowerActions=[Collections.Generic.List[string]]::new()
function Get-VM { [CmdletBinding()]param($Name) $global:SentinelPowerFixture[$Name] }
function Stop-VM { [CmdletBinding()]param($VM) $global:SentinelPowerActions.Add('stop:'+ $VM.Name); $VM.State='Off' }
function Start-VM { [CmdletBinding()]param($VM) $global:SentinelPowerActions.Add('start:'+ $VM.Name); $VM.State='Running' }
function Expect-Blocked([scriptblock]$Action) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch 'BLOCKED') { throw }; return }
    throw 'Expected BLOCKED'
}
Expect-Blocked { & $tool -Mode STOP -ExpectedControlPlaneVMId $cp -ExpectedWorkerVMId $worker }
if ($global:SentinelPowerActions.Count) { throw 'Missing approval caused power operation' }
Expect-Blocked { & $tool -Mode STOP -ExpectedControlPlaneVMId ([guid]::NewGuid()) -ExpectedWorkerVMId $worker -Approval STOP_EXACT_SENTINEL_SANDBOX_PAIR }
if ($global:SentinelPowerActions.Count) { throw 'UUID mismatch caused power operation' }
& $tool -Mode STOP -ExpectedControlPlaneVMId $cp -ExpectedWorkerVMId $worker -Approval STOP_EXACT_SENTINEL_SANDBOX_PAIR
& $tool -Mode START -ExpectedControlPlaneVMId $cp -ExpectedWorkerVMId $worker -Approval START_EXACT_SENTINEL_SANDBOX_PAIR
if (($global:SentinelPowerActions -join ',') -cne 'stop:sentinel-l1-w01,stop:sentinel-l1-cp01,start:sentinel-l1-cp01,start:sentinel-l1-w01') {
    throw 'Wrong power operation sequence'
}
$global:SentinelPowerActions.Clear()
function Stop-VM { [CmdletBinding()]param($VM) throw 'BLOCKED: simulated guest shutdown failure' }
Expect-Blocked { & $tool -Mode STOP -ExpectedControlPlaneVMId $cp -ExpectedWorkerVMId $worker -Approval STOP_EXACT_SENTINEL_SANDBOX_PAIR }
if ($global:SentinelPowerFixture['sentinel-l1-cp01'].State -ne 'Running') { throw 'Control plane stopped after failed worker shutdown' }
Write-Host 'PASS: mocked sandbox UUID/approval gates, shutdown/start order and shutdown failure stop'
