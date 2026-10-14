param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'archive-android-aab.ps1') -FunctionsOnly
$script:Passed = 0
function Assert-Fixture {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "Fixture failed: $Name" }
    $script:Passed++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Name)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Fixture -Condition $rejected -Name $Name
}
function Write-ArchiveFixture {
    param([string]$Folder, [string]$Content = 'synthetic bundle bytes', [hashtable]$Overrides = @{})
    [IO.Directory]::CreateDirectory($Folder) | Out-Null
    $aab = Join-Path $Folder 'dropo-Android-Play-universal.aab'
    [IO.File]::WriteAllText($aab, $Content, [Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $aab -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$aab.sha256", "$hash  dropo-Android-Play-universal.aab`n", [Text.UTF8Encoding]::new($false))
    $record = [ordered]@{
        artifactName = 'dropo-Android-Play-universal.aab'; sha256 = $hash
        sourceRevision = ('a' * 40); sourceDirty = $false; channel = 'play'
        packageName = 'com.dropo_dzhamuha.app'; version = '3.0.47'; versionCode = 30047; architecture = 'universal'
    }
    foreach ($key in $Overrides.Keys) { $record[$key] = $Overrides[$key] }
    [IO.File]::WriteAllText("$aab.build.json", ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    return $aab
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dropo-aab-archive-fixture-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$safeFixtureRoot = Assert-DropoAabArchiveNonReparsePath -Path $fixtureRoot
try {
    $releaseFolder = Join-Path $fixtureRoot 'release'
    $aab = Write-ArchiveFixture -Folder $releaseFolder
    $inputData = Get-DropoAabArchiveInput -Folder $releaseFolder
    Assert-Fixture ($inputData.record.sourceRevision -ceq ('a' * 40)) 'accepts historical clean source revision without current HEAD dependency'
    $archiveRoot = Join-Path $fixtureRoot 'archive'
    # This entry represents an immutable archive made before the Play package
    # correction. New archive writes must not migrate its metadata or bytes.
    $historicalFolder = Join-Path (Join-Path $archiveRoot '3.0.47') 'historical-old-package'
    Write-ArchiveFixture -Folder $historicalFolder -Content 'older package bundle bytes' -Overrides @{
        packageName = 'in.droponevedimka.dropo'; sourceRevision = ('b' * 40)
    } | Out-Null
    $historicalHashes = @{}
    foreach ($name in $script:DropoAabArchiveFileNames) {
        $historicalHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $historicalFolder $name) -Algorithm SHA256).Hash
    }
    $first = Copy-DropoVerifiedAabToArchive -InputData $inputData -Root $archiveRoot
    Assert-Fixture (-not $first.alreadyArchived) 'first immutable archive copy'
    Assert-Fixture ($first.archivePath -ceq (Join-Path (Join-Path $archiveRoot '3.0.47') (('a' * 40) + '-' + $inputData.record.sha256.Substring(0, 12)))) 'full commit and digest identity'
    Assert-Fixture (@(Get-ChildItem -LiteralPath $first.archivePath -Force).Count -eq 3) 'archives exactly AAB checksum and public build record'
    $again = Copy-DropoVerifiedAabToArchive -InputData $inputData -Root $archiveRoot
    Assert-Fixture ($again.alreadyArchived -and $again.archivePath -ceq $first.archivePath) 'identical archive is idempotent'
    foreach ($name in $script:DropoAabArchiveFileNames) {
        Assert-Fixture ((Get-FileHash -LiteralPath (Join-Path $historicalFolder $name) -Algorithm SHA256).Hash -ceq $historicalHashes[$name]) "historical old-package archive preserves $name"
    }

    $secondFolder = Join-Path $fixtureRoot 'second'
    Write-ArchiveFixture -Folder $secondFolder -Content 'different synthetic bundle bytes' | Out-Null
    $secondData = Get-DropoAabArchiveInput -Folder $secondFolder
    $second = Copy-DropoVerifiedAabToArchive -InputData $secondData -Root $archiveRoot
    Assert-Fixture ($second.archivePath -cne $first.archivePath -and [IO.File]::Exists($first.artifactPath)) 'different bytes preserve the older artifact'
    $recordCollisionFolder = Join-Path $fixtureRoot 'record-collision'
    Write-ArchiveFixture -Folder $recordCollisionFolder | Out-Null
    [IO.File]::AppendAllText((Join-Path $recordCollisionFolder 'dropo-Android-Play-universal.aab.build.json'), "`n")
    $recordCollision = Get-DropoAabArchiveInput -Folder $recordCollisionFolder
    Assert-Rejected { Copy-DropoVerifiedAabToArchive -InputData $recordCollision -Root $archiveRoot } 'same identity with changed record rejected'
    [IO.File]::WriteAllText($first.artifactPath, 'corrupted archived fixture')
    Assert-Rejected { Copy-DropoVerifiedAabToArchive -InputData $inputData -Root $archiveRoot } 'corrupt archive collision rejected without overwrite'
    Assert-Fixture ([IO.File]::ReadAllText($first.artifactPath) -ceq 'corrupted archived fixture') 'rejected collision does not replace bytes'

    $invalidFolder = Join-Path $fixtureRoot 'invalid'
    foreach ($case in @(
        @{ label = 'dirty builds'; data = @{ sourceDirty = $true } },
        @{ label = 'false string is not clean boolean'; data = @{ sourceDirty = 'false' } },
        @{ label = 'short source revisions'; data = @{ sourceRevision = 'abcdef0' } },
        @{ label = 'unsafe source revisions'; data = @{ sourceRevision = '../unsafe' } },
        @{ label = 'preview channel'; data = @{ channel = 'preview' } },
        @{ label = 'old Play package'; data = @{ packageName = 'in.droponevedimka.dropo' } },
        @{ label = 'preview package'; data = @{ packageName = 'in.droponevedimka.dropo.preview' } },
        @{ label = 'new package preview suffix'; data = @{ packageName = 'com.dropo_dzhamuha.app.preview' } },
        @{ label = 'arm64-only architecture'; data = @{ architecture = 'arm64' } },
        @{ label = 'wrong record filename'; data = @{ artifactName = 'other.aab' } },
        @{ label = 'wrong record hash'; data = @{ sha256 = ('0' * 64) } },
        @{ label = 'wrong versionCode'; data = @{ versionCode = 30048 } },
        @{ label = 'string versionCode'; data = @{ versionCode = '30047' } },
        @{ label = 'unsafe version'; data = @{ version = '../3.0.47' } },
        @{ label = 'overflow version'; data = @{ version = '999999999999999999999.0.47' } },
        @{ label = 'versionCode collision scheme'; data = @{ version = '3.0.100'; versionCode = 30100 } },
        @{ label = 'private properties not archived'; data = @{ storePassword = 'synthetic-not-a-real-password' } }
    )) {
        Write-ArchiveFixture -Folder $invalidFolder -Overrides $case.data | Out-Null
        Assert-Rejected { Get-DropoAabArchiveInput -Folder $invalidFolder } $case.label
    }
    $invalidAab = Write-ArchiveFixture -Folder $invalidFolder
    $correctChecksum = [IO.File]::ReadAllText("$invalidAab.sha256")
    [IO.File]::WriteAllText("$invalidAab.sha256", $correctChecksum.Replace('dropo-Android-Play-universal.aab', '../other.aab'))
    Assert-Rejected { Get-DropoAabArchiveInput -Folder $invalidFolder } 'unsafe checksum filename rejected'
    [IO.File]::WriteAllText("$invalidAab.sha256", ('0' * 64) + '  dropo-Android-Play-universal.aab')
    Assert-Rejected { Get-DropoAabArchiveInput -Folder $invalidFolder } 'incorrect artifact checksum rejected'
    Write-ArchiveFixture -Folder $invalidFolder | Out-Null
    [IO.File]::Delete("$invalidAab.build.json")
    Assert-Rejected { Get-DropoAabArchiveInput -Folder $invalidFolder } 'missing provenance rejected'
    Assert-Rejected { Assert-DropoAabArchiveContainedPath -Root $archiveRoot -Path $fixtureRoot } 'parent escape rejected'
    Assert-Rejected { Assert-DropoAabArchiveContainedPath -Root $archiveRoot -Path ($archiveRoot + '-other/file') } 'prefix sibling escape rejected'
    $junction = Join-Path $fixtureRoot 'archive-link'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        New-Item -ItemType Junction -Path $junction -Target $archiveRoot | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $junction -Target $archiveRoot | Out-Null
    }
    try {
        Assert-Rejected { Copy-DropoVerifiedAabToArchive -InputData $inputData -Root $junction } 'reparse archive root rejected'
        Assert-Rejected { Assert-DropoAabArchiveNonReparsePath -Path (Join-Path $junction 'nonexistent/child') } 'reparse ancestor of future path rejected'
    } finally { [IO.Directory]::Delete($junction, $false) }
    $helperText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'archive-android-aab.ps1'))
    Assert-Fixture ($helperText -match 'verify-android-aab\.ps1' -and $helperText -notmatch '(?im)^\s*.*(?:-Download|keytool|signing\.properties|--clobber)') 'entry verifies signed AAB without network or private key access'
    Write-Host "[OK] Android AAB archive: $script:Passed fixture checks passed."
} finally {
    # A freshly generated fixture directory is the only recursive cleanup target.
    $resolvedFixtureRoot = Assert-DropoAabArchiveNonReparsePath -Path $fixtureRoot
    if ($resolvedFixtureRoot -cne $safeFixtureRoot -or
        -not (Split-Path -Leaf $resolvedFixtureRoot).StartsWith('dropo-aab-archive-fixture-', [StringComparison]::Ordinal)) {
        throw 'Refusing to remove an unexpected archive fixture path.'
    }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
