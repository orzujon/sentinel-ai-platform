#Requires -Version 5.1
# Stage 5.3.4: independently verified SSH host-public-key trust, local Windows only.
# No Hyper-V, SSH, known_hosts or guest mutations in these pure file primitives.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Import Sentinel.KvpEvidence.psm1 from the entrypoint BEFORE this module.
# Importing it again with -Force in nested module scope removes/replaces the
# caller-visible exported functions in Windows PowerShell 5.1. Keep one owner
# of shared imports and fail closed if the dependency is unavailable.
if (-not (Get-Command Get-SentinelHostKeyFingerprint -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'BLOCKED: import Sentinel.KvpEvidence.psm1 before Sentinel.SshTrust.psm1'
}

function Get-SentinelTrustedHostLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$PublicKey,
        [Parameter(Mandatory)][string]$Fingerprint
    )
    if ($IPAddress -cnotmatch '^10\.78\.0\.(12|2[0-9])$') {
        throw 'BLOCKED: trusted host entry must target approved disposable slot only'
    }
    $calculated = Get-SentinelHostKeyFingerprint -PublicKey $PublicKey
    if ($calculated -cne $Fingerprint) {
        throw 'BLOCKED: KVP public key and fingerprint differ'
    }
    return "$IPAddress $PublicKey"
}

function Assert-SentinelTrustStoreDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'BLOCKED: provisioner-owned trust directory missing'
    }
    $directory = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCKED: reparse point or junction in trusted host file directory'
    }
}

function Assert-SentinelTrustedHostACL {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $acl = [IO.File]::GetAccessControl($Path)
    if (-not $acl.AreAccessRulesProtected) {
        throw 'BLOCKED: trust store ACL inherits permissions'
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $system = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
    $admins = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)).Value
    $allowed = @($user,$system,$admins)
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
        throw 'BLOCKED: unexpected trusted host file owner'
    }
    $rules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowed) {
            throw 'BLOCKED: trust store ACL grants access to an unexpected identity'
        }
    }
}

function Get-SentinelTrustStoreState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    Assert-SentinelTrustStoreDirectory -Path $Path
    if ($ExpectedLine -cnotmatch '^10\.78\.0\.(12|2[0-9]) ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') {
        throw 'BLOCKED: unexpected trusted host line'
    }
    if (-not [IO.File]::Exists($Path)) {
        if (Test-Path -LiteralPath $Path) {
            throw 'BLOCKED: trusted host path is occupied but not a normal file'
        }
        return 'ABSENT'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.PSIsContainer -or $item.Length -gt 512) {
        throw 'BLOCKED: trusted host path is symlinked, not regular or oversized'
    }
    Assert-SentinelTrustedHostACL -Path $Path
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $actualBytes = [IO.File]::ReadAllBytes($Path)
    if ($actualBytes.Length -ne $expectedBytes.Length) {
        throw 'BLOCKED: trusted host file contains extra, missing or changed entries'
    }
    for ($i=0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $expectedBytes[$i]) {
            throw 'BLOCKED: trusted host key differs from independently verified KVP evidence'
        }
    }
    return 'MATCH'
}

function Register-SentinelTrustedHostFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    $state = Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine
    if ($state -eq 'MATCH') { return 'ALREADY_REGISTERED' }
    if ($state -ne 'ABSENT') { throw 'BLOCKED: unexpected trust state' }

    # A protected NTFS ACL is applied AT FILE CREATION, not after writing.
    # No Create/overwrite mode: an unexpectedly appearing file blocks.
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $sids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    )
    foreach ($sid in $sids) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $bytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $stream = [IO.FileStream]::new(
        $Path,[IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Modify,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$security
    )
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if ((Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine) -ne 'MATCH') {
        throw 'BLOCKED: trusted host registration did not verify after write'
    }
    return 'REGISTERED'
}

Export-ModuleMember -Function Get-SentinelTrustedHostLine, Get-SentinelTrustStoreState, Register-SentinelTrustedHostFile
) {
        throw 'BLOCKED: trusted host entry must target only disposable IP 10.78.0.12'
    }
    $calculated = Get-SentinelHostKeyFingerprint -PublicKey $PublicKey
    if ($calculated -cne $Fingerprint) {
        throw 'BLOCKED: KVP public key and fingerprint differ'
    }
    return "$IPAddress $PublicKey"
}

function Assert-SentinelTrustStoreDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'BLOCKED: provisioner-owned trust directory missing'
    }
    $directory = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCKED: reparse point or junction in trusted host file directory'
    }
}

function Assert-SentinelTrustedHostACL {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $acl = [IO.File]::GetAccessControl($Path)
    if (-not $acl.AreAccessRulesProtected) {
        throw 'BLOCKED: trust store ACL inherits permissions'
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $system = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
    $admins = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)).Value
    $allowed = @($user,$system,$admins)
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
        throw 'BLOCKED: unexpected trusted host file owner'
    }
    $rules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowed) {
            throw 'BLOCKED: trust store ACL grants access to an unexpected identity'
        }
    }
}

function Get-SentinelTrustStoreState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    Assert-SentinelTrustStoreDirectory -Path $Path
    if ($ExpectedLine -cnotmatch '^10\.78\.0\.(12|2[0-9]) ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') {
        throw 'BLOCKED: unexpected trusted host line'
    }
    if (-not [IO.File]::Exists($Path)) {
        if (Test-Path -LiteralPath $Path) {
            throw 'BLOCKED: trusted host path is occupied but not a normal file'
        }
        return 'ABSENT'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.PSIsContainer -or $item.Length -gt 512) {
        throw 'BLOCKED: trusted host path is symlinked, not regular or oversized'
    }
    Assert-SentinelTrustedHostACL -Path $Path
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $actualBytes = [IO.File]::ReadAllBytes($Path)
    if ($actualBytes.Length -ne $expectedBytes.Length) {
        throw 'BLOCKED: trusted host file contains extra, missing or changed entries'
    }
    for ($i=0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $expectedBytes[$i]) {
            throw 'BLOCKED: trusted host key differs from independently verified KVP evidence'
        }
    }
    return 'MATCH'
}

function Register-SentinelTrustedHostFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    $state = Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine
    if ($state -eq 'MATCH') { return 'ALREADY_REGISTERED' }
    if ($state -ne 'ABSENT') { throw 'BLOCKED: unexpected trust state' }

    # A protected NTFS ACL is applied AT FILE CREATION, not after writing.
    # No Create/overwrite mode: an unexpectedly appearing file blocks.
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $sids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    )
    foreach ($sid in $sids) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $bytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $stream = [IO.FileStream]::new(
        $Path,[IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Modify,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$security
    )
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if ((Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine) -ne 'MATCH') {
        throw 'BLOCKED: trusted host registration did not verify after write'
    }
    return 'REGISTERED'
}

Export-ModuleMember -Function Get-SentinelTrustedHostLine, Get-SentinelTrustStoreState, Register-SentinelTrustedHostFile
) {
        throw 'BLOCKED: unexpected trusted host line'
    }
    if (-not [IO.File]::Exists($Path)) {
        if (Test-Path -LiteralPath $Path) {
            throw 'BLOCKED: trusted host path is occupied but not a normal file'
        }
        return 'ABSENT'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.PSIsContainer -or $item.Length -gt 512) {
        throw 'BLOCKED: trusted host path is symlinked, not regular or oversized'
    }
    Assert-SentinelTrustedHostACL -Path $Path
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $actualBytes = [IO.File]::ReadAllBytes($Path)
    if ($actualBytes.Length -ne $expectedBytes.Length) {
        throw 'BLOCKED: trusted host file contains extra, missing or changed entries'
    }
    for ($i=0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $expectedBytes[$i]) {
            throw 'BLOCKED: trusted host key differs from independently verified KVP evidence'
        }
    }
    return 'MATCH'
}

function Register-SentinelTrustedHostFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    $state = Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine
    if ($state -eq 'MATCH') { return 'ALREADY_REGISTERED' }
    if ($state -ne 'ABSENT') { throw 'BLOCKED: unexpected trust state' }

    # A protected NTFS ACL is applied AT FILE CREATION, not after writing.
    # No Create/overwrite mode: an unexpectedly appearing file blocks.
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $sids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    )
    foreach ($sid in $sids) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $bytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $stream = [IO.FileStream]::new(
        $Path,[IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Modify,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$security
    )
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if ((Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine) -ne 'MATCH') {
        throw 'BLOCKED: trusted host registration did not verify after write'
    }
    return 'REGISTERED'
}

Export-ModuleMember -Function Get-SentinelTrustedHostLine, Get-SentinelTrustStoreState, Register-SentinelTrustedHostFile
) {
        throw 'BLOCKED: trusted host entry must target only disposable IP 10.78.0.12'
    }
    $calculated = Get-SentinelHostKeyFingerprint -PublicKey $PublicKey
    if ($calculated -cne $Fingerprint) {
        throw 'BLOCKED: KVP public key and fingerprint differ'
    }
    return "$IPAddress $PublicKey"
}

function Assert-SentinelTrustStoreDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw 'BLOCKED: provisioner-owned trust directory missing'
    }
    $directory = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'BLOCKED: reparse point or junction in trusted host file directory'
    }
}

function Assert-SentinelTrustedHostACL {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $acl = [IO.File]::GetAccessControl($Path)
    if (-not $acl.AreAccessRulesProtected) {
        throw 'BLOCKED: trust store ACL inherits permissions'
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $system = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
    $admins = ([Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)).Value
    $allowed = @($user,$system,$admins)
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
        throw 'BLOCKED: unexpected trusted host file owner'
    }
    $rules = $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowed) {
            throw 'BLOCKED: trust store ACL grants access to an unexpected identity'
        }
    }
}

function Get-SentinelTrustStoreState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    Assert-SentinelTrustStoreDirectory -Path $Path
    if ($ExpectedLine -cnotmatch '^10\.78\.0\.(12|2[0-9]) ssh-ed25519 [A-Za-z0-9+/]+={0,2}$') {
        throw 'BLOCKED: unexpected trusted host line'
    }
    if (-not [IO.File]::Exists($Path)) {
        if (Test-Path -LiteralPath $Path) {
            throw 'BLOCKED: trusted host path is occupied but not a normal file'
        }
        return 'ABSENT'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.PSIsContainer -or $item.Length -gt 512) {
        throw 'BLOCKED: trusted host path is symlinked, not regular or oversized'
    }
    Assert-SentinelTrustedHostACL -Path $Path
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $actualBytes = [IO.File]::ReadAllBytes($Path)
    if ($actualBytes.Length -ne $expectedBytes.Length) {
        throw 'BLOCKED: trusted host file contains extra, missing or changed entries'
    }
    for ($i=0; $i -lt $actualBytes.Length; $i++) {
        if ($actualBytes[$i] -ne $expectedBytes[$i]) {
            throw 'BLOCKED: trusted host key differs from independently verified KVP evidence'
        }
    }
    return 'MATCH'
}

function Register-SentinelTrustedHostFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLine
    )
    $state = Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine
    if ($state -eq 'MATCH') { return 'ALREADY_REGISTERED' }
    if ($state -ne 'ABSENT') { throw 'BLOCKED: unexpected trust state' }

    # A protected NTFS ACL is applied AT FILE CREATION, not after writing.
    # No Create/overwrite mode: an unexpectedly appearing file blocks.
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $sids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid,$null),
        [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,$null)
    )
    foreach ($sid in $sids) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,[Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }
    $security.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    $bytes = [Text.Encoding]::ASCII.GetBytes($ExpectedLine + [char]10)
    $stream = [IO.FileStream]::new(
        $Path,[IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Modify,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough,$security
    )
    try {
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if ((Get-SentinelTrustStoreState -Path $Path -ExpectedLine $ExpectedLine) -ne 'MATCH') {
        throw 'BLOCKED: trusted host registration did not verify after write'
    }
    return 'REGISTERED'
}

Export-ModuleMember -Function Get-SentinelTrustedHostLine, Get-SentinelTrustStoreState, Register-SentinelTrustedHostFile
