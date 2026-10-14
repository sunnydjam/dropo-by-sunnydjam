$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'publish-android-release-assets.ps1') -FunctionsOnly
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dropo-android-publish-fixtures-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$cases = 0
function Assert-Rejected([scriptblock]$Operation, [string]$Label) {
    try { & $Operation | Out-Null } catch { $script:cases++; return }
    throw "Android publication fixture was not rejected: $Label"
}
try {
    $artifact = Join-Path $fixtureRoot 'dropo-Android-Play-universal.aab'
    [IO.File]::WriteAllBytes($artifact, [byte[]]@(1, 2, 3, 4))
    $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecar = "$artifact.sha256"
    [IO.File]::WriteAllText($sidecar, "$hash  dropo-Android-Play-universal.aab`n")
    if ((Assert-AndroidReleaseChecksum $artifact $sidecar) -cne $hash) { throw 'Matching sidecar failed.' }
    $cases++
    [IO.File]::WriteAllText($sidecar, "$hash  unrelated.aab`n")
    Assert-Rejected { Assert-AndroidReleaseChecksum $artifact $sidecar } 'wrong sidecar filename'
    [IO.File]::WriteAllText($sidecar, (('0' * 64) + "  dropo-Android-Play-universal.aab`n"))
    Assert-Rejected { Assert-AndroidReleaseChecksum $artifact $sidecar } 'wrong sidecar hash'
    [IO.File]::WriteAllText($sidecar, ((' ' * 1025) + "$hash  dropo-Android-Play-universal.aab"))
    Assert-Rejected { Assert-AndroidReleaseChecksum $artifact $sidecar } 'oversized sidecar'
    [IO.File]::WriteAllText($sidecar, "$hash  dropo-Android-Play-universal.aab`n$hash  second.aab")
    Assert-Rejected { Assert-AndroidReleaseChecksum $artifact $sidecar } 'multiple checksum records'
    Assert-Rejected { Assert-AndroidReleaseChecksum $artifact "$sidecar.missing" } 'missing sidecar'

    $local = [pscustomobject]@{ Name = 'dropo-Android-Play-universal.aab'; Bytes = 4; SHA256 = $hash }
    $plan = @(Get-AndroidAssetPublicationPlan @($local) @())
    if ($plan.Count -ne 1 -or -not $plan[0].Upload) { throw 'New asset upload plan failed.' }
    $cases++
    $existing = [pscustomobject]@{ name = $local.Name; size = 4; digest = "sha256:$hash" }
    $plan = @(Get-AndroidAssetPublicationPlan @($local) @($existing))
    if ($plan.Count -ne 1 -or $plan[0].Upload) { throw 'Idempotent immutable asset plan failed.' }
    $cases++
    Assert-Rejected { Get-AndroidAssetPublicationPlan @($local) @($existing, $existing) } 'ambiguous existing assets'
    $different = [pscustomobject]@{ name = $local.Name; size = 4; digest = 'sha256:' + ('0' * 64) }
    Assert-Rejected { Get-AndroidAssetPublicationPlan @($local) @($different) } 'different existing hash'
    $different = [pscustomobject]@{ name = $local.Name; size = 5; digest = "sha256:$hash" }
    Assert-Rejected { Get-AndroidAssetPublicationPlan @($local) @($different) } 'different existing size'

    $sourceSha = 'a' * 40
    $recordPath = "$artifact.build.json"
    $record = [ordered]@{ sourceRevision = $sourceSha; sourceDirty = $false; channel = 'play';
        packageName = 'in.droponevedimka.dropo'; version = '3.0.47'; versionCode = 30047;
        architecture = 'universal'; artifactName = $local.Name; sha256 = $hash }
    function Assert-Record {
        Assert-AndroidBuildRecord -Path $recordPath -SourceRevision $sourceSha -Version '3.0.47' `
            -VersionCode 30047 -Channel play -ArtifactName $local.Name -SHA256 $hash
    }
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
    Assert-Record
    $cases++
    foreach ($field in @('sourceRevision', 'sourceDirty', 'channel', 'packageName', 'version',
        'versionCode', 'architecture', 'artifactName', 'sha256')) {
        $badRecord = [ordered]@{}
        foreach ($key in $record.Keys) { $badRecord[$key] = $record[$key] }
        $badRecord[$field] = switch ($field) {
            'sourceDirty' { $true }
            'versionCode' { 30046 }
            default { 'wrong' }
        }
        [IO.File]::WriteAllText($recordPath, ($badRecord | ConvertTo-Json))
        Assert-Rejected { Assert-Record } "wrong build record $field"
    }
    $record.sourceDirty = 'false'
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
    Assert-Rejected { Assert-Record } 'string false cannot stand in for source cleanliness'

    # Resolve both lightweight and annotated release tags without any network.
    function Invoke-AndroidReleaseGhJson {
        param([string[]]$Arguments)
        if ($script:tagFixture -eq 'lightweight') {
            return [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $sourceSha } }
        }
        if ($script:tagFixture -eq 'annotated') {
            if ($Arguments[1] -match '/git/ref/tags/') {
                return [pscustomobject]@{ object = [pscustomobject]@{ type = 'tag'; sha = 'b' * 40 } }
            }
            return [pscustomobject]@{ object = [pscustomobject]@{ type = 'commit'; sha = $sourceSha } }
        }
        if ($script:tagFixture -eq 'nested') {
            return [pscustomobject]@{ object = [pscustomobject]@{ type = 'tag'; sha = 'b' * 40 } }
        }
        return [pscustomobject]@{ object = [pscustomobject]@{ type = 'blob'; sha = 'b' * 40 } }
    }
    foreach ($kind in @('lightweight', 'annotated')) {
        $script:tagFixture = $kind
        if ((Get-AndroidReleaseTagRevision -Repository 'owner/project' -Tag 'v3.0.47') -cne $sourceSha) {
            throw "Android release tag resolution failed: $kind"
        }
        $cases++
    }
    foreach ($kind in @('nested', 'blob')) {
        $script:tagFixture = $kind
        Assert-Rejected { Get-AndroidReleaseTagRevision -Repository 'owner/project' -Tag 'v3.0.47' } "invalid release tag $kind"
    }

    $publisher = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'publish-android-release-assets.ps1') -Raw
    foreach ($required in @('Get-ReleaseReadiness', 'Get-AndroidReleaseTagRevision',
        'check-clean-contributors.ps1', 'verify-android-apk.ps1', 'verify-android-aab.ps1',
        'android-upload-cert.sha256', 'sourceDirty', 'PreviewOnly')) {
        if (-not $publisher.Contains($required)) { throw "Android publisher gate missing: $required" }
    }
    if ($publisher -match '(?m)^\s*&\s+gh\s+release\s+(create|delete|edit)\b' -or
        $publisher -match '(?m)^\s*&\s+gh\s+release\s+upload.*--clobber') {
        throw 'Android attachment helper must not create, delete, edit or overwrite releases.'
    }
    $cases++
    Write-Host "Android publication fixtures passed ($cases cases). No GitHub writes performed."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^dropo-android-publish-fixtures-[0-9a-f]{32}$') {
        throw 'Refusing cleanup outside the dedicated publication fixture directory.'
    }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
