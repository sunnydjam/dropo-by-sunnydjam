# Google Play build entry point. The public account-service origin also serves
# the anonymous Dropo Free offer; leaving it empty removes that offer on a fresh
# installation. No private subscription URL or credential is embedded here.
[CmdletBinding()]
param(
    [string]$Version,
    [string]$AccountEndpoint = 'https://dropo.fun',
    [switch]$AllowDirtySource,
    [switch]$KeepExistingBuilds = $true,
    [switch]$UseCachedFlutterPackages
)

$ErrorActionPreference = 'Stop'
$buildArguments = @{
    AndroidBundle = $true
    AndroidArchitecture = 'universal'
    AccountEndpoint = $AccountEndpoint
    AllowDirtySource = $AllowDirtySource
    KeepExistingBuilds = $KeepExistingBuilds
    UseCachedFlutterPackages = $UseCachedFlutterPackages
}
if ($Version) { $buildArguments.Version = $Version }
& (Join-Path $PSScriptRoot '../scripts/build/build.ps1') @buildArguments
