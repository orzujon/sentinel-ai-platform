#Requires -Version 5.1
# Offline only. Approval gates execute before any infrastructure access.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Expect-Blocked([scriptblock]$Action) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'BLOCKED') { throw }
        return
    }
    throw 'Expected BLOCKED but operation returned'
}
foreach ($relative in @('src\Sentinel.FreshCluster.psm1','tools\Invoke-SentinelFreshCluster.ps1',
    'tools\New-SentinelFreshVM.ps1','tools\Invoke-SentinelFreshTrust.ps1')) {
    $errors=$null; $tokens=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $commands = $ast.FindAll({param($a) $a -is [Management.Automation.Language.CommandAst]},$true)
    foreach ($command in $commands) {
        if ($command.GetCommandName() -in @('Stop-VM','Remove-VM','Remove-Item','New-VMSwitch','Set-VMSwitch','Checkpoint-VM')) {
            throw 'Fresh creation pipeline contains a prohibited lifecycle operation'
        }
    }
}
$runner=Join-Path $root 'tools\Invoke-SentinelFreshCluster.ps1'
foreach ($stage in @('BOOTSTRAP','BASELINE','REPOSITORY','PACKAGES','INIT','CNI','JOIN','NETWORK-TEST')) {
    Expect-Blocked { & $runner -Stage $stage }
    Expect-Blocked { & $runner -Stage $stage -Approval FRESH_CREATE_CONTROL_PLANE }
}
Expect-Blocked { & $runner -Stage CREATE -Node control-plane }
Expect-Blocked { & $runner -Stage CREATE -Node worker -Approval FRESH_CREATE_CONTROL_PLANE }
Expect-Blocked { & $runner -Stage TRUST -Node worker -Approval FRESH_TRUST_CONTROL_PLANE }
Expect-Blocked { & $runner -Stage CREATE -Node worker -Approval FRESH_CREATE_WORKER }
Expect-Blocked { & $runner -Stage CNI -Approval FRESH_CNI }
Expect-Blocked { & (Join-Path $root 'tools\New-SentinelFreshVM.ps1') -Mode CREATE -Node worker -ImagePath missing -ImageSHA256 ('a'*64) }
Expect-Blocked { & (Join-Path $root 'tools\Invoke-SentinelFreshTrust.ps1') -Mode REGISTER -Node worker }
Import-Module (Join-Path $root 'src\Sentinel.FreshCluster.psm1') -Force
Import-Module (Join-Path $root 'src\Sentinel.KvpEvidence.psm1') -Force
$cp=Get-SentinelFreshNode -Node control-plane
$worker=Get-SentinelFreshNode -Node worker
if ($cp.IP -cne '10.78.0.30' -or $worker.IP -cne '10.78.0.31' -or $cp.Folder -ceq $worker.Folder) { throw 'Wrong profile' }
Expect-Blocked { Assert-SentinelFreshPath -Path 'C:\Sentinel\Level1-Sandbox\VMs' }
$wire=[byte[]](0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+[byte[]](0,0,0,32)+[byte[]](1..32)
$key='ssh-ed25519 '+[Convert]::ToBase64String($wire)
$id=[guid]::NewGuid().ToString()
$entry=[pscustomobject]@{node=$cp.Name;ip=$cp.IP;vmId=$id;nonce=('a'*64)}
$data=@{schema=1;node=$cp.Name;ip=$cp.IP;nonce=('a'*64);publicKey=$key;fingerprint=(Get-SentinelHostKeyFingerprint $key)} | ConvertTo-Json -Compress
Expect-Blocked { Assert-SentinelKvpIdentity -ManifestEntry $entry -ActualVMId $id -GuestData $data }
$evidence=Assert-SentinelKvpIdentity -FreshCluster -ManifestEntry $entry -ActualVMId $id -GuestData $data
if ($evidence.result -cne 'EVIDENCE_MATCH' -or $evidence.trusted) { throw 'Evidence must not independently establish trust' }
Expect-Blocked { Assert-SentinelKvpIdentity -FreshCluster -ManifestEntry $entry -ActualVMId ([guid]::NewGuid().ToString()) -GuestData $data }
$entry.node='sentinel-l1-cp01'; $entry.ip='10.78.0.10'
Expect-Blocked { Assert-SentinelKvpIdentity -FreshCluster -ManifestEntry $entry -ActualVMId $id -GuestData $data }
Write-Host 'PASS: fresh pipeline syntax, pre-access approval gates, profile isolation and KVP identity checks'
