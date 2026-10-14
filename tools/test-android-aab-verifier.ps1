param([switch]$RunJavaTests)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot
$tokens = $null
$errors = $null
$verifierAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'verify-android-aab.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'AAB verifier syntax failed.' }
foreach ($function in $verifierAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    . ([ScriptBlock]::Create($function.Extent.Text))
}
foreach ($required in @(
    'signing/android-upload-cert.sha256', 'prepare-android-bundletool.ps1',
    'android/VerifyBundleSignature.java', '-verify -strict', 'validate "--bundle=$bundlePath"',
    'dump manifest "--bundle=$bundlePath"', 'dump config "--bundle=$bundlePath"', 'Assert-DropoAabManifest -Manifest',
    'Assert-DropoAabContents -Archive', '$signerExit -notin @(0, 4)',
    'VersionCode = $versionCode'
)) {
    if (-not $verifierAst.Extent.Text.Contains($required)) { throw "AAB verifier entry point is missing: $required" }
}
if ($verifierAst.Extent.Text.Contains('-Download') -or $verifierAst.Extent.Text.Contains('android-release-cert.sha256')) {
    throw 'AAB verifier must never download tools or reuse the app-signing certificate pin.'
}

$manifestText = @'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="in.droponevedimka.dropo" android:versionCode="30047" android:versionName="3.0.47">
  <uses-sdk android:minSdkVersion="29" android:targetSdkVersion="36" />
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
  <application android:label="dropo" android:debuggable="false">
    <service android:name="in.droponevedimka.dropo.DropoVpnService" android:permission="android.permission.BIND_VPN_SERVICE" android:exported="false" android:foregroundServiceType="specialUse">
      <intent-filter><action android:name="android.net.VpnService" /></intent-filter>
    </service>
  </application>
</manifest>
'@
$fixtureCount = 0
function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    $rejected = $false
    try { $null = & $Action } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Invalid AAB fixture was accepted (expected $ExpectedMessage)." }
    $script:fixtureCount++
}
if ((Assert-DropoAabManifest -Manifest ([xml]$manifestText) -Version '3.0.47') -ne 30047) { throw 'AAB manifest positive fixture failed.' }
$fixtureCount++
foreach ($encodedType in @('0x40000000', '1073741824')) {
    $dumpStyle = $manifestText.Replace('android:foregroundServiceType="specialUse"', "android:foregroundServiceType=`"$encodedType`"")
    if ((Assert-DropoAabManifest -Manifest ([xml]$dumpStyle) -Version '3.0.47') -ne 30047) {
        throw 'AAB manifest dump-style foreground-service enum fixture failed.'
    }
    $fixtureCount++
}
foreach ($case in @(
    @('in.droponevedimka.dropo', 'in.droponevedimka.dropo.preview', 'package'),
    @('versionName="3.0.47"', 'versionName="3.0.47-preview"', 'versionName'),
    @('versionCode="30047"', 'versionCode="30046"', 'versionCode'),
    @('minSdkVersion="29"', 'minSdkVersion="28"', 'API 36'),
    @('targetSdkVersion="36"', 'targetSdkVersion="35"', 'API 36'),
    @('debuggable="false"', 'debuggable="true"', 'non-debuggable'),
    @('debuggable="false"', 'debuggable="false" android:testOnly="true"', 'non-debuggable'),
    @('android.permission.INTERNET', 'android.permission.REQUEST_INSTALL_PACKAGES', 'REQUEST_INSTALL_PACKAGES'),
    @('android.permission.FOREGROUND_SERVICE_SPECIAL_USE', 'android.permission.POST_NOTIFICATIONS', 'required VPN'),
    @('android.permission.BIND_VPN_SERVICE', 'android.permission.INTERNET', 'protected'),
    @('android:exported="false"', 'android:exported="true"', 'non-exported'),
    @('android.net.VpnService', 'android.intent.action.VIEW', 'VpnService'),
    @('android:foregroundServiceType="specialUse"', 'android:foregroundServiceType="dataSync"', 'foreground VpnService'),
    @('android:foregroundServiceType="specialUse"', 'android:foregroundServiceType="0x40000001"', 'foreground VpnService'),
    @('android:foregroundServiceType="specialUse"', 'android:foregroundServiceType="1073741825"', 'foreground VpnService'),
    @('android:foregroundServiceType="specialUse"', 'android:foregroundServiceType="specialUse|dataSync"', 'foreground VpnService'),
    @('</application>', '<provider android:name="androidx.core.content.FileProvider" android:authorities="in.droponevedimka.dropo.updates" /></application>', 'update FileProvider'),
    @('</manifest>', '<queries><intent><action android:name="android.intent.action.VIEW" /><data android:mimeType="application/vnd.android.package-archive" /></intent></queries></manifest>', 'installer queries')
)) {
    $modified = $manifestText.Replace($case[0], $case[1])
    Assert-Rejected { Assert-DropoAabManifest -Manifest ([xml]$modified) -Version '3.0.47' } $case[2]
}
$overflow = $manifestText.Replace('3.0.47', '3.0.100')
Assert-Rejected { Assert-DropoAabManifest -Manifest ([xml]$overflow) -Version '3.0.100' } 'below 100'
$validConfig = '{"optimizations":{"uncompressNativeLibraries":{"enabled":true,"alignment":"PAGE_ALIGNMENT_16K"}}}' | ConvertFrom-Json
Assert-DropoAabConfig -Config $validConfig
$fixtureCount++
Assert-Rejected { Assert-DropoAabConfig -Config ('{"optimizations":{"uncompressNativeLibraries":{"alignment":"PAGE_ALIGNMENT_4K"}}}' | ConvertFrom-Json) } 'PAGE_ALIGNMENT_16K'
Assert-Rejected { Assert-DropoAabConfig -Config ('{}' | ConvertFrom-Json) } 'PAGE_ALIGNMENT_16K'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$fixtureRoot = Join-Path $temporaryParent ('dropo-aab-fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

function Set-Bytes {
    param([byte[]]$Destination, [int]$Offset, [byte[]]$Value)
    [Array]::Copy($Value, 0, $Destination, $Offset, $Value.Length)
}
function New-ElfFixture {
    $bytes = [byte[]]::new(120)
    Set-Bytes $bytes 0 ([BitConverter]::GetBytes([uint32]0x464C457F))
    $bytes[4] = 2
    $bytes[5] = 1
    Set-Bytes $bytes 18 ([BitConverter]::GetBytes([uint16]183))
    Set-Bytes $bytes 32 ([BitConverter]::GetBytes([uint64]64))
    Set-Bytes $bytes 54 ([BitConverter]::GetBytes([uint16]56))
    Set-Bytes $bytes 56 ([BitConverter]::GetBytes([uint16]1))
    Set-Bytes $bytes 64 ([BitConverter]::GetBytes([uint32]1))
    Set-Bytes $bytes 112 ([BitConverter]::GetBytes([uint64]16384))
    return ,$bytes
}
function New-ArchiveFixture {
    param([string]$Name, [string]$Omit, [string]$Extra, [byte[]]$ElfBytes, [switch]$TamperLicense)
    $path = Join-Path $fixtureRoot $Name
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = @{}
        foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
            foreach ($library in @('libflutter.so', 'libapp.so', 'libgojni.so')) {
                $files["base/lib/$abi/$library"] = $ElfBytes
            }
        }
        $sourceFiles = @('Xray-core-LICENSE.txt', 'Xray-core-NOTICE.txt',
            'xray-core-source/client.go.txt', 'xray-core-source/dialer.go.txt',
            'xray-core-source/managed_session.go.txt', 'xray-core-source/managed_session_test.go.txt')
        foreach ($source in $sourceFiles) {
            $files["base/assets/flutter_assets/assets/licenses/$source"] = [IO.File]::ReadAllBytes(
                (Join-Path $repositoryRoot "flutter_app/assets/licenses/$source"))
        }
        if ($TamperLicense) { $files['base/assets/flutter_assets/assets/licenses/Xray-core-LICENSE.txt'] = [Text.Encoding]::UTF8.GetBytes('corrupted') }
        foreach ($name in $files.Keys) {
            if ($Omit -and $name -like $Omit) { continue }
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            try { $stream.Write($files[$name], 0, $files[$name].Length) } finally { $stream.Dispose() }
        }
        if ($Extra) {
            $entry = $zip.CreateEntry($Extra)
            $stream = $entry.Open()
            try { $stream.Write($ElfBytes, 0, $ElfBytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $path
}
function Assert-ContentsFixture {
    param([string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try { Assert-DropoAabContents -Archive $zip -RepositoryRoot $repositoryRoot } finally { $zip.Dispose() }
}
function Invoke-FixtureJavaVerifier {
    param([string]$Path, [string]$Fingerprint, [bool]$ShouldPass)
    $output = & $jdkTools.java (Join-Path $PSScriptRoot 'android/VerifyBundleSignature.java') $Path $Fingerprint 2>&1
    if (($LASTEXITCODE -eq 0) -ne $ShouldPass) { throw "AAB cryptographic fixture failed: $($output | Select-Object -Last 3)" }
    $script:fixtureCount++
}

try {
    $elf = New-ElfFixture
    $validPath = New-ArchiveFixture -Name 'valid.aab' -ElfBytes $elf
    Assert-ContentsFixture $validPath
    $fixtureCount++
    foreach ($case in @(
        @('missing-arm32.aab', 'base/lib/armeabi-v7a/*', 'exactly ARM32'),
        @('missing-app.aab', 'base/lib/arm64-v8a/libapp.so', 'missing arm64-v8a/libapp.so'),
        @('missing-license.aab', 'base/assets/flutter_assets/assets/licenses/Xray-core-LICENSE.txt', 'required license'),
        @('missing-source.aab', 'base/assets/flutter_assets/assets/licenses/xray-core-source/dialer.go.txt', 'required license')
    )) {
        $path = New-ArchiveFixture -Name $case[0] -Omit $case[1] -ElfBytes $elf
        Assert-Rejected { Assert-ContentsFixture $path } $case[2]
    }
    $path = New-ArchiveFixture -Name 'wrong-abi.aab' -Extra 'base/lib/x86_64/libgojni.so' -ElfBytes $elf
    Assert-Rejected { Assert-ContentsFixture $path } 'exactly ARM32'
    $path = New-ArchiveFixture -Name 'bad-path.aab' -Extra 'base/../escape' -ElfBytes $elf
    Assert-Rejected { Assert-ContentsFixture $path } 'unsafe ZIP'
    $path = New-ArchiveFixture -Name 'duplicate.aab' -Extra 'base/lib/arm64-v8a/libapp.so' -ElfBytes $elf
    Assert-Rejected { Assert-ContentsFixture $path } 'duplicate'
    $path = New-ArchiveFixture -Name 'tampered-license.aab' -ElfBytes $elf -TamperLicense
    Assert-Rejected { Assert-ContentsFixture $path } 'license/source bytes'
    foreach ($case in @(
        @('4kb.aab', 112, [BitConverter]::GetBytes([uint64]4096), '16 KB'),
        @('non-power-alignment.aab', 112, [BitConverter]::GetBytes([uint64]24576), '16 KB'),
        @('unaligned.aab', 72, [BitConverter]::GetBytes([uint64]4096), '16 KB'),
        @('no-load.aab', 64, [BitConverter]::GetBytes([uint32]0), 'no loadable'),
        @('bad-offset.aab', 32, [BitConverter]::GetBytes([uint64]1048577), 'program headers'),
        @('wrong-machine.aab', 18, [BitConverter]::GetBytes([uint16]62), 'ARM64 ELF')
    )) {
        $modified = [byte[]]$elf.Clone()
        Set-Bytes $modified $case[1] $case[2]
        $path = New-ArchiveFixture -Name $case[0] -ElfBytes $modified
        Assert-Rejected { Assert-ContentsFixture $path } $case[3]
    }
    $invalidTool = Join-Path $fixtureRoot 'bundletool-invalid.jar'
    [IO.File]::WriteAllBytes($invalidTool, [byte[]]@(1, 2, 3))
    Assert-Rejected { & (Join-Path $PSScriptRoot 'prepare-android-bundletool.ps1') -Path $invalidTool } 'reviewed version and SHA-256'
    $missingTool = Join-Path $fixtureRoot 'bundletool-missing.jar'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'prepare-android-bundletool.ps1') -Path $missingTool } 'build preparation'
    if (Test-Path -LiteralPath $missingTool) { throw 'AAB verifier silently downloaded bundletool.' }

    if ($RunJavaTests) {
        $jdkTools = Get-DropoAabJavaTools
        $extension = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { '.exe' } else { '' }
        $keytool = Join-Path (Split-Path $jdkTools.java) "keytool$extension"
        $keystore = Join-Path $fixtureRoot 'ephemeral.jks'
        foreach ($identity in @(@('upload', 'CN=Dropo AAB Test'), @('debug', 'CN=Android Debug'))) {
            $output = & $keytool -genkeypair -keystore $keystore -storepass dropo-fixture-only -keypass dropo-fixture-only -alias $identity[0] -dname $identity[1] -keyalg RSA -keysize 2048 -validity 2 -noprompt 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Cannot generate isolated fixture signing key.' }
        }
        $certificate = Join-Path $fixtureRoot 'fixture-certificate.der'
        $output = & $keytool -exportcert -keystore $keystore -storepass dropo-fixture-only -alias upload -file $certificate 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Cannot export fixture public certificate.' }
        $fingerprint = (Get-FileHash -LiteralPath $certificate -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-FixtureJavaVerifier $validPath $fingerprint $false
        $signed = Join-Path $fixtureRoot 'signed.aab'
        Copy-Item -LiteralPath $validPath -Destination $signed
        $output = & $jdkTools.jarsigner -keystore $keystore -storepass dropo-fixture-only -keypass dropo-fixture-only $signed upload 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Cannot sign isolated AAB fixture.' }
        Invoke-FixtureJavaVerifier $signed $fingerprint $true
        Invoke-FixtureJavaVerifier $signed ('0' * 64) $false
        $appended = Join-Path $fixtureRoot 'appended.aab'
        Copy-Item -LiteralPath $signed -Destination $appended
        $zip = [IO.Compression.ZipFile]::Open($appended, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $zip.CreateEntry('META-INF/unsigned-payload.txt')
            $stream = $entry.Open()
            try { $stream.WriteByte(42) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        Invoke-FixtureJavaVerifier $appended $fingerprint $false
        $tampered = Join-Path $fixtureRoot 'tampered.aab'
        Copy-Item -LiteralPath $signed -Destination $tampered
        $zip = [IO.Compression.ZipFile]::Open($tampered, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $zip.GetEntry('base/lib/arm64-v8a/libapp.so').Delete()
            $entry = $zip.CreateEntry('base/lib/arm64-v8a/libapp.so')
            $stream = $entry.Open()
            try { $stream.WriteByte(42) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        Invoke-FixtureJavaVerifier $tampered $fingerprint $false
        $debug = Join-Path $fixtureRoot 'debug.aab'
        Copy-Item -LiteralPath $validPath -Destination $debug
        $output = & $jdkTools.jarsigner -keystore $keystore -storepass dropo-fixture-only -keypass dropo-fixture-only $debug debug 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Cannot sign debug fixture.' }
        $output = & $keytool -exportcert -keystore $keystore -storepass dropo-fixture-only -alias debug -file $certificate 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Cannot export debug fixture certificate.' }
        $debugFingerprint = (Get-FileHash -LiteralPath $certificate -Algorithm SHA256).Hash.ToLowerInvariant()
        Invoke-FixtureJavaVerifier $debug $debugFingerprint $false
    }
    Write-Host "Android AAB verifier passed ($fixtureCount manifest, ABI, ELF, source, tool-pin and signing fixtures; Java signing: $RunJavaTests)."
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($temporaryParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedFixture -Leaf) -notmatch '^dropo-aab-fixtures-[a-f0-9]{32}$') {
        throw 'Refusing to remove an unexpected Android AAB fixture directory.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
