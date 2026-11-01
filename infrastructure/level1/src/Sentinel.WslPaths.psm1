#Requires -Version 5.1
# Pure Windows -> standard WSL automount conversion, with no WSL execution.
# Stage 3 expects mounted fixed drives beneath /mnt/<drive>.
Set-StrictMode -Version Latest

function ConvertTo-SentinelWslMountPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WindowsPath)
    if ($WindowsPath -match '[\r\n]') { throw 'BLOCKED: newline in filesystem path' }
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($full -cnotmatch '^(?<drive>[A-Za-z]):\\(?<relative>.+)$') {
        throw 'BLOCKED: only absolute, local drive paths can be passed to WSL'
    }
    $drive = $Matches['drive'].ToLowerInvariant()
    $tail = $Matches['relative'].Replace([char]92, [char]47)
    if ($tail -match '[\r\n]') { throw 'BLOCKED: unsafe WSL path' }
    return "/mnt/$drive/$tail"
}

Export-ModuleMember -Function ConvertTo-SentinelWslMountPath
