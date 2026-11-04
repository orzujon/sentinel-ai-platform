#Requires -Version 5.1
# This file does not use Hyper-V or any real VM. Approval gates fail before
# importing Hyper-V or checking storage; AST review checks destructive scope.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scriptFile = Join-Path $root 'tools\Remove-SentinelFreshCluster.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptFile,[ref]$tokens,[ref]$errors)
if (@($errors).Count -ne 0) { throw "BLOCKED: PowerShell parser failed: $($errors | Out-String)" }
function Expect-Blocked([scriptblock]$Action) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'BLOCKED') { throw }
        return
    }
    throw 'Expected BLOCKED before any Hyper-V or storage operation'
}
$id1 = [guid]'11111111-1111-4111-8111-111111111111'
$id2 = [guid]'22222222-2222-4222-8222-222222222222'
Expect-Blocked { & $scriptFile -Mode REMOVE -ExpectedControlPlaneVMId $id1 -ExpectedWorkerVMId $id2 }
Expect-Blocked { & $scriptFile -Mode REMOVE -ExpectedControlPlaneVMId $id1 -ExpectedWorkerVMId $id2 -Approval 'REMOVE_EXACT_SENTINEL_STAGE54_DISPOSABLE' }
Expect-Blocked { & $scriptFile -Mode PLAN -ExpectedControlPlaneVMId $id1 -ExpectedWorkerVMId $id2 -Approval 'REMOVE_EXACT_SENTINEL_FRESH_PAIR_FOR_REBUILD' }
Expect-Blocked { & $scriptFile -Mode PLAN -ExpectedControlPlaneVMId $id1 -ExpectedWorkerVMId $id1 }
Expect-Blocked { & $scriptFile -Mode PLAN -ExpectedControlPlaneVMId ([guid]::Empty) -ExpectedWorkerVMId $id2 }
$source = Get-Content -LiteralPath $scriptFile -Raw -Encoding UTF8
foreach ($required in @(
    'REMOVE_EXACT_SENTINEL_FRESH_PAIR_FOR_REBUILD',
    'sentinel-fresh-cp01','sentinel-fresh-w01',
    '10.78.0.30','10.78.0.31',
    'C:\Sentinel\FreshCluster\VMs',
    "Assert-SentinelHyperVConfigLayout -ConfigDirectory ",
    'Get-VMSnapshot','Get-VHD','Get-VMHardDiskDrive',
    'Test-Under','ReparsePoint','sourceImageSHA256','provisioning.json',
    'Remove-VM -VM $vm -Force',
    'Remove-Item -LiteralPath $folder -Recurse -Force',
    'if ($Mode -eq 'PLAN')',
    'FRESH_REMOVE_PLAN_READY','FRESH_PAIR_REMOVAL_PASS'
)) {
    if (-not $source.Contains($required)) {
        throw "BLOCKED: missing cleanup safety contract $required"
    }
}
foreach ($prohibited in @(
    'Remove-VMSwitch','New-VMSwitch','Get-VM -Name sentinel-fresh-*',
    'Remove-VM -Name','Stop-VM -Force','Stop-VM -TurnOff','Checkpoint-VM',
    "Remove-Item -LiteralPath 'C:\Sentinel\ImageCache'",
    "Remove-Item -LiteralPath $storageRoot"
)) {
    if ($source.Contains($prohibited)) {
        throw "BLOCKED: overly broad or destructive operation: $prohibited"
    }
}
$commands = @($ast.FindAll({
    param($a) $a -is [Management.Automation.Language.CommandAst]
},$true))
$vmRemoval = @($commands | Where-Object { $_.GetCommandName() -ceq 'Remove-VM' })
$folderRemoval = @($commands | Where-Object { $_.GetCommandName() -ceq 'Remove-Item' })
if ($vmRemoval.Count -ne 1 -or $folderRemoval.Count -ne 1) {
    throw 'BLOCKED: unexpected number of VM/folder destruction sites'
}
$stopLine = $source.IndexOf('Stop-VM -VM $vm -ErrorAction Stop')
$verifyLine = $source.IndexOf('$stopped = @(Assert-BothTargets)')
$removeLine = $source.IndexOf('Remove-VM -VM $vm -Force -ErrorAction Stop')
$unlinkLine = $source.IndexOf('Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop')
if ($stopLine -lt 0 -or $verifyLine -le $stopLine -or
    $removeLine -le $verifyLine -or $unlinkLine -le $removeLine) {
    throw 'BLOCKED: cleanup does not enforce stop/revalidate/unregister/files order'
}
Write-Host 'PASS: fresh-cluster cleanup AST, early approval, exact pair scope, no force-off, and no wildcard deletions'
