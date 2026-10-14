param(
    [string]$ReleaseFolder,
    [ValidatePattern('^[0-9a-f]{40}$')][string]$SourceRevision,
    [string]$Tag,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'sunnydjam/dropo-by-sunnydjam',
    [string]$SdkRoot,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedUploadCertificateSHA256,
    [switch]$PreviewOnly,
    [switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot

# These pure checks are exercised without GitHub access or release mutations.
function Assert-AndroidReleaseChecksum {
    param([string]$ArtifactPath, [string]$SidecarPath)
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
        throw 'Android artifact and SHA-256 sidecar must both exist.'
    }
    if ((Get-Item -LiteralPath $SidecarPath).Length -gt 1024) {
        throw 'Android checksum sidecar exceeds the updater limit.'
    }
    $name = [IO.Path]::GetFileName($ArtifactPath)
    $declared = (Get-Content -LiteralPath $SidecarPath -Raw).Trim()
    if ($declared -notmatch '^([0-9a-fA-F]{64})\s+\*?([^\r\n]+)$' -or
        $Matches[2] -cne $name) {
        throw 'Android checksum sidecar must identify the exact artifact filename.'
    }
    $hash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Matches[1].ToLowerInvariant() -cne $hash) {
        throw "Android SHA-256 sidecar mismatch: $name"
    }
    return $hash
}

function Get-AndroidAssetPublicationPlan {
    param([object[]]$LocalAssets, [object[]]$ExistingAssets)
    $plan = @()
    foreach ($local in $LocalAssets) {
        $matching = @($ExistingAssets | Where-Object { $_.name -ceq $local.Name })
        if ($matching.Count -gt 1) { throw 'Ambiguous existing Android release asset.' }
        if ($matching.Count -eq 1) {
            if ([string]$matching[0].digest -cne "sha256:$($local.SHA256)" -or
                [long]$matching[0].size -ne [long]$local.Bytes) {
                throw "Existing asset differs; immutable releases cannot be overwritten: $($local.Name)"
            }
            $plan += [pscustomobject]@{ Asset = $local; Upload = $false }
        } else {
            $plan += [pscustomobject]@{ Asset = $local; Upload = $true }
        }
    }
    return $plan
}

function Assert-AndroidBuildRecord {
    param([string]$Path, [string]$SourceRevision, [string]$Version, [long]$VersionCode,
        [string]$Channel, [string]$ArtifactName, [string]$SHA256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -gt 65536) {
        throw 'Android artifact requires a bounded source build record.'
    }
    $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $packageName = 'in.droponevedimka.dropo' + $(if ($Channel -ceq 'preview') { '.preview' } else { '' })
    if ($record.sourceRevision -cne $SourceRevision -or
        $record.sourceDirty -isnot [bool] -or $record.sourceDirty -ne $false -or
        $record.channel -cne $Channel -or $record.packageName -cne $packageName -or
        $record.version -cne $Version -or [long]$record.versionCode -ne $VersionCode -or
        $record.architecture -cne 'universal' -or $record.artifactName -cne $ArtifactName -or
        $record.sha256 -cne $SHA256) {
        throw 'Android artifact build record does not match the clean release source, channel or bytes.'
    }
}

function Invoke-AndroidReleaseGhJson {
    param([string[]]$Arguments)
    $raw = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'GitHub release verification failed.' }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Get-AndroidReleaseTagRevision {
    param([string]$Repository, [string]$Tag)
    $reference = Invoke-AndroidReleaseGhJson -Arguments @('api', "repos/$Repository/git/ref/tags/$Tag")
    $object = $reference.object
    for ($depth = 0; $depth -lt 5; $depth++) {
        if ($object.type -ceq 'commit' -and $object.sha -cmatch '^[0-9a-f]{40}$') {
            return [string]$object.sha
        }
        if ($object.type -cne 'tag' -or $object.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Release tag does not resolve to a commit.'
        }
        $annotation = Invoke-AndroidReleaseGhJson -Arguments @('api', "repos/$Repository/git/tags/$($object.sha)")
        $object = $annotation.object
    }
    throw 'Release tag nesting exceeded the verification limit.'
}

if ($FunctionsOnly) { return }
if (-not $SourceRevision) { throw 'Pass the exact full source commit SHA in -SourceRevision.' }
$currentRevision = ([string](& git -C $repositoryRoot rev-parse HEAD)).Trim()
if ($LASTEXITCODE -ne 0 -or $currentRevision -cne $SourceRevision) {
    throw 'Publication source revision must equal the clean current checkout.'
}
$dirty = @(& git -C $repositoryRoot status --porcelain=v1 --untracked-files=normal)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Development or dirty-source Android artifacts cannot be published.'
}
& (Join-Path $PSScriptRoot 'check-clean-contributors.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Contributor metadata check failed.' }
$version = [string](Get-Content -LiteralPath (Join-Path $repositoryRoot 'version.json') -Raw | ConvertFrom-Json).version
$pubspec = Get-Content -LiteralPath (Join-Path $repositoryRoot 'flutter_app/pubspec.yaml') -Raw
$pubspecVersion = [regex]::Match($pubspec, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$')
if (-not $pubspecVersion.Success -or $pubspecVersion.Groups[1].Value -cne $version) {
    throw 'Android publication metadata version is not synchronized.'
}
$versionCode = [long]$pubspecVersion.Groups[2].Value
$releaseTag = if ($Tag) { $Tag.Trim() } else { "v$version" }
if ($releaseTag -cne "v$version") { throw 'Android assets must attach to the current stable version tag.' }
if (-not $ReleaseFolder) {
    $ReleaseFolder = Join-Path $repositoryRoot "release/dropo-$version-$($SourceRevision.Substring(0, 7))"
}
$ReleaseFolder = (Resolve-Path -LiteralPath $ReleaseFolder).Path
if ([IO.Path]::GetFileName($ReleaseFolder) -cne "dropo-$version-$($SourceRevision.Substring(0, 7))") {
    throw 'Android publication requires the clean source build folder, not a development folder.'
}

$apkPath = Join-Path $ReleaseFolder 'dropo-Android-Preview-universal.apk'
$artifactPaths = @($apkPath)
if (-not $PreviewOnly) {
    $artifactPaths += Join-Path $ReleaseFolder 'dropo-Android-Play-universal.aab'
    if (-not $ExpectedUploadCertificateSHA256) {
        $pinPath = Join-Path $repositoryRoot 'signing/android-upload-cert.sha256'
        if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) {
            throw 'Configure the owner upload certificate pin or pass -ExpectedUploadCertificateSHA256.'
        }
        $ExpectedUploadCertificateSHA256 = (Get-Content -LiteralPath $pinPath -Raw).Trim()
    }
    if ($ExpectedUploadCertificateSHA256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'The upload certificate pin must be a SHA-256 public certificate fingerprint.'
    }
}
$localAssets = @()
foreach ($artifact in $artifactPaths) {
    $hash = Assert-AndroidReleaseChecksum -ArtifactPath $artifact -SidecarPath "$artifact.sha256"
    $channel = if ($artifact -ceq $apkPath) { 'preview' } else { 'play' }
    Assert-AndroidBuildRecord -Path "$artifact.build.json" -SourceRevision $SourceRevision `
        -Version $version -VersionCode $versionCode -Channel $channel `
        -ArtifactName ([IO.Path]::GetFileName($artifact)) -SHA256 $hash
    foreach ($path in @($artifact, "$artifact.sha256")) {
        $file = Get-Item -LiteralPath $path
        $localAssets += [pscustomobject]@{ Path = $file.FullName; Name = $file.Name; Bytes = $file.Length;
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

& (Join-Path $PSScriptRoot 'verify-android-apk.ps1') -Path $apkPath -SdkRoot $SdkRoot `
    -Architecture universal -ExpectedVersion $version -Preview | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Android Preview verification failed.' }
# Preview remains a separate package and preserves its existing installation key.
$androidRoot = if ($SdkRoot) { $SdkRoot } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else {
    $toolchainRoot = $env:DROPO_ANDROID_TOOLCHAIN_ROOT
    if (-not $toolchainRoot) { $toolchainRoot = [Environment]::GetEnvironmentVariable('DROPO_ANDROID_TOOLCHAIN_ROOT', 'User') }
    if (-not $toolchainRoot) { throw 'Configure the Android SDK before publishing.' }
    Join-Path $toolchainRoot 'sdk'
}
$signerOutput = (& (Join-Path $androidRoot 'build-tools/36.0.0/apksigner.bat') verify --print-certs $apkPath) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Android Preview signature check failed.' }
$previewSigners = [regex]::Matches($signerOutput, 'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})')
if ($previewSigners.Count -ne 1 -or $previewSigners[0].Groups[1].Value.ToLowerInvariant() -cne
    '8f2c5d427fd51f1f7afd36434b908fc074342d63b88a718ac8f2cab53e533e3c') {
    throw 'Android Preview update certificate continuity failed.'
}
if (-not $PreviewOnly) {
    & (Join-Path $PSScriptRoot 'verify-android-aab.ps1') -Path $artifactPaths[1] `
        -ExpectedVersion $version -SdkRoot $SdkRoot `
        -ExpectedCertificateSHA256 $ExpectedUploadCertificateSHA256 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Android Play bundle verification failed.' }
}

# Only completed latest CI and Windows package gates for this exact commit count.
. (Join-Path $PSScriptRoot 'check-release-readiness.ps1') -FunctionsOnly `
    -Repository $Repository -Sha $SourceRevision
$runs = @()
foreach ($workflow in @('ci.yml', 'windows-release-gate.yml')) {
    $pages = @(Invoke-AndroidReleaseGhJson -Arguments @('api',
        "repos/$Repository/actions/workflows/$workflow/runs?head_sha=$SourceRevision&per_page=100",
        '--paginate', '--slurp'))
    foreach ($page in $pages) { $runs += @($page.workflow_runs) }
}
$readiness = Get-ReleaseReadiness -Runs $runs -Repository $Repository -Sha $SourceRevision -Branch 'Dzhamuha-develop'
if (-not $readiness.Ready) { throw $readiness.Reason }
$release = Invoke-AndroidReleaseGhJson -Arguments @('api', "repos/$Repository/releases/tags/$releaseTag")
if ($release.draft -or $release.prerelease -or $release.tag_name -cne $releaseTag) {
    throw 'Android assets require an existing stable published release.'
}
if ((Get-AndroidReleaseTagRevision -Repository $Repository -Tag $releaseTag) -cne $SourceRevision) {
    throw 'Release tag and Android source commit differ.'
}
foreach ($name in @('dropo-Windows-Setup-x64.exe', 'dropo-Windows-Setup-x64.exe.sha256',
    'dropo-Windows-Portable-x64.zip', 'dropo-Windows-Portable-x64.zip.sha256')) {
    $found = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($found.Count -ne 1 -or $found[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The CI-created Windows release assets must already be complete.'
    }
}
$plan = @(Get-AndroidAssetPublicationPlan -LocalAssets $localAssets -ExistingAssets $release.assets)
foreach ($step in $plan) {
    if (-not $step.Upload) { Write-Host "[OK] Already published unchanged: $($step.Asset.Name)"; continue }
    # No --clobber, delete, replacement, tag creation or Play Console publication.
    & gh release upload $releaseTag $step.Asset.Path --repo $Repository
    if ($LASTEXITCODE -ne 0) { throw 'Android asset upload failed; retry only with identical files.' }
    $updated = Invoke-AndroidReleaseGhJson -Arguments @('api', "repos/$Repository/releases/tags/$releaseTag")
    $uploaded = @($updated.assets | Where-Object { $_.name -ceq $step.Asset.Name })
    if ($uploaded.Count -ne 1 -or $uploaded[0].digest -cne "sha256:$($step.Asset.SHA256)" -or
        [long]$uploaded[0].size -ne [long]$step.Asset.Bytes) {
        throw 'GitHub Android asset digest or size does not match the verified local file.'
    }
    Write-Host "[OK] Published $($step.Asset.Name)"
}
Write-Host "[SUCCESS] Android assets attached to $releaseTag; Windows assets unchanged."
