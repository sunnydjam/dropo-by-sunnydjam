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
Write-Host 'Android build options passed (offline pub, CLI version override, Preview suffix and metadata fallback).'
