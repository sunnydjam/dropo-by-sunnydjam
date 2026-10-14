$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot
function Read-ScriptAst([string]$RelativePath) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot $RelativePath), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Android build script parsing failed.' }
    return $ast
}
$buildAst = Read-ScriptAst 'scripts/build/build.ps1'
$verifyAst = Read-ScriptAst 'tools/verify-android-apk.ps1'
$androidFunction = @($buildAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Build-AndroidApplication'
}, $true))
if ($androidFunction.Count -ne 1) { throw 'Android build entry point missing.' }
$body = $androidFunction[0].Extent.Text
foreach ($required in @(
    '$UseCachedFlutterPackages', '& $FlutterCmd pub get --offline',
    "`$androidBuildArguments += '--no-pub'", '"-ExpectedVersion", $AppVersion',
    'Get-DropoAccountBuildArguments -Endpoint $AccountEndpoint'
)) {
    if (-not $body.Contains($required)) { throw 'Android build option integration missing.' }
}
$parameter = @($verifyAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedVersion' })
if ($parameter.Count -ne 1 -or -not $parameter[0].Extent.Text.Contains('ValidatePattern')) {
    throw 'APK verifier expected-version parameter missing validation.'
}
if (-not $verifyAst.Extent.Text.Contains('$version = if ($ExpectedVersion) { $ExpectedVersion } else {') -or
    -not $verifyAst.Extent.Text.Contains('version.json')) {
    throw 'APK verifier must preserve the default metadata version.'
}
$suffixAssignment = @($verifyAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$expectedVersionName'
}, $true))
if ($suffixAssignment.Count -ne 1) { throw 'APK verifier version suffix expression missing.' }
foreach ($case in @(@('3.0.41', $false, '3.0.41'), @('3.0.42', $true, '3.0.42-preview'))) {
    $version = $case[0]
    $Preview = $case[1]
    . ([ScriptBlock]::Create($suffixAssignment[0].Extent.Text))
    if ($expectedVersionName -cne $case[2]) { throw 'APK verifier version override fixture failed.' }
}
function Get-BuildFunctionAst([string]$Name) {
    $functions = @($buildAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    if ($functions.Count -ne 1) { throw "Android build function missing: $Name" }
    return $functions[0]
}
foreach ($name in @('Get-DropoAccountBuildArguments', 'Get-DropoAndroidBundleBuildArguments', 'Get-AndroidBuildNumber', 'Write-DropoAndroidBuildMetadata')) {
    . ([ScriptBlock]::Create((Get-BuildFunctionAst $name).Extent.Text))
}
if (@($buildAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AndroidBundle' }).Count -ne 1) {
    throw 'Explicit AndroidBundle build option missing.'
}
$bundleArguments = @(Get-DropoAndroidBundleBuildArguments -AppVersion '3.0.47' -BuildNumber 30047 -Endpoint 'https://accounts.example.com')
$expectedBundleArguments = @(
    'build', 'appbundle', '--release',
    '--target-platform', 'android-arm,android-arm64',
    '--build-name', '3.0.47', '--build-number', '30047',
    '--dart-define', 'DROPO_APP_VERSION=3.0.47',
    '--dart-define', 'DROPO_PLAY_DISTRIBUTION=true',
    '--dart-define', 'DROPO_ACCOUNT_ENDPOINT=https://accounts.example.com'
)
if (($bundleArguments -join "`n") -cne ($expectedBundleArguments -join "`n")) {
    throw 'Google Play bundle command fixture failed (release, ABI, version or account/channel define).'
}
if ($bundleArguments -contains '--profile' -or $bundleArguments -contains '--debug') {
    throw 'Google Play bundles must never use profile/debug signing.'
}
$bundleBody = (Get-BuildFunctionAst 'Build-AndroidAppBundle').Extent.Text
foreach ($required in @(
    "tools\prepare-android-bundletool.ps1') -Download", 'Build-AndroidBridgeAAR',
    "tools\verify-android-aab.ps1'", "'-BundletoolPath', `$bundletool.Path",
    'Get-DropoAndroidBundleBuildArguments', '$UseCachedFlutterPackages',
    '& $FlutterCmd pub get --offline', "`$androidBundleArguments += '--no-pub'",
    'Write-DropoAndroidBuildMetadata', "-Channel 'play'",
    'build\app\outputs\bundle\release\app-release.aab'
)) {
    if (-not $bundleBody.Contains($required)) { throw "Google Play bundle integration missing: $required" }
}
foreach ($required in @(
    'DROPO_PLAY_DISTRIBUTION=false', 'Write-DropoAndroidBuildMetadata'
)) {
    if (-not $body.Contains($required)) { throw "APK channel isolation missing: $required" }
}
if ($bundleBody.Contains('ORG_GRADLE_PROJECT_dropoPlayDistribution') -or
    $body.Contains('ORG_GRADLE_PROJECT_dropoPlayDistribution')) {
    throw 'Distribution must use the same explicit Flutter Dart define, never an environment-only Gradle selector.'
}
$gradleSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'flutter_app/android/app/build.gradle.kts') -Raw
foreach ($required in @(
    'dropoDistributionDefine(gradle.startParameter.projectProperties["dart-defines"])',
    'gradle.startParameter.projectProperties["dropoPlayDistribution"]',
    'explicitPlayDistribution != dartPlayDistribution', 'dartPlayDistribution ?: false',
    'playBundleRequested && dartPlayDistribution != true', 'Base64.getDecoder()',
    'CodingErrorAction.REPORT', 'selected != null'
)) {
    if (-not $gradleSource.Contains($required)) { throw "Native/Dart distribution consistency missing: $required" }
}
if ($gradleSource.Contains('findProperty("dropoPlayDistribution")')) {
    throw 'Native channel must not read a daemon/environment-backed distribution property.'
}

# Execute the actual ABI-selection expression with both artifact combinations,
# without importing the full build script or invoking native build/runtime code.
$targetAssignment = @($buildAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$AndroidGoMobileTarget'
}, $true))
if ($targetAssignment.Count -ne 1) { throw 'Android bridge ABI selector missing.' }
foreach ($case in @(
    @{ Bundle = $false; Architecture = 'arm64'; Target = 'android/arm64' },
    @{ Bundle = $false; Architecture = 'universal'; Target = 'android/arm,android/arm64' },
    @{ Bundle = $true; Architecture = 'arm64'; Target = 'android/arm,android/arm64' },
    @{ Bundle = $true; Architecture = 'universal'; Target = 'android/arm,android/arm64' }
)) {
    $willBuildAndroidBundle = $case.Bundle
    $AndroidArchitecture = $case.Architecture
    . ([ScriptBlock]::Create($targetAssignment[0].Extent.Text))
    if ($AndroidGoMobileTarget -cne $case.Target) { throw 'Google Play bundle ABI coverage fixture failed.' }
}
$windowsAssignment = @($buildAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$willBuildWindows'
}, $true))
if ($windowsAssignment.Count -ne 1) { throw 'Windows build selection missing.' }
$Build = $Flutter = $AppOnly = $All = $Portable = $Android = $Clean = $false
$AndroidBundle = $true
. ([ScriptBlock]::Create($windowsAssignment[0].Extent.Text))
if ($willBuildWindows) { throw 'AAB-only build must not implicitly build or package Windows.' }

$mainDispatch = @($buildAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if ($AppOnly)')
})
if ($mainDispatch.Count -ne 1) { throw 'Combined artifact dispatch missing.' }
function Build-Application { $script:windowsCalls++ }
function Build-AndroidApplication { $script:apkCalls++ }
function Build-AndroidAppBundle { $script:bundleCalls++ }
function Create-Portable { $script:portableCalls++ }
foreach ($case in @(
    @{ Bundle = $true; Apk = $false; Windows = $false; AllArtifacts = $false; AppOnlyBuild = $false; Expected = '0,0,1,0' },
    @{ Bundle = $true; Apk = $true; Windows = $false; AllArtifacts = $false; AppOnlyBuild = $false; Expected = '0,1,1,0' },
    @{ Bundle = $true; Apk = $false; Windows = $true; AllArtifacts = $false; AppOnlyBuild = $false; Expected = '1,0,1,0' },
    @{ Bundle = $true; Apk = $true; Windows = $false; AllArtifacts = $true; AppOnlyBuild = $false; Expected = '1,1,1,0' },
    @{ Bundle = $true; Apk = $true; Windows = $false; AllArtifacts = $true; AppOnlyBuild = $true; Expected = '1,1,1,0' }
)) {
    $AndroidBundle = $case.Bundle
    $Android = $case.Apk
    $Build = $case.Windows
    $All = $case.AllArtifacts
    $AppOnly = $case.AppOnlyBuild
    $Flutter = $Portable = $false
    $script:windowsCalls = $script:apkCalls = $script:bundleCalls = $script:portableCalls = 0
    . ([ScriptBlock]::Create($mainDispatch[0].Extent.Text))
    $observed = @($script:windowsCalls, $script:apkCalls, $script:bundleCalls, $script:portableCalls) -join ','
    if ($observed -cne $case.Expected) { throw 'Combined Windows/APK/AAB dispatch fixture failed.' }
}

$AppVersion = '3.0.47'
$SourceRevision = 'a' * 40
$SourceDirty = $true
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('dropo-build-metadata-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
$artifactPath = Join-Path $fixtureDirectory 'dropo-Android-Play-universal.aab'
$metadataPath = "$artifactPath.build.json"
try {
    Write-DropoAndroidBuildMetadata -ArtifactPath $artifactPath -ArtifactSHA256 ('b' * 64) `
        -Channel 'play' -PackageName 'in.droponevedimka.dropo' -Architecture 'universal'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.artifactName -cne 'dropo-Android-Play-universal.aab' -or
        $metadata.sourceRevision -cne $SourceRevision -or -not $metadata.sourceDirty -or
        $metadata.sha256 -cne ('b' * 64) -or $metadata.channel -cne 'play' -or
        $metadata.packageName -cne 'in.droponevedimka.dropo' -or
        $metadata.version -cne '3.0.47' -or $metadata.versionCode -ne 30047 -or
        $metadata.architecture -cne 'universal') {
        throw 'Android artifact metadata provenance fixture failed.'
    }
} finally {
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) { Remove-Item -LiteralPath $metadataPath -Force }
    Remove-Item -LiteralPath $fixtureDirectory -Force
}
Write-Host 'Android build options passed (APK channel isolation, release AAB, ARM32/ARM64, exact metadata and combined artifact dispatch).'
