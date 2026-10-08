param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$SdkRoot,
    [ValidateSet("arm64", "universal")][string]$Architecture = "arm64",
    [switch]$Preview
)
$ErrorActionPreference = "Stop"
$apkPath = (Resolve-Path -LiteralPath $Path).Path
$androidToolsRoot = $env:DROPO_ANDROID_TOOLCHAIN_ROOT
if (-not $androidToolsRoot) { $androidToolsRoot = [Environment]::GetEnvironmentVariable("DROPO_ANDROID_TOOLCHAIN_ROOT", "User") }
if (-not $SdkRoot) { $SdkRoot = $env:ANDROID_HOME }
if (-not $SdkRoot -and $androidToolsRoot) { $SdkRoot = Join-Path $androidToolsRoot "sdk" }
if (-not $SdkRoot) { throw "Pass -SdkRoot or configure the Android toolchain." }
if (-not $env:JAVA_HOME -and $androidToolsRoot) {
    $jdk = Get-ChildItem -LiteralPath (Join-Path $androidToolsRoot "java") -Directory |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "bin\java.exe") } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
$buildTools = Join-Path $SdkRoot "build-tools\36.0.0"
foreach ($tool in @("aapt2.exe", "apksigner.bat", "zipalign.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $buildTools $tool))) { throw "Missing Android build tool: $tool" }
}
$badging = & (Join-Path $buildTools "aapt2.exe") dump badging $apkPath
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect APK metadata." }
$packageLine = $badging | Where-Object { $_ -match '^package:' } | Select-Object -First 1
$expectedPackage = "in.droponevedimka.dropo" + $(if ($Preview) { ".preview" } else { "" })
if ($packageLine -notmatch "name='$([regex]::Escape($expectedPackage))'") { throw "Unexpected APK package: $packageLine" }
$minimumLine = $badging | Where-Object { $_ -match '^(minSdkVersion|sdkVersion):' } | Select-Object -First 1
if ($minimumLine -notmatch "^(minSdkVersion|sdkVersion):'29'$") { throw "Unexpected minimum Android version: $minimumLine" }
$targetLine = $badging | Where-Object { $_ -match '^targetSdkVersion:' } | Select-Object -First 1
if ($targetLine -ne "targetSdkVersion:'36'") { throw "Unexpected target Android version: $targetLine" }
$repositoryRoot = Split-Path $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot "version.json") -Raw | ConvertFrom-Json).version
$expectedVersion = [string]$version + $(if ($Preview) { "-preview" } else { "" })
if ($packageLine -notmatch "versionName='$([regex]::Escape($expectedVersion))'") { throw "APK version does not match project metadata: $packageLine" }
& (Join-Path $buildTools "apksigner.bat") verify --verbose $apkPath
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed." }
$alignmentOutput = & (Join-Path $buildTools "zipalign.exe") -c -P 16 -v 4 $apkPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "APK ZIP alignment failed: $($alignmentOutput | Select-Object -Last 3)" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($apkPath)
try {
    $abis = @("arm64-v8a")
    if ($Architecture -eq "universal") { $abis += "armeabi-v7a" }
    foreach ($abi in $abis) {
        foreach ($library in @("libflutter.so", "libapp.so", "libgojni.so")) {
            if (-not $archive.GetEntry("lib/$abi/$library")) { throw "APK is missing $abi/$library" }
        }
    }
    $libraries = @($archive.Entries | Where-Object { $_.FullName -match '^lib/(arm64-v8a|x86_64)/.+\.so$' })
    foreach ($entry in $libraries) {
        $stream = $entry.Open()
        $reader = [IO.BinaryReader]::new($stream)
        try {
            $header = $reader.ReadBytes(64)
            if ($header.Length -ne 64 -or [BitConverter]::ToUInt32($header, 0) -ne 0x464C457F -or $header[4] -ne 2 -or $header[5] -ne 1) {
                throw "Expected little-endian ELF64: $($entry.FullName)"
            }
            $offset = [BitConverter]::ToUInt64($header, 32)
            $entrySize = [BitConverter]::ToUInt16($header, 54)
            $count = [BitConverter]::ToUInt16($header, 56)
            if ($offset -lt 64 -or $offset -gt 1048576 -or $entrySize -lt 56 -or $count -lt 1 -or $count -gt 256) {
                throw "Invalid ELF program headers: $($entry.FullName)"
            }
            if ($reader.ReadBytes([int]($offset - 64)).Length -ne [int]($offset - 64)) { throw "Truncated ELF headers." }
            $segments = $reader.ReadBytes($entrySize * $count)
            if ($segments.Length -ne $entrySize * $count) { throw "Truncated ELF segments." }
            $loads = 0
            for ($i = 0; $i -lt $count; $i++) {
                $start = $entrySize * $i
                if ([BitConverter]::ToUInt32($segments, $start) -ne 1) { continue }
                $loads++
                $alignment = [BitConverter]::ToUInt64($segments, $start + 48)
                $fileOffset = [BitConverter]::ToUInt64($segments, $start + 8)
                $address = [BitConverter]::ToUInt64($segments, $start + 16)
                if ($alignment -lt 16384 -or $fileOffset % 16384 -ne $address % 16384) {
                    throw "Native library is not compatible with 16 KB pages: $($entry.FullName)"
                }
            }
            if ($loads -eq 0) { throw "ELF has no loadable segments: $($entry.FullName)" }
        } finally { $reader.Dispose(); $stream.Dispose() }
    }
} finally { $archive.Dispose() }
$apk = Get-Item -LiteralPath $apkPath
[pscustomobject]@{
    Path = $apkPath
    Package = $expectedPackage
    Version = $expectedVersion
    Android = "10+ (API 29), target 36"
    Architecture = $Architecture
    Native16KB = "passed"
    Bytes = $apk.Length
    SHA256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
