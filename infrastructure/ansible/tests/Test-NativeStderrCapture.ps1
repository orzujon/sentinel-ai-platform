#Requires -Version 5.1
# Regression for Windows PowerShell 5.1 native stderr redirection and exit status.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NativeCapture {
    param([string]$NativeCommand)
    $original = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& cmd.exe /d /c $NativeCommand 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $original
    }
    return [pscustomobject]@{ Lines = $output; ExitCode = $exitCode }
}

$warning = Invoke-NativeCapture 'echo sentinel-warning 1>&2'
if ($warning.ExitCode -ne 0 -or -not (($warning.Lines -join ' ') -match 'sentinel-warning')) {
    throw 'Warning on native stderr was not captured as text'
}
$failure = Invoke-NativeCapture 'echo sentinel-failure 1>&2 & exit /b 7'
if ($failure.ExitCode -ne 7 -or -not (($failure.Lines -join ' ') -match 'sentinel-failure')) {
    throw 'Native process failure must still propagate via exit code'
}

$wrapper = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Invoke-SentinelReadiness.ps1') -Raw
if ($wrapper -notmatch 'wsl\.exe @wslArgs 2>&1' -or $wrapper -notmatch '\$exitCode = \$LASTEXITCODE') {
    throw 'Native stderr handling or exit-code gate missing from actual wrapper'
}
$global:LASTEXITCODE = 0
Write-Host 'PASS: native stderr warnings are loggable; real process failures remain blocked'
