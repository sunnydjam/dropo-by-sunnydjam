param(
    [string]$Path,
    [string]$CacheDirectory,
    [switch]$Download
)

$ErrorActionPreference = 'Stop'
# Build-time only. Never shipped to clients or downloaded by the VPN runtime.
# Source: https://github.com/google/bundletool/releases/tag/1.18.3
$version = '1.18.3'
$expectedSHA256 = 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29'
$expectedBytes = 32520401
$downloadUrl = "https://github.com/google/bundletool/releases/download/$version/bundletool-all-$version.jar"
if (-not $CacheDirectory) {
    $CacheDirectory = Join-Path (Split-Path $PSScriptRoot) '.toolchain/android'
}
if (-not $Path) { $Path = Join-Path $CacheDirectory "bundletool-all-$version.jar" }
$bundletoolPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $bundletoolPath -PathType Leaf)) {
    if (-not $Download) {
        throw 'Pinned bundletool is missing. Run tools/prepare-android-bundletool.ps1 -Download as a build preparation step.'
    }
    $parentDirectory = Split-Path $bundletoolPath -Parent
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    $temporaryPath = Join-Path $parentDirectory ('bundletool-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryPath -TimeoutSec 120
        if ((Get-Item -LiteralPath $temporaryPath).Length -ne $expectedBytes -or
            (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedSHA256) {
            throw 'Downloaded bundletool did not match the reviewed version and SHA-256.'
        }
        # Fail rather than replacing an existing cache entry produced concurrently.
        [IO.File]::Move($temporaryPath, $bundletoolPath)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}
if ((Get-Item -LiteralPath $bundletoolPath).Length -ne $expectedBytes -or
    (Get-FileHash -LiteralPath $bundletoolPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedSHA256) {
    throw 'Local bundletool did not match the reviewed version and SHA-256. It was not executed or overwritten.'
}
[pscustomobject]@{ Path = $bundletoolPath; Version = $version; SHA256 = $expectedSHA256 }
