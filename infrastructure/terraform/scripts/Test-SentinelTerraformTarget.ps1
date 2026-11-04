#Requires -Version 5.1
<#
Read-only guard. Run BEFORE each Windows Terraform plan and apply.
Validates the dedicated kubeconfig, API endpoint, exact two nodes, their
private IPs and Kubernetes Ready status. Does not print credentials.
#>
[CmdletBinding()]
param(
    [string]$Kubeconfig = (Join-Path $HOME '.kube\sentinel.yaml')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Kubeconfig -PathType Leaf)) {
    throw 'BLOCKED: dedicated Sentinel kubeconfig missing'
}
$cfg = (Resolve-Path -LiteralPath $Kubeconfig).Path
$server = & kubectl.exe "--kubeconfig=$cfg" config view --minify '-o=jsonpath={.clusters[0].cluster.server}'
if ($LASTEXITCODE -ne 0 -or $server -cne 'https://10.78.0.30:6443') {
    throw 'BLOCKED: kubeconfig is not pointed at the accepted cp01 API'
}
$raw = & kubectl.exe "--kubeconfig=$cfg" get nodes -o json
if ($LASTEXITCODE -ne 0 -or -not $raw) {
    throw 'BLOCKED: cannot inspect Kubernetes node inventory'
}
$nodes = @((ConvertFrom-Json -InputObject ($raw -join [Environment]::NewLine)).items)
$names = @($nodes | ForEach-Object { $_.metadata.name } | Sort-Object)
if ($names.Count -ne 2 -or $names[0] -cne 'cp01' -or $names[1] -cne 'w01') {
    throw 'BLOCKED: not exactly the cp01/w01 target'
}
foreach ($node in $nodes) {
    $name = $node.metadata.name
    $ip = if ($name -ceq 'cp01') { '10.78.0.30' } else { '10.78.0.31' }
    $ips = @($node.status.addresses | Where-Object { $_.type -eq 'InternalIP' } |
        ForEach-Object { $_.address })
    $ready = @($node.status.conditions | Where-Object {
        $_.type -eq 'Ready' -and $_.status -eq 'True'
    })
    if ($ip -cnotin $ips -or $ready.Count -ne 1) {
        throw "BLOCKED: unexpected InternalIP or NotReady: $name"
    }
}
Write-Host 'SENTINEL_TERRAFORM_TARGET_PASS: exact cp01/w01 Ready; pinned API/IPs'
