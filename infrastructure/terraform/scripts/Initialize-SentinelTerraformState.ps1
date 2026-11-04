#Requires -Version 5.1
<#
Windows-local directory and ACL preparation only. Does not start Terraform,
connect to Kubernetes, or write/overwrite any Terraform state file.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') { throw 'BLOCKED: Windows-only local state setup' }
$stateRoot = 'C:\Sentinel\TerraformState\level1'
$backupRoot = 'C:\Sentinel\Backups\TerraformState'
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not $ownerSid) { throw 'BLOCKED: Windows identity SID missing' }

foreach ($path in @('C:\Sentinel', 'C:\Sentinel\TerraformState', $stateRoot,
                    'C:\Sentinel\Backups', $backupRoot)) {
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "BLOCKED: path is not a real directory: $path"
        }
    } else {
        [void](New-Item -ItemType Directory -Path $path -Force)
    }
}

$ownerRule = '*' + $ownerSid + ':(OI)(CI)F'
foreach ($path in @($stateRoot, $backupRoot)) {
    # Remove inherited ACEs and grant only owner, Local System, Administrators.
    & icacls.exe $path /inheritance:r /grant:r $ownerRule '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "BLOCKED: ACL configuration failed for $path" }
    $allowed = @($ownerSid, 'S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $path
    foreach ($ace in @($acl.Access)) {
        $sid = $ace.IdentityReference.Translate(
            [Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowed) {
            throw "BLOCKED: unexpected account retains access to $path"
        }
    }
    Write-Host "LOCAL_PRIVATE_DIRECTORY_READY: $path"
}
Write-Host 'SENTINEL_TERRAFORM_STATE_DIRECTORIES_PASS: no state or Kubernetes objects modified'
