param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$SdkRoot,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$ExpectedVersion,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedCertificateSHA256,
    [string]$BundletoolPath
)

$ErrorActionPreference = 'Stop'

function Get-DropoAabJavaTools {
    $toolsRoot = $env:DROPO_ANDROID_TOOLCHAIN_ROOT
    if (-not $toolsRoot) { $toolsRoot = [Environment]::GetEnvironmentVariable('DROPO_ANDROID_TOOLCHAIN_ROOT', 'User') }
    $jdkPath = $env:JAVA_HOME
    if (-not $jdkPath -and $toolsRoot -and (Test-Path -LiteralPath (Join-Path $toolsRoot 'java'))) {
        $jdkPath = Get-ChildItem -LiteralPath (Join-Path $toolsRoot 'java') -Directory |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin/java.exe') } |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $extension = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { '.exe' } else { '' }
    $resolved = @{}
    foreach ($name in @('java', 'jarsigner')) {
        $candidate = if ($jdkPath) { Join-Path $jdkPath "bin/$name$extension" } else { $null }
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $command = Get-Command "$name$extension" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            $candidate = if ($command) { $command.Source } else { $null }
        }
        if (-not $candidate) { throw 'A JDK 17 or newer with java and jarsigner is required to verify AABs.' }
        $resolved[$name] = $candidate
    }
    return $resolved
}

function Assert-DropoAabManifest {
    param([xml]$Manifest, [string]$Version)
    $namespace = 'http://schemas.android.com/apk/res/android'
    $root = $Manifest.DocumentElement
    if ($root.LocalName -cne 'manifest' -or $root.GetAttribute('package') -cne 'in.droponevedimka.dropo') {
        throw 'Unexpected AAB package. Google Play requires the stable application identity.'
    }
    if ($root.GetAttribute('versionName', $namespace) -cne $Version) { throw 'AAB versionName does not match the expected release.' }
    $parts = $Version.Split('.')
    if ([int]$parts[1] -gt 99 -or [int]$parts[2] -gt 99) { throw 'Android versionCode scheme requires minor and patch below 100.' }
    $expectedCode = [long]$parts[0] * 10000 + [long]$parts[1] * 100 + [long]$parts[2]
    if ($expectedCode -lt 1 -or $expectedCode -gt 2100000000 -or
        $root.GetAttribute('versionCode', $namespace) -cne [string]$expectedCode) {
        throw 'AAB versionCode does not match synchronized release metadata.'
    }
    $sdk = @($root.SelectNodes('uses-sdk'))
    if ($sdk.Count -ne 1 -or $sdk[0].GetAttribute('minSdkVersion', $namespace) -cne '29' -or
        $sdk[0].GetAttribute('targetSdkVersion', $namespace) -cne '36') {
        throw 'AAB must target API 36 and support Android 10+ (minimum API 29).'
    }
    $applications = @($root.SelectNodes('application'))
    if ($applications.Count -ne 1 -or $applications[0].GetAttribute('debuggable', $namespace) -eq 'true' -or
        $applications[0].GetAttribute('testOnly', $namespace) -eq 'true') {
        throw 'AAB must be a non-debuggable, non-test-only release application.'
    }
    $permissions = @($root.SelectNodes('uses-permission | uses-permission-sdk-23') |
        ForEach-Object { $_.GetAttribute('name', $namespace) })
    foreach ($permission in $permissions) {
        if ($permission -ceq 'android.permission.REQUEST_INSTALL_PACKAGES') {
            throw 'Play AAB must not request REQUEST_INSTALL_PACKAGES or implement APK self-updates.'
        }
    }
    foreach ($required in @('android.permission.INTERNET', 'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_SPECIAL_USE')) {
        if ($required -cnotin $permissions) { throw 'AAB is missing a required VPN/foreground service permission.' }
    }
    foreach ($provider in $applications[0].SelectNodes('provider')) {
        if ($provider.GetAttribute('authorities', $namespace).Split(';') -ccontains 'in.droponevedimka.dropo.updates') {
            throw 'Play AAB must not declare the APK update FileProvider.'
        }
    }
    foreach ($data in $root.SelectNodes('queries/intent/data')) {
        if ($data.GetAttribute('mimeType', $namespace) -ieq 'application/vnd.android.package-archive') {
            throw 'Play AAB must not declare APK installer queries.'
        }
    }
    $vpnServices = @($applications[0].SelectNodes('service') | Where-Object {
        $_.GetAttribute('name', $namespace) -cin @('.DropoVpnService', 'in.droponevedimka.dropo.DropoVpnService')
    })
    if ($vpnServices.Count -ne 1 -or
        $vpnServices[0].GetAttribute('permission', $namespace) -cne 'android.permission.BIND_VPN_SERVICE' -or
        $vpnServices[0].GetAttribute('exported', $namespace) -cne 'false' -or
        # aapt/bundletool may render the enum as its exact encoded bit instead
        # of the source name. Additional foreground-service bits are forbidden.
        $vpnServices[0].GetAttribute('foregroundServiceType', $namespace) -cnotin @('specialUse', '0x40000000', '1073741824') -or
        @($vpnServices[0].SelectNodes('intent-filter/action') | Where-Object {
            $_.GetAttribute('name', $namespace) -ceq 'android.net.VpnService'
        }).Count -ne 1) {
        throw 'AAB is missing the protected, non-exported foreground VpnService declaration.'
    }
    return $expectedCode
}

function Assert-DropoAabConfig {
    param([object]$Config)
    if ($Config.optimizations.uncompressNativeLibraries.alignment -cne 'PAGE_ALIGNMENT_16K') {
        throw 'AAB must request PAGE_ALIGNMENT_16K for APKs generated by Google Play.'
    }
}

function Assert-DropoAabElf16KB {
    param([IO.Compression.ZipArchiveEntry]$Entry)
    $reader = [IO.BinaryReader]::new($Entry.Open())
    try {
        $header = $reader.ReadBytes(64)
        if ($header.Length -ne 64 -or [BitConverter]::ToUInt32($header, 0) -ne 0x464C457F -or
            $header[4] -ne 2 -or $header[5] -ne 1 -or [BitConverter]::ToUInt16($header, 18) -ne 183) {
            throw "Expected little-endian ARM64 ELF: $($Entry.FullName)"
        }
        $offset = [BitConverter]::ToUInt64($header, 32)
        $entrySize = [BitConverter]::ToUInt16($header, 54)
        $count = [BitConverter]::ToUInt16($header, 56)
        if ($offset -lt 64 -or $offset -gt 1048576 -or $entrySize -lt 56 -or $count -lt 1 -or $count -gt 256) {
            throw "Invalid ELF program headers: $($Entry.FullName)"
        }
        if ($reader.ReadBytes([int]($offset - 64)).Length -ne [int]($offset - 64)) { throw 'Truncated ELF headers.' }
        $segments = $reader.ReadBytes($entrySize * $count)
        if ($segments.Length -ne $entrySize * $count) { throw 'Truncated ELF segments.' }
        $loads = 0
        for ($index = 0; $index -lt $count; $index++) {
            $start = $entrySize * $index
            if ([BitConverter]::ToUInt32($segments, $start) -ne 1) { continue }
            $loads++
            $alignment = [BitConverter]::ToUInt64($segments, $start + 48)
            $fileOffset = [BitConverter]::ToUInt64($segments, $start + 8)
            $address = [BitConverter]::ToUInt64($segments, $start + 16)
            if ($alignment -lt 16384 -or ($alignment -band ($alignment - 1)) -ne 0 -or
                $fileOffset % 16384 -ne $address % 16384) {
                throw "Native library is not compatible with 16 KB pages: $($Entry.FullName)"
            }
        }
        if ($loads -eq 0) { throw "ELF has no loadable segments: $($Entry.FullName)" }
    } finally { $reader.Dispose() }
}

function Assert-DropoAabContents {
    param([IO.Compression.ZipArchive]$Archive, [string]$RepositoryRoot)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Archive.Entries) {
        if (-not $seen.Add($entry.FullName) -or $entry.FullName -match '(^/|\\|(?:^|/)\.\.(?:/|$))') {
            throw 'AAB contains duplicate or unsafe ZIP paths.'
        }
    }
    $abis = @($Archive.Entries | Where-Object { $_.FullName -match '^base/lib/([^/]+)/[^/]+\.so$' } |
        ForEach-Object { ($_.FullName -split '/')[2] } | Sort-Object -Unique)
    if (($abis -join ',') -cne 'arm64-v8a,armeabi-v7a') { throw 'Play AAB must contain exactly ARM32 and ARM64 native libraries.' }
    foreach ($abi in $abis) {
        foreach ($name in @('libflutter.so', 'libapp.so', 'libgojni.so')) {
            if (-not $Archive.GetEntry("base/lib/$abi/$name")) { throw "AAB is missing $abi/$name" }
        }
    }
    foreach ($entry in $Archive.Entries | Where-Object { $_.FullName -match '^base/lib/arm64-v8a/[^/]+\.so$' }) {
        Assert-DropoAabElf16KB -Entry $entry
    }
    $assetPaths = @('flutter_app/assets/licenses/Xray-core-LICENSE.txt', 'flutter_app/assets/licenses/Xray-core-NOTICE.txt')
    $overlay = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'app/mobile/dropoandroid/xray_overlay/manifest.json') -Raw | ConvertFrom-Json
    if (@($overlay.files).Count -ne 4) { throw 'Corresponding-source manifest is incomplete.' }
    foreach ($file in $overlay.files) {
        if ($file.bundledAssetPath -notmatch '^flutter_app/assets/licenses/xray-core-source/[a-z_]+\.go\.txt$') {
            throw 'Unsafe corresponding-source asset path.'
        }
        if ((Get-FileHash -LiteralPath (Join-Path $RepositoryRoot $file.bundledAssetPath) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.replacementSha256) {
            throw 'Corresponding-source asset does not match its reviewed manifest.'
        }
        $assetPaths += [string]$file.bundledAssetPath
    }
    foreach ($path in $assetPaths) {
        $archivePath = 'base/assets/flutter_assets/' + $path.Substring('flutter_app/'.Length)
        $entry = $Archive.GetEntry($archivePath)
        if (-not $entry -or $entry.Length -lt 1 -or $entry.Length -gt 1048576) { throw "AAB is missing required license/source asset: $archivePath" }
        $stream = $entry.Open()
        $digest = [Security.Cryptography.SHA256]::Create()
        try {
            $actual = [BitConverter]::ToString($digest.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally { $stream.Dispose(); $digest.Dispose() }
        if ($actual -cne (Get-FileHash -LiteralPath (Join-Path $RepositoryRoot $path) -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "AAB license/source bytes do not match reviewed source: $archivePath"
        }
    }
}

$repositoryRoot = Split-Path $PSScriptRoot
$bundlePath = (Resolve-Path -LiteralPath $Path).Path
if ([IO.Path]::GetExtension($bundlePath) -cne '.aab') { throw 'Pass an Android App Bundle (.aab), not an APK or renamed ZIP.' }
if (-not $ExpectedCertificateSHA256) {
    $pinPath = Join-Path $repositoryRoot 'signing/android-upload-cert.sha256'
    if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) {
        throw 'Google Play upload certificate pin is missing. Configure and retain the owner-approved upload key; debug signing is not accepted.'
    }
    $ExpectedCertificateSHA256 = (Get-Content -LiteralPath $pinPath -Raw).Trim()
}
if ($ExpectedCertificateSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid Google Play upload certificate SHA-256 pin.' }
$ExpectedCertificateSHA256 = $ExpectedCertificateSHA256.ToLowerInvariant()
$bundletool = & (Join-Path $PSScriptRoot 'prepare-android-bundletool.ps1') -Path $BundletoolPath
$jdkTools = Get-DropoAabJavaTools
$jarsignerOutput = & $jdkTools.jarsigner '-J-Duser.language=en' '-J-Duser.country=US' -verify -strict -verbose:summary -certs $bundlePath 2>&1
$signerExit = $LASTEXITCODE
# Android upload certificates are normally self-signed/untrusted by the JDK.
# Only that bit is tolerated; unsigned entries (16), usage (8), etc. fail.
# Validity and the exact certificate are verified for every payload below.
if ($signerExit -notin @(0, 4) -or ($jarsignerOutput -join "`n") -notmatch 'jar verified') {
    throw 'AAB JAR signature verification failed or contains unsigned payload.'
}
$signatureOutput = & $jdkTools.java (Join-Path $PSScriptRoot 'android/VerifyBundleSignature.java') $bundlePath $ExpectedCertificateSHA256 2>&1
if ($LASTEXITCODE -ne 0) { throw "AAB upload signer/entry verification failed: $($signatureOutput | Select-Object -Last 3)" }
$validationOutput = & $jdkTools.java -jar $bundletool.Path validate "--bundle=$bundlePath" 2>&1
if ($LASTEXITCODE -ne 0) { throw "bundletool rejected AAB: $($validationOutput | Select-Object -Last 3)" }
$manifestOutput = & $jdkTools.java -jar $bundletool.Path dump manifest "--bundle=$bundlePath" '--module=base' 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect AAB manifest.' }
$manifest = [xml]($manifestOutput -join "`n")
$configOutput = & $jdkTools.java -jar $bundletool.Path dump config "--bundle=$bundlePath" 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect AAB APK-generation configuration.' }
Assert-DropoAabConfig -Config (($configOutput -join "`n") | ConvertFrom-Json)
$version = if ($ExpectedVersion) { $ExpectedVersion } else {
    (Get-Content -LiteralPath (Join-Path $repositoryRoot 'version.json') -Raw | ConvertFrom-Json).version
}
$versionCode = Assert-DropoAabManifest -Manifest $manifest -Version $version
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($bundlePath)
try { Assert-DropoAabContents -Archive $archive -RepositoryRoot $repositoryRoot } finally { $archive.Dispose() }
[pscustomobject]@{
    Path = $bundlePath
    Package = 'in.droponevedimka.dropo'
    Version = $version
    VersionCode = $versionCode
    Distribution = 'Google Play (APK self-update disabled)'
    Android = '10+ (API 29), target 36'
    Architecture = 'universal (armeabi-v7a, arm64-v8a)'
    Native16KB = 'passed'
    GeneratedApk16KB = 'PAGE_ALIGNMENT_16K'
    UploadCertificateSHA256 = $ExpectedCertificateSHA256
    Bytes = (Get-Item -LiteralPath $bundlePath).Length
    SHA256 = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
}
