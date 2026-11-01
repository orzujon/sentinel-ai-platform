#Requires -Version 5.1
# Pure parser and path conversion contract; does not call WSL or any VM.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Sentinel.WslPaths.psm1') -Force
$actual = ConvertTo-SentinelWslMountPath 'C:\Users\Orzu\projects\sentinel-ai-platform\infrastructure\level1\tools\..\src\prepare-disk-and-seed.sh'
$expected = '/mnt/c/Users/Orzu/projects/sentinel-ai-platform/infrastructure/level1/src/prepare-disk-and-seed.sh'
if ($actual -cne $expected) { throw "WSL path conversion mismatch: $actual" }
$cache = ConvertTo-SentinelWslMountPath 'C:\Sentinel\ImageCache\ubuntu\26.04\20261016\sha.img'
if ($cache -cne '/mnt/c/Sentinel/ImageCache/ubuntu/26.04/20261016/sha.img') {
    throw "Image path conversion mismatch: $cache"
}
function Require-Blocked([string]$path) {
    try {
        ConvertTo-SentinelWslMountPath $path | Out-Null
        throw 'Expected path rejection'
    } catch {
        if ([string]$_.Exception.Message -eq 'Expected path rejection') { throw }
        if ([string]$_.Exception.Message -notmatch 'BLOCKED') { throw }
    }
}
Require-Blocked '\\example\share\not-local.img'
Require-Blocked ('C:\Sentinel\safe\bad' + "`n" + 'path')
Write-Host 'PASS: Stage 5.3 WSL path conversion produces valid /mnt/c paths without invoking bash'
