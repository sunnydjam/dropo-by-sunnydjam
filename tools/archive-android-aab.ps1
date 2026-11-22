[CmdletBinding(DefaultParameterSetName = 'Archive')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Archive')][string]$ReleaseFolder,
    [Parameter(ParameterSetName = 'Archive')][string]$ArchiveRoot,
    [Parameter(ParameterSetName = 'Functions')][switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'
$script:DropoAabArchiveArtifactName = 'dropo-Android-Play-universal.aab'
$script:DropoAabArchiveFileNames = @(
    $script:DropoAabArchiveArtifactName,
    "$($script:DropoAabArchiveArtifactName).sha256",
    "$($script:DropoAabArchiveArtifactName).build.json"
)

function Assert-DropoAabArchiveNonReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $cursor = $fullPath
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'AAB archive paths must not contain symbolic links or directory junctions.'
            }
        } elseif (Test-Path -LiteralPath $cursor) {
            throw 'AAB archive path has an unsupported filesystem entry.'
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if (-not $parent -or $parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $fullPath
}

function Assert-DropoAabArchiveContainedPath {
    param([string]$Root, [string]$Path)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'AAB archive destination escaped the configured archive root.'
    }
    Assert-DropoAabArchiveNonReparsePath -Path $fullPath | Out-Null
    return $fullPath
}

function Get-DropoAabArchiveInput {
    param([Parameter(Mandatory = $true)][string]$Folder)
    $sourceFolder = Assert-DropoAabArchiveNonReparsePath -Path $Folder
    if (-not [IO.Directory]::Exists($sourceFolder)) { throw 'AAB release folder does not exist.' }
    foreach ($name in $script:DropoAabArchiveFileNames) {
        $filePath = Join-Path $sourceFolder $name
        Assert-DropoAabArchiveNonReparsePath -Path $filePath | Out-Null
        if (-not [IO.File]::Exists($filePath) -or (Get-Item -LiteralPath $filePath).Length -lt 1) {
            throw "AAB archive requires a nonempty $name."
        }
    }
    $artifactPath = Join-Path $sourceFolder $script:DropoAabArchiveArtifactName
    $checksumPath = "$artifactPath.sha256"
    $recordPath = "$artifactPath.build.json"
    if ((Get-Item -LiteralPath $checksumPath).Length -gt 1024 -or (Get-Item -LiteralPath $recordPath).Length -gt 16384) {
        throw 'AAB checksum or build record exceeds its permitted size.'
    }
    $checksum = [IO.File]::ReadAllText($checksumPath)
    if ($checksum -cnotmatch '^([0-9a-f]{64})  dropo-Android-Play-universal\.aab\r?\n?$') {
        throw 'AAB checksum must bind the exact Play artifact filename and SHA-256.'
    }
    $boundHash = $Matches[1]
    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($boundHash -cne $actualHash) { throw 'AAB checksum does not match the artifact bytes.' }
    $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    $allowedProperties = @('artifactName', 'sha256', 'sourceRevision', 'sourceDirty', 'channel',
        'packageName', 'version', 'versionCode', 'architecture')
    $properties = @($record.PSObject.Properties | ForEach-Object { $_.Name })
    if ($properties.Count -ne $allowedProperties.Count -or
        @($properties | Where-Object { $_ -cnotin $allowedProperties }).Count -ne 0) {
        throw 'AAB build record must contain only the expected public provenance fields.'
    }
    if ($record.artifactName -cne $script:DropoAabArchiveArtifactName -or $record.sha256 -cne $actualHash) {
        throw 'AAB build record is not bound to the exact artifact name and bytes.'
    }
    if ($record.sourceRevision -isnot [string] -or $record.sourceRevision -cnotmatch '^[0-9a-f]{40}$' -or
        $record.sourceDirty -isnot [bool] -or $record.sourceDirty) {
        throw 'Only clean builds with a complete source commit revision may enter the AAB archive.'
    }
    if ($record.channel -cne 'play' -or $record.packageName -cne 'com.dropo.myapp' -or
        $record.architecture -cne 'universal') {
        throw 'AAB archive accepts only the stable Google Play universal Android channel.'
    }
    if ($record.version -isnot [string] -or $record.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'Invalid synchronized AAB release version.'
    }
    $parts = $record.version.Split('.')
    $major = 0L; $minor = 0L; $patch = 0L
    if (-not [long]::TryParse($parts[0], [ref]$major) -or -not [long]::TryParse($parts[1], [ref]$minor) -or
        -not [long]::TryParse($parts[2], [ref]$patch) -or $major -gt 210000 -or $minor -gt 99 -or $patch -gt 99) {
        throw 'AAB version is outside the supported Android versionCode scheme.'
    }
    $expectedVersionCode = $major * 10000 + $minor * 100 + $patch
    if ($expectedVersionCode -lt 1 -or $expectedVersionCode -gt 2100000000 -or
        ($record.versionCode -isnot [int] -and $record.versionCode -isnot [long]) -or
        $record.versionCode -ne $expectedVersionCode) {
        throw 'AAB build record versionCode does not match its release version.'
    }
    $fileHashes = @{}
    foreach ($name in $script:DropoAabArchiveFileNames) {
        $fileHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $sourceFolder $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [pscustomobject]@{ folder = $sourceFolder; artifactPath = $artifactPath; record = $record; fileHashes = $fileHashes }
}

function Get-DropoAabArchiveDestination {
    param([Parameter(Mandatory = $true)][object]$InputData, [Parameter(Mandatory = $true)][string]$Root)
    $safeRoot = Assert-DropoAabArchiveNonReparsePath -Path $Root
    $versionDirectory = Assert-DropoAabArchiveContainedPath -Root $safeRoot -Path (Join-Path $safeRoot $InputData.record.version)
    $identity = $InputData.record.sourceRevision + '-' + $InputData.record.sha256.Substring(0, 12)
    $destination = Assert-DropoAabArchiveContainedPath -Root $safeRoot -Path (Join-Path $versionDirectory $identity)
    [pscustomobject]@{ root = $safeRoot; versionDirectory = $versionDirectory; destination = $destination }
}

function Assert-DropoAabArchivedFiles {
    param([object]$InputData, [string]$ArchiveDirectory, [string]$Root)
    Assert-DropoAabArchiveContainedPath -Root $Root -Path $ArchiveDirectory | Out-Null
    if (-not [IO.Directory]::Exists($ArchiveDirectory)) { throw 'AAB archive identity is not a directory.' }
    $entries = @(Get-ChildItem -LiteralPath $ArchiveDirectory -Force)
    if ($entries.Count -ne $script:DropoAabArchiveFileNames.Count -or
        @($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $script:DropoAabArchiveFileNames }).Count -ne 0) {
        throw 'Existing AAB archive identity contains unexpected or missing entries; it was not replaced.'
    }
    foreach ($name in $script:DropoAabArchiveFileNames) {
        $path = Assert-DropoAabArchiveContainedPath -Root $Root -Path (Join-Path $ArchiveDirectory $name)
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $InputData.fileHashes[$name]) {
            throw 'Existing AAB archive bytes differ from this build; nothing was replaced.'
        }
    }
}

function Copy-DropoVerifiedAabToArchive {
    # The public script verifies the real signed AAB first. This filesystem-only
    # function is separate so fixture tests never need an upload key or network.
    param([Parameter(Mandatory = $true)][object]$InputData, [Parameter(Mandatory = $true)][string]$Root)
    $paths = Get-DropoAabArchiveDestination -InputData $InputData -Root $Root
    $alreadyArchived = [IO.Directory]::Exists($paths.destination)
    if ($alreadyArchived) {
        Assert-DropoAabArchivedFiles -InputData $InputData -ArchiveDirectory $paths.destination -Root $paths.root
    } else {
        [IO.Directory]::CreateDirectory($paths.versionDirectory) | Out-Null
        Assert-DropoAabArchiveContainedPath -Root $paths.root -Path $paths.versionDirectory | Out-Null
        $staging = Assert-DropoAabArchiveContainedPath -Root $paths.root -Path (
            Join-Path $paths.versionDirectory ('.staging-' + [Guid]::NewGuid().ToString('N')))
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        try {
            foreach ($name in $script:DropoAabArchiveFileNames) {
                $source = Assert-DropoAabArchiveNonReparsePath -Path (Join-Path $InputData.folder $name)
                $target = Assert-DropoAabArchiveContainedPath -Root $paths.root -Path (Join-Path $staging $name)
                $inputStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
            }
            Assert-DropoAabArchivedFiles -InputData $InputData -ArchiveDirectory $staging -Root $paths.root
            Assert-DropoAabArchiveContainedPath -Root $paths.root -Path $paths.destination | Out-Null
            try { [IO.Directory]::Move($staging, $paths.destination) } catch {
                # An identical concurrent invocation may have won the atomic move.
                if (-not [IO.Directory]::Exists($paths.destination)) { throw }
                Assert-DropoAabArchivedFiles -InputData $InputData -ArchiveDirectory $paths.destination -Root $paths.root
                $alreadyArchived = $true
            }
        } finally {
            if ([IO.Directory]::Exists($staging)) {
                # Remove only this invocation's exact staging files, never a
                # release folder, archive identity, or recursively selected root.
                Assert-DropoAabArchiveContainedPath -Root $paths.root -Path $staging | Out-Null
                foreach ($name in $script:DropoAabArchiveFileNames) {
                    $temporaryFile = Assert-DropoAabArchiveContainedPath -Root $paths.root -Path (Join-Path $staging $name)
                    if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
                }
                [IO.Directory]::Delete($staging, $false)
            }
        }
        Assert-DropoAabArchivedFiles -InputData $InputData -ArchiveDirectory $paths.destination -Root $paths.root
    }
    [pscustomobject]@{
        archivePath = $paths.destination
        artifactPath = Join-Path $paths.destination $script:DropoAabArchiveArtifactName
        version = $InputData.record.version
        sourceRevision = $InputData.record.sourceRevision
        sha256 = $InputData.record.sha256
        alreadyArchived = $alreadyArchived
    }
}

if ($FunctionsOnly) { return }
$repositoryRoot = Split-Path $PSScriptRoot
if (-not $ArchiveRoot) { $ArchiveRoot = Join-Path $repositoryRoot 'build-archive/android-play' }
$inputData = Get-DropoAabArchiveInput -Folder $ReleaseFolder
# Verification uses the already prepared, checksum-pinned bundletool. It does
# not download anything or access signing properties/private signing keys.
$verified = & (Join-Path $PSScriptRoot 'verify-android-aab.ps1') -Path $inputData.artifactPath -ExpectedVersion $inputData.record.version
if ($verified.Package -cne $inputData.record.packageName -or $verified.VersionCode -ne $inputData.record.versionCode -or
    $verified.SHA256 -cne $inputData.record.sha256) {
    throw 'Verified AAB metadata does not match the clean build record.'
}
Copy-DropoVerifiedAabToArchive -InputData $inputData -Root $ArchiveRoot
