#Requires -Version 5.1
<#
.SYNOPSIS
  Stage 5.4 single-command disposable VM -> KVP -> pinned SSH -> Ansible.
.DESCRIPTION
  PLAN is read-only and requires no approval. RUN is a separately approved,
  non-destructive one-time pipeline for a NONEXISTENT disposable slot only.
  If cloud-init or KVP fails, do not attempt SSH, accept unknown keys, destroy
  state or silently adopt an old VM. Inspect guest console and retry VERIFY.
#>
[CmdletBinding()]
param(
    [ValidateSet('PLAN','RUN')][string]$Mode = 'PLAN',
    [ValidateRange(20,29)][int]$Slot = 20,
    [Parameter(Mandatory)][string]$ImagePath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ImageSHA256,
    [string]$WSLPrivateKey = '/home/orzu/.ssh/id_ed25519',
    [string]$Approval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'RUN' -and $Approval -cne 'CREATE_AND_REGISTER_FRESH_SENTINEL_STAGE54') {
    throw 'BLOCKED: explicit one-time Stage54 CREATE + TRUST approval required'
}
$create = Join-Path $PSScriptRoot 'New-SentinelStage54VM.ps1'
$trust = Join-Path $PSScriptRoot 'Invoke-SentinelStage54Trust.ps1'
if (-not (Test-Path -LiteralPath $create -PathType Leaf) -or
    -not (Test-Path -LiteralPath $trust -PathType Leaf)) {
    throw 'BLOCKED: pinned source components missing'
}
function Assert-AnsibleControllerReady {
    if ($WSLPrivateKey -cnotmatch '^/home/[a-z][a-z0-9_-]*/\.ssh/id_ed25519$') {
        throw 'BLOCKED: existing WSL controller key must be /home/<user>/.ssh/id_ed25519'
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'BLOCKED: WSL controller is not available'
    }
    & wsl.exe -d Ubuntu-26.04 --exec test -r $WSLPrivateKey
    if ($LASTEXITCODE -ne 0) {
        throw 'BLOCKED: pre-existing WSL Ansible SSH private identity missing or unreadable'
    }
    # A readable WSL key is not sufficient. It must be the SAME login key
    # authorised by the provisioner inside the guest's cloud-init seed.
    $winPublicPath = Join-Path $HOME '.ssh\id_ed25519.pub'
    if (-not (Test-Path -LiteralPath $winPublicPath -PathType Leaf)) {
        throw 'BLOCKED: Windows provisioning SSH login public key unavailable'
    }
    $winPublic = (Get-Content -LiteralPath $winPublicPath -Raw -Encoding ASCII).Trim()
    $wslPublic = @(& wsl.exe -d Ubuntu-26.04 --exec ssh-keygen -y -P '' -f $WSLPrivateKey)
    if ($LASTEXITCODE -ne 0 -or $wslPublic.Count -ne 1) {
        throw 'BLOCKED: cannot independently derive WSL Ansible login public key'
    }
    $winFields = $winPublic -split '\s+'
    $wslFields = $wslPublic[0].Trim() -split '\s+'
    if ($winFields.Length -lt 2 -or $wslFields.Length -lt 2 -or
        $winFields[0] -cne 'ssh-ed25519' -or
        $wslFields[0] -cne $winFields[0] -or
        $wslFields[1] -cne $winFields[1]) {
        throw 'BLOCKED: WSL Ansible user private key does not match cloud-init authorised public login key'
    }
    & wsl.exe -d Ubuntu-26.04 --exec ansible --version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'BLOCKED: Ansible command unavailable in controller WSL Ubuntu-26.04'
    }
}
# Check the WSL Ansible controller BEFORE any disposable VM CREATE.
Assert-AnsibleControllerReady
if ($Mode -eq 'PLAN') {
    & $create -Mode PLAN -Slot $Slot -ImagePath $ImagePath -ImageSHA256 $ImageSHA256
    Write-Host 'STAGE54_ORCHESTRATOR_PLAN_READY: no VM or SSH trust change.'
    return
}
# Explicit operator approval is split into two scoped sub-step authorizations.
& $create -Mode CREATE -Slot $Slot -ImagePath $ImagePath -ImageSHA256 $ImageSHA256 -Approval CREATE_FRESH_DISPOSABLE_SENTINEL_STAGE54
Write-Host 'STAGE54_WAITING_FOR_FIRSTBOOT_KVP: no network SSH has been attempted.'
$verified = $false
for ($i=1; $i -le 120; $i++) {
    try {
        & $trust -Mode VERIFY -Slot $Slot
        $verified = $true
        break
    } catch {
        if ($i -eq 120) {
            throw 'BLOCKED: no fresh KVP identity after 10 minutes; use VM console/cloud-init. Never auto-trust or retry VM creation.'
        }
        if ($i % 12 -eq 0) {
            Write-Host "STAGE54_WAIT_KVP: first boot still pending after $($i * 5) seconds; no SSH fallback."
        }
        Start-Sleep -Seconds 5
    }
}
if (-not $verified) { throw 'BLOCKED: KVP verification failed' }
& $trust -Mode REGISTER -Slot $Slot -Approval REGISTER_KVP_VERIFIED_SENTINEL_STAGE54_HOST_KEY
& $trust -Mode ACCEPT -Slot $Slot
& $trust -Mode ANSIBLE -Slot $Slot -WSLPrivateKey $WSLPrivateKey
Write-Host "STAGE54_ZERO_TOUCH_E2E_PASS: sentinel-e2e-auto$Slot; VM created -> KVP verified -> trusted SSH -> Ansible."
