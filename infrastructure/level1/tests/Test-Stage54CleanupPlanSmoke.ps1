#Requires -Version 5.1
# Full Stage54 cleanup PLAN smoke test with isolated, fabricated Hyper-V
# metadata on an ephemeral GitHub Actions Windows runner. NO REMOVE mode,
# no real Hyper-V objects and no changes to production hosts.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows') {
    throw 'BLOCKED: PLAN integration fixture only runs on GitHub-hosted Windows CI'
}
$entrypoint = Join-Path $PSScriptRoot '..\tools\Remove-SentinelStage54Disposable.ps1'
$vmId = [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'
$vmName = 'sentinel-e2e-w02'
$root = 'C:\Sentinel\E2E-WorkerReplica'
if (Test-Path -LiteralPath $root) {
    throw 'BLOCKED: test fixture root already exists on CI runner; refuse adoption'
}
$folder = Join-Path $root $vmName
$global:config = Join-Path $folder $vmName
$global:osDisk = Join-Path $folder 'os.vhdx'
$global:seed = Join-Path $folder 'seed.iso'
$vmConfig = Join-Path $global:config 'Virtual Machines'
$runtime = Join-Path $vmConfig $vmId.ToString('D').ToUpperInvariant()
[void][IO.Directory]::CreateDirectory($runtime)
foreach ($extension in @('.vmcx','.vmgs','.vmrs')) {
    [IO.File]::WriteAllBytes(
        (Join-Path $vmConfig ($vmId.ToString('D').ToUpperInvariant() + $extension)),
        [byte[]](1,2,3)
    )
}
[IO.File]::WriteAllBytes($global:osDisk,[byte[]](1,2,3))
[IO.File]::WriteAllBytes($global:seed,[byte[]](1,2,3))
$manifest = [ordered]@{
    schema=1;purpose='disposable-worker-replica-e2e';
    node=$vmName;vmId=[string]$vmId;privateIP='10.78.0.12';
    managementMAC='02AA78000112';privateMAC='02AA78000012';
    nonce=('a'*64);kubernetesInstall=$false
}
[IO.File]::WriteAllText(
    (Join-Path $folder 'provisioning.json'),
    ($manifest | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false)
)
$global:fakeVM = [pscustomobject]@{
    Name=$vmName; Id=$vmId; State='Off'; Path=$global:config
}
# The following functions shadow real Hyper-V cmdlets in the child script.
# Fixture values are global only inside this disposable GitHub Actions process,
# because the tested cleanup script has its own PowerShell script scope.
function Get-VM {
    [CmdletBinding()]
    param([string]$Name)
    if (-not $PSBoundParameters.ContainsKey('Name') -or $Name -ceq $global:fakeVM.Name) {
        return $global:fakeVM
    }
}
function Get-VMHardDiskDrive {
    [CmdletBinding()]
    param($VM)
    return [pscustomobject]@{Path=$global:osDisk}
}
function Get-VMDvdDrive {
    [CmdletBinding()]
    param($VM)
    return [pscustomobject]@{Path=$global:seed}
}
function Get-VMSnapshot {
    [CmdletBinding()]
    param($VM)
}
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param($VM)
    [pscustomobject]@{SwitchName='Default Switch'; MacAddress='02AA78000112'}
    [pscustomobject]@{SwitchName='Sentinel-L1'; MacAddress='02AA78000012'}
}
function Get-VHD {
    [CmdletBinding()]
    param([string]$Path)
    [pscustomobject]@{VhdType='Dynamic'; ParentPath=$null}
}
function Stop-VM { throw 'BLOCKED: cleanup PLAN invoked a mutating Hyper-V command' }
function Remove-VM { throw 'BLOCKED: cleanup PLAN invoked a mutating Hyper-V command' }

$success = @(& $entrypoint -Mode PLAN -Target w02 -ExpectedVMId $vmId 6>&1) | Out-String
foreach ($marker in @('CLEANUP_VM_UUID_RUNTIME_VERIFIED',
                     'CLEANUP_VM_CONFIG_FILES_VERIFIED',
                     'CLEANUP_NESTED_HYPERV_CONFIG_VERIFIED',
                     'STAGE54_CLEANUP_PLAN_READY')) {
    if (-not $success.Contains($marker)) {
        throw "BLOCKED: real cleanup PLAN did not emit $marker"
    }
}
Write-Host 'PASS: complete Stage54 cleanup PLAN ran with strict mode, exact mocked VM UUID and real Hyper-V-shaped directory layout'
