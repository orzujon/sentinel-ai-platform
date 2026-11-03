#Requires -Version 5.1
# Stage54 negative cleanup gates are purely offline: no Hyper-V VM ever removed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
$script = Join-Path $root 'tools\Remove-SentinelStage54Disposable.ps1'
$provisioner = Join-Path $root 'tools\New-SentinelStage54VM.ps1'
$pipeline = Join-Path $root 'tools\Invoke-SentinelStage54.ps1'
$layoutModule = Join-Path $root 'src\Sentinel.HyperVDisposableLayout.psm1'
foreach ($path in @($script,$provisioner,$pipeline,$layoutModule)) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -ne 0) {
        throw ('BLOCKED: invalid Stage54 cleanup or preflight PowerShell syntax: ' + (($errors | ForEach-Object Message) -join '; '))
    }
}
function Expect-Blocked([scriptblock]$Action) {
    try {
        & $Action | Out-Null
        throw 'Unexpected destructive approval gate bypass'
    } catch {
        if ($_.Exception.Message -eq 'Unexpected destructive approval gate bypass') { throw }
        if ($_.Exception.Message -notmatch 'BLOCKED') {
            throw ('Cleanup refused for unexpected reason: ' + $_.Exception.Message)
        }
    }
}
$id = [guid]'7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'
# Each REMOVE must fail BEFORE invoking any Get-VM or Remove-VM calls.
Expect-Blocked { & $script -Mode REMOVE -Target w02 -ExpectedVMId $id }
Expect-Blocked { & $script -Mode REMOVE -Target w02 -ExpectedVMId $id -Approval 'wrong' }
Expect-Blocked { & $script -Mode REMOVE -Target stage54 -Slot 20 -ExpectedVMId ([guid]::NewGuid()) }
Expect-Blocked { & $script -Mode REMOVE -Target stage54 -Slot 20 -ExpectedVMId ([guid]::NewGuid()) -Approval 'wrong' }
# w02's verified UUID must also block a wrong GUID even if no deletion requested.
Expect-Blocked { & $script -Mode PLAN -Target w02 -ExpectedVMId ([guid]::NewGuid()) }
Expect-Blocked { & $script -Mode PLAN -Target stage54 -ExpectedVMId ([guid]::Empty) }
$source = Get-Content -LiteralPath $script -Raw -Encoding UTF8
$createSource = Get-Content -LiteralPath $provisioner -Raw -Encoding UTF8
$pipelineSource = Get-Content -LiteralPath $pipeline -Raw -Encoding UTF8
foreach ($required in @(
    "C:\Sentinel\E2E-WorkerReplica",
    "C:\Sentinel\Stage54",
    '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9',
    'disposable-worker-replica-e2e',
    'sentinel-stage54-disposable-bootstrap',
    'REMOVE_EXACT_SENTINEL_E2E_W02',
    'REMOVE_EXACT_SENTINEL_STAGE54_DISPOSABLE',
    'ExpectedVMId',
    'Get-VMHardDiskDrive',
    'Get-VMDvdDrive',
    'Get-VMSnapshot',
    'Get-VMNetworkAdapter',
    'Get-VHD',
    'ReparsePoint',
    'ParentPath',
    'Get-ChildItem -LiteralPath',
    'Get-VM -ErrorAction Stop',
    'Remove-VM -VM',
    'Remove-Item -LiteralPath $folder',
    'Stop-VM -VM $again -ErrorAction Stop',
    'Assert-SentinelHyperVConfigLayout -ConfigDirectory $configDir -ExpectedVMId $ExpectedVMId',
    'CLEANUP_NESTED_HYPERV_CONFIG_VERIFIED',
    'CLEANUP_NESTED_PATH_MISMATCH',
    'CLEANUP_UNRECOGNISED_NESTED_ENTRY',
    'Test-InFolder -Candidate ([string]$vm.Path) -Directory $nested',
    'Get-VMSnapshot -VM $vm',
    'CLEANUP_UNRECOGNISED_ENTRY:',
    'CLEANUP_UNRECOGNISED_ENTRIES:',
    'no deletion performed',
    'review each path before changing allowlist',
    'STAGE54_CLEANUP_PLAN_READY',
    'STAGE54_DISPOSABLE_CLEANUP_COMPLETE',
    'foreign VM',
    'ProtectedKubernetesVMsUntouched'
)) {
    if (-not $source.Contains($required)) { throw "BLOCKED: missing cleanup safeguard: $required" }
}
foreach ($forbidden in @('Stop-VM -TurnOff','Stop-VM -Force','Stop-VM -VM $again -Shutdown','Remove-VMSwitch','New-VMSwitch','Set-VMNetworkAdapter','Remove-VMHardDiskDrive','Remove-VHD','ssh-keyscan','Read-Host')) {
    if ($source.Contains($forbidden)) {
        throw "BLOCKED: cleanup has unsafe operation or unexpected external command: $forbidden"
    }
}
# Prevent the 2026-11-01 live cleanup bug: -Shutdown is not a Stop-VM parameter.
# Assert the actual parsed Stop-VM invocation has no unsupported or power-cut switches.
$stopTokens = $null; $stopErrors = $null
$stopAst = [Management.Automation.Language.Parser]::ParseFile($script,[ref]$stopTokens,[ref]$stopErrors)
$stopCalls = @($stopAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'Stop-VM'
},$true))
if ($stopCalls.Count -ne 1 -or $stopCalls[0].Extent.Text -cne 'Stop-VM -VM $again -ErrorAction Stop') {
    throw 'BLOCKED: cleanup must use one supported graceful Stop-VM command without -Shutdown, -Force or -TurnOff'
}
Write-Host 'PASS: graceful Stop-VM invocation uses supported syntax and rejects forced shutdown'

# Regression for the actual 2026-11-01 runtime failure: the real cleanup
# PLAN referenced $configDir before assignment even though static tests passed.
# Locate the assignment and consumer as parsed AST nodes, not a string
# appearing in a comment or a function that never runs.
$parseTokens = $null
$parseErrors = $null
$cleanupAst = [Management.Automation.Language.Parser]::ParseFile(
    $script, [ref]$parseTokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw 'BLOCKED: cleanup AST is not parseable for variable-flow regression'
}
$assignments = @($cleanupAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$configDir' -and
    $node.Right.Extent.Text -match 'Join-Path\s+\$nested\s+'
}, $true))
$calls = @($cleanupAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'Assert-SentinelHyperVConfigLayout'
}, $true))
if ($assignments.Count -ne 1 -or $calls.Count -ne 1 -or
    $assignments[0].Extent.StartOffset -ge $calls[0].Extent.StartOffset) {
    throw 'BLOCKED: actual PLAN configDir must be initialised exactly once before Hyper-V config layout validator'
}
$preflight = $source.IndexOf("if (-not (Test-Path -LiteralPath " + '$configDir' + " -PathType Container))")
if ($preflight -le $assignments[0].Extent.StartOffset -or
    $preflight -ge $calls[0].Extent.StartOffset) {
    throw 'BLOCKED: actual PLAN configDir existence check must happen between assignment and validator'
}
Write-Host 'PASS: configDir assignment and directory preflight precede real cleanup PLAN validator invocation'

# Nested same-name folders are NOT trusted just because they have a familiar name.
# The live Hyper-V VM.Path and UUID-named vmcx must both match, and child
# folders must not contain foreign VM disks, checkpoints or unknown files.
if (-not $source.Contains('if ($allowNested) { $topAllowed += $name }') -or
    -not $source.Contains('if (-not (Test-InFolder -Candidate ([string]$vm.Path) -Directory $nested))') -or
    -not $source.Contains('Assert-SentinelHyperVConfigLayout -ConfigDirectory $configDir -ExpectedVMId $ExpectedVMId') -or
    -not $source.Contains('if ($unexpectedNested.Count -ne 0)') -or
    -not $source.Contains('Snapshots') -or
    -not $source.Contains('if ($unexpected.Count -ne 0)')) {
    throw 'BLOCKED: same-name nested Hyper-V configuration must retain VM UUID and strict file ownership checks'
}
# Unknown entries must be listed for review, NEVER deleted or adopted.
# Maintain the original explicit top-level allowlist; no wildcard additions.
if (-not $source.Contains('if ($unexpected.Count -ne 0)') -or
    -not $source.Contains('foreach ($item in $unexpected)') -or
    $source.Contains("'*'")) {
    throw 'BLOCKED: cleanup unexpectedly broadens the deletion allowlist'
}
if (-not $createSource.Contains('STAGE54_CLEANUP_REQUIRED') -or
    -not $createSource.Contains('sentinel-e2e-(w02|ssh01|auto2[0-9])') -or
    -not $pipelineSource.Contains('# First check that previous disposable lab VMs have been cleaned up.')) {
    throw 'BLOCKED: new VM creation must refuse existing disposables and require cleanup first'
}
if ($pipelineSource.IndexOf('& $create -Mode PLAN') -gt $pipelineSource.IndexOf('Assert-AnsibleControllerReady'+[char]10+'if ($Mode')) {
    throw 'BLOCKED: cleanup and VM plan must precede controller preflight'
}

# Real file-system fixtures exercise the SAME pure helper used by cleanup.
# They never call Remove-VM or touch any Hyper-V object.
Import-Module $layoutModule -Force -ErrorAction Stop
$sourceLayout = Get-Content -LiteralPath $layoutModule -Raw -Encoding UTF8
foreach ($guard in @(
    'CLEANUP_UNOWNED_CONFIG_ENTRY',
    'CLEANUP_UNRECOGNISED_RUNTIME_ENTRY',
    'CLEANUP_VM_UUID_RUNTIME_VERIFIED',
    'CLEANUP_CONFIG_FILE_CANDIDATES',
    "'.vmcx'",
    'ReparsePoint',
    'ExpectedVMId'
)) {
    if (-not $sourceLayout.Contains($guard)) {
        throw "BLOCKED: missing GUID-aware nested Hyper-V validator guard $guard"
    }
}

$fixture = Join-Path $env:TEMP ('sentinel-stage54-layout-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixture -ErrorAction Stop)
try {
    $vmId = [guid]::NewGuid()
    $uuid = $vmId.ToString('D').ToUpperInvariant()
    $vmcx = Join-Path $fixture ($uuid + '.vmcx')
    $vmgs = Join-Path $fixture ($uuid + '.vmgs')
    $vmrs = Join-Path $fixture ($uuid + '.vmrs')
    foreach ($path in @($vmcx,$vmgs,$vmrs)) {
        [IO.File]::WriteAllBytes($path,[byte[]](1,2,3))
    }
    $runtime = Join-Path $fixture $uuid
    [void](New-Item -ItemType Directory -Path $runtime -ErrorAction Stop)
    if ((Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId $vmId) -cne 'VERIFIED') {
        throw 'BLOCKED: exact GUID-matching empty runtime folder should be accepted'
    }
    $oldRuntime = Join-Path $runtime ($uuid + '.bin')
    [IO.File]::WriteAllBytes($oldRuntime,[byte[]](1,2))
    if ((Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId $vmId) -cne 'VERIFIED') {
        throw 'BLOCKED: exact GUID-matching historical VM state file should be accepted'
    }
    # Unknown files must still stop the cleanup preflight without mutations.
    $foreign = Join-Path $runtime 'other-vm.bin'
    [IO.File]::WriteAllBytes($foreign,[byte[]](1))
    Expect-Blocked { Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId $vmId }
    if (-not [IO.File]::Exists($foreign)) {
        throw 'BLOCKED: inspection unexpectedly deleted foreign test data'
    }
    [IO.File]::Delete($foreign)
    $foreignDir = Join-Path $fixture ([guid]::NewGuid().ToString('D'))
    [void](New-Item -ItemType Directory -Path $foreignDir -ErrorAction Stop)
    Expect-Blocked { Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId $vmId }
    Remove-Item -LiteralPath $foreignDir -Recurse -Force
    $unexpectedFile = Join-Path $fixture 'config-note.txt'
    [IO.File]::WriteAllBytes($unexpectedFile,[byte[]](1))
    Expect-Blocked { Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId $vmId }
    [IO.File]::Delete($unexpectedFile)
    Expect-Blocked {
        Assert-SentinelHyperVConfigLayout -ConfigDirectory $fixture -ExpectedVMId ([guid]::NewGuid())
    }
    Write-Host 'PASS: GUID folder accepts exact VM-owned files only; foreign runtime/config entries and wrong UUID block'
} finally {
    # CI-created TEMP fixtures only; never production VM disks.
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS: exact-UUID disposal, protection checks, no-force graceful shutdown and cleanup-before-create enforcement'
