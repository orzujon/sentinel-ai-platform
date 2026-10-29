#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# One call per VM: actual SSH public-key authentication, hostname, cloud-init,
# Linux-reported RAM, and passwordless sudo. No commands mutate guest state.
function Assert-SentinelGuestHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('sentinel-l1-cp01','sentinel-l1-w01')][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('10.78.0.10','10.78.0.11')][string]$IPAddress,
        [int]$Attempts = 3
    )
    $expectedIP = switch ($VMName) { 'sentinel-l1-cp01' { '10.78.0.10' }; 'sentinel-l1-w01' { '10.78.0.11' } }
    if ($IPAddress -cne $expectedIP) { throw "VM name and IP are not paired as specified: $VMName / $IPAddress" }
    $key = Join-Path $HOME '.ssh\id_ed25519'
    if (-not (Test-Path -LiteralPath $key -PathType Leaf)) { throw "Windows SSH private key not found: $key" }
    $ssh = Get-Command ssh.exe -CommandType Application -ErrorAction Stop
    # cloud-init gets 150s to finish; SSH is additionally bounded by connection and keepalive timeouts.
    # StrictHostKeyChecking=accept-new permits a first-time host key, but REJECTS changed keys.
    $remote = 'set -eu; printf "HOST="; hostname; printf "CLOUD="; timeout 150s cloud-init status --wait; grep "^MemTotal:" /proc/meminfo; sudo -n true; echo SENTINEL_GUEST_OK'
    $sshArgs = @(
        '-o','BatchMode=yes',
        '-o','PasswordAuthentication=no',
        '-o','KbdInteractiveAuthentication=no',
        '-o','IdentitiesOnly=yes',
        '-o','StrictHostKeyChecking=accept-new',
        '-o','ConnectTimeout=10',
        '-o','ConnectionAttempts=1',
        '-o','ServerAliveInterval=10',
        '-o','ServerAliveCountMax=3',
        '-i',$key,
        ('orzu@' + $IPAddress),
        $remote
    )
    $lastError = ''
    for ($attempt=1; $attempt -le $Attempts; $attempt++) {
        # Capture command output without polluting the result-object pipeline.
        # SSH diagnostic stderr goes to the console; only stdout is parsed.
        # Avoid PowerShell 5.1 treating redirected native stderr as a terminating error.
        $outputLines = @(& $ssh.Source @sshArgs | ForEach-Object { [string]$_ })
        $exit = $LASTEXITCODE
        $output = $outputLines -join "`n"
        if ($exit -eq 0) {
            if ($output -notmatch "(?m)^HOST=$([regex]::Escape($VMName))\r?$") { throw "SSH authenticated but hostname mismatch for $VMName. Output: $output" }
            if ($output -notmatch '(?m)^CLOUD=status: done\s*$') { throw "Cloud-init not confirmed DONE for $VMName. Output: $output" }
            $match = [regex]::Match($output,'(?m)^MemTotal:\s+(\d+)\s+kB\s*$')
            if (-not $match.Success) { throw "Could not read guest RAM for $VMName. Output: $output" }
            [long]$ramKiB = [long]$match.Groups[1].Value
            if ($ramKiB -lt 3500000) { throw "Guest $VMName reports only $ramKiB KiB RAM; expected about 4 GiB." }
            if ($output -notmatch '(?m)^SENTINEL_GUEST_OK\s*$') { throw "sudo or completion marker missing on $VMName." }
            return [pscustomobject]@{ VMName=$VMName; IP=$IPAddress; Hostname=$VMName; CloudInit='done'; MemoryKiB=$ramKiB; SSHAuthenticated=$true; Sudo=$true }
        }
        $lastError = ($outputLines | Select-Object -Last 4) -join ' | '
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 8 }
    }
    throw "SSH guest-health failed for $VMName at $IPAddress after $Attempts attempt(s), exit $exit`: $lastError"
}
Export-ModuleMember -Function Assert-SentinelGuestHealth
