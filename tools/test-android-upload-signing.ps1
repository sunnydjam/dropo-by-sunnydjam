$ErrorActionPreference = 'Stop'
$initializer = Join-Path $PSScriptRoot 'initialize-android-upload-signing.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($initializer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Upload-signing initializer syntax failed.' }
$source = $ast.Extent.Text
foreach ($required in @(
    "if (-not `$Create)", "if (-not `$IsWindows)",
    '[IO.Path]::IsPathRooted($SigningDirectory)', '[IO.Path]::GetPathRoot($directory)',
    'Private signing material must stay outside the repository.',
    'refusing to overwrite a permanent identity.',
    'Get-ChildItem -LiteralPath $directory -Force', '$ancestor = $ancestor.Parent',
    '[IO.FileAttributes]::ReparsePoint', '$acl.SetAccessRuleProtection($true, $false)',
    "'S-1-5-18'", "'S-1-5-32-544'", '[IO.FileMode]::CreateNew',
    '[IO.FileShare]::None', '$stream.Flush($true)',
    '[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)',
    '-storepass:env DROPO_UPLOAD_KEYTOOL_PASSWORD', '-keypass:env DROPO_UPLOAD_KEYTOOL_PASSWORD',
    "[Environment]::SetEnvironmentVariable('DROPO_UPLOAD_KEYTOOL_PASSWORD', `$previousPassword, 'Process')",
    '[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem',
    '$password = $null', '$content = $null', '$bytes = $null'
)) {
    if (-not $source.Contains($required)) { throw "Upload-signing safety contract missing: $required" }
}
$generateOffset = $source.IndexOf('& $keytool -genkeypair', [StringComparison]::Ordinal)
$flushOffset = $source.IndexOf('$stream.Flush($true)', [StringComparison]::Ordinal)
$exclusiveOffset = $source.IndexOf('[IO.FileMode]::CreateNew', [StringComparison]::Ordinal)
$aclOffset = $source.IndexOf('Set-Acl -LiteralPath $directory', [StringComparison]::Ordinal)
$ancestorOffset = $source.IndexOf('while ($null -ne $ancestor)', [StringComparison]::Ordinal)
if ($generateOffset -lt 0 -or $flushOffset -lt 0 -or $exclusiveOffset -lt 0 -or
    $exclusiveOffset -ge $flushOffset -or $flushOffset -ge $generateOffset -or
    $aclOffset -ge $exclusiveOffset -or $ancestorOffset -ge $aclOffset) {
    throw 'Upload signing must validate paths, protect ACLs, and persist exclusive recovery properties before key generation.'
}
foreach ($command in $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst]
}, $true)) {
    $text = $command.Extent.Text
    if ($text.StartsWith('& $keytool', [StringComparison]::Ordinal) -and
        ($text -match '-(?:storepass|keypass)\s' -or $text -match '\$(password|content|bytes)\b')) {
        throw 'A signing password must not enter native command-line arguments.'
    }
    if ($command.GetCommandName() -match '^(Write-(Host|Output|Verbose|Debug|Information)|Out-(Host|String))$' -and
        $text -match '\$(password|content|bytes|output)\b') {
        throw 'Upload signing must not print private material or raw keytool output.'
    }
}
$returnObjects = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.ConvertExpressionAst] -and
        $node.Type.TypeName.FullName -eq 'pscustomobject'
}, $true))
if ($returnObjects.Count -ne 1 -or $returnObjects[0].Extent.Text -match '\$(password|content|bytes|output)\b') {
    throw 'Upload signing must return only public certificate metadata and local file references.'
}

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$fixtureRoot = Join-Path $temporaryParent ('dropo-upload-signing-fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$caseCount = 1
$junctionPath = $null
function Assert-SigningRejected {
    param([hashtable]$Arguments, [string]$ExpectedMessage)
    $rejected = $false
    try { $null = & $initializer @Arguments } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Unsafe upload-signing request was accepted.' }
    $script:caseCount++
}
try {
    Assert-SigningRejected @{ SigningDirectory = (Join-Path $fixtureRoot 'owner-gated') } 'owner authorizes'
    if ($IsWindows) {
        $fakeJdk = Join-Path $fixtureRoot 'fake-jdk'
        $fakeBin = Join-Path $fakeJdk 'bin'
        New-Item -ItemType Directory -Path $fakeBin | Out-Null
        $fakeKeytool = Join-Path $fakeBin 'keytool.exe'
        # This is deliberately not executable. Every fixture must reject before
        # invoking it; no test creates, imports, exports, or replaces a real key.
        [IO.File]::WriteAllBytes($fakeKeytool, [byte[]]@(1, 2, 3))
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = 'relative-signing' } 'must be absolute'
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = [IO.Path]::GetPathRoot($fixtureRoot) } 'not a drive root'
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = (Split-Path $PSScriptRoot) } 'outside the repository'
        $collection = Join-Path $fixtureRoot 'existing-collection'
        New-Item -ItemType Directory -Path $collection | Out-Null
        $sentinel = Join-Path $collection 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'retained fixture bytes')
        $originalAcl = (Get-Acl -LiteralPath $collection).Sddl
        $originalHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = $collection } 'new or empty'
        if ((Get-Acl -LiteralPath $collection).Sddl -cne $originalAcl -or
            (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -cne $originalHash) {
            throw 'Rejected signing request modified an existing directory or its contents.'
        }
        foreach ($name in @('dropo-upload.keystore', 'android-upload-signing.properties', 'dropo-upload-cert.pem')) {
            $existingIdentity = Join-Path $fixtureRoot ('existing-' + $caseCount)
            New-Item -ItemType Directory -Path $existingIdentity | Out-Null
            $existingPath = Join-Path $existingIdentity $name
            [IO.File]::WriteAllBytes($existingPath, [byte[]]@(4, 5, 6))
            $originalHash = (Get-FileHash -LiteralPath $existingPath -Algorithm SHA256).Hash
            Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = $existingIdentity } 'refusing to overwrite'
            if ((Get-FileHash -LiteralPath $existingPath -Algorithm SHA256).Hash -cne $originalHash) {
                throw 'Rejected signing request overwrote an existing identity.'
            }
        }
        $junctionTarget = Join-Path $fixtureRoot 'junction-target'
        $junctionPath = Join-Path $fixtureRoot 'linked-directory'
        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = $junctionPath } 'reparse points'
        Assert-SigningRejected @{ Create = $true; JavaHome = $fakeJdk; SigningDirectory = (Join-Path $junctionPath 'new-child') } 'reparse points'
        if (@(Get-ChildItem -LiteralPath $junctionTarget -Force).Count -ne 0) {
            throw 'Rejected reparse request wrote signing files through a directory link.'
        }
        if ((Get-FileHash -LiteralPath $fakeKeytool -Algorithm SHA256).Hash -cne
            [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([byte[]]@(1, 2, 3))).Replace('-', '')) {
            throw 'Fixture keytool bytes changed unexpectedly.'
        }
    } else {
        Assert-SigningRejected @{ Create = $true; SigningDirectory = (Join-Path $fixtureRoot 'windows-only') } 'Windows ACLs'
    }
    Write-Host "Android upload signing safety passed ($caseCount static/rejection cases; Windows path fixtures: $IsWindows). No signing keys generated."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixtureRoot.StartsWith($temporaryParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^dropo-upload-signing-fixtures-[0-9a-f]{32}$') {
        throw 'Refusing cleanup outside the dedicated upload-signing fixture directory.'
    }
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
        # Remove only the link; do not recursively traverse its target.
        Remove-Item -LiteralPath $junctionPath -Force
    }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
