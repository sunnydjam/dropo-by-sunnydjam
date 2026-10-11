param(
    [string]$ManifestPath,
    [string]$ModuleDirectory,
    [string]$OutputDirectory,
    [string]$GoCommand = 'go'
)

$ErrorActionPreference = 'Stop'
if ($env:GOFLAGS -match '(?:^|\s|\")-(?:overlay|modfile)(?:=|\s)') {
    throw 'Android XHTTP preparation cannot combine an existing Go overlay or modfile.'
}
$repositoryRoot = Split-Path $PSScriptRoot
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repositoryRoot 'app/mobile/dropoandroid/xray_overlay/manifest.json'
}
$resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
$overlayRoot = Split-Path $resolvedManifest
$manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or
    $manifest.module -cne 'github.com/xtls/xray-core' -or
    $manifest.moduleVersion -cne 'v1.260327.0' -or
    $manifest.sourceRevision -cne 'd2758a023cd7f4174a5a5fa4ff66e487d4342ba0' -or
    $manifest.license -cne 'MPL-2.0') {
    throw 'Android XHTTP overlay manifest does not identify the approved pinned source.'
}

function Resolve-ContainedOverlayPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains('\') -or
        @($RelativePath.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -gt 0) {
        throw 'Android XHTTP overlay path must be a safe relative path.'
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
    $prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Android XHTTP overlay path escaped its expected directory.'
    }
    return $path
}

function Assert-OverlaySHA256 {
    param([string]$Path, [string]$Expected, [string]$Label)
    if ($Expected -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Expected) {
        throw "Android XHTTP $Label did not match its pinned SHA-256."
    }
}

if (-not $ModuleDirectory) {
    Push-Location (Join-Path $repositoryRoot 'app/mobile/dropoandroid')
    try {
        $moduleOutput = & $GoCommand mod download -json 'github.com/xtls/xray-core@v1.260327.0' 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the pinned Android XHTTP Go module.' }
        $moduleInfo = ($moduleOutput -join "`n") | ConvertFrom-Json
        if ($moduleInfo.Path -cne $manifest.module -or $moduleInfo.Version -cne $manifest.moduleVersion -or
            [string]::IsNullOrWhiteSpace([string]$moduleInfo.Dir)) {
            throw 'Android XHTTP Go module resolution returned an unexpected version.'
        }
        $ModuleDirectory = [string]$moduleInfo.Dir
    } finally {
        Pop-Location
    }
}
$moduleRoot = (Resolve-Path -LiteralPath $ModuleDirectory).Path
if (-not (Test-Path -LiteralPath (Join-Path $moduleRoot 'go.mod') -PathType Leaf) -or
    (Get-Content -LiteralPath (Join-Path $moduleRoot 'go.mod') -Raw) -notmatch '(?m)^module github\.com/xtls/xray-core\s*$') {
    throw 'Android XHTTP overlay target is not the expected module directory.'
}

$expectedPaths = @(
    'transport/internet/splithttp/client.go',
    'transport/internet/splithttp/dialer.go',
    'transport/internet/splithttp/dropo_managed_session.go',
    'transport/internet/splithttp/dropo_managed_session_test.go'
)
$files = @($manifest.files)
if ($files.Count -lt 3 -or $files.Count -gt $expectedPaths.Count) { throw 'Android XHTTP overlay file set is incomplete.' }
foreach ($required in $expectedPaths[0..2]) {
    if (@($files | Where-Object { $_.upstreamPath -ceq $required }).Count -ne 1) {
        throw 'Android XHTTP overlay is missing a required lifecycle source.'
    }
}
$replace = [ordered]@{}
foreach ($file in $files) {
    if ($file.upstreamPath -cnotin $expectedPaths -or $replace.Contains((Join-Path $moduleRoot $file.upstreamPath))) {
        throw 'Android XHTTP overlay file set is unexpected or duplicated.'
    }
    $target = Resolve-ContainedOverlayPath -Root $moduleRoot -RelativePath $file.upstreamPath
    $replacement = Resolve-ContainedOverlayPath -Root $overlayRoot -RelativePath $file.replacementPath
    $bundledAsset = Resolve-ContainedOverlayPath -Root $repositoryRoot -RelativePath $file.bundledAssetPath
    Assert-OverlaySHA256 -Path $replacement -Expected $file.replacementSha256 -Label 'replacement source'
    Assert-OverlaySHA256 -Path $bundledAsset -Expected $file.replacementSha256 -Label 'bundled corresponding source'
    if ($file.operation -ceq 'replace') {
        Assert-OverlaySHA256 -Path $target -Expected $file.upstreamSha256 -Label 'upstream source'
    } elseif ($file.operation -ceq 'add') {
        if (-not [string]::IsNullOrEmpty([string]$file.upstreamSha256) -or (Test-Path -LiteralPath $target)) {
            throw 'Android XHTTP added source already exists in the pinned module.'
        }
    } else {
        throw 'Android XHTTP overlay operation is invalid.'
    }
    $replace[$target] = $replacement
}

if (-not $OutputDirectory) {
    $androidToolsRoot = [string]$env:DROPO_ANDROID_TOOLCHAIN_ROOT
    if (-not $androidToolsRoot) { $androidToolsRoot = [Environment]::GetEnvironmentVariable('DROPO_ANDROID_TOOLCHAIN_ROOT', 'User') }
    $OutputDirectory = if ($androidToolsRoot -and (Test-Path -LiteralPath $androidToolsRoot -PathType Container)) {
        Join-Path $androidToolsRoot 'xhttp-overlay-build'
    } else { Join-Path ([IO.Path]::GetTempPath()) 'dropo-android-xhttp-overlay' }
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$moduleCacheOutput = & $GoCommand env GOMODCACHE 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the Go module cache for safe XHTTP staging.' }
$moduleCacheRoot = [IO.Path]::GetFullPath(([string]($moduleCacheOutput | Select-Object -First 1)).Trim())
foreach ($protectedRoot in @($moduleRoot, $moduleCacheRoot)) {
    $protectedPrefix = $protectedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedOutput -ceq $protectedRoot -or $resolvedOutput.StartsWith($protectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Android XHTTP staging must remain outside the original module and Go module cache.'
    }
}
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

# Go 1.26 forbids replacing module-cache files with an overlay. Create an
# immutable copy of the pinned source outside GOMODCACHE, verify every copied
# byte, and use a temporary modfile to point only this build at that copy.
$sourceFiles = @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse -Force | Sort-Object FullName)
$sourceRecords = @($sourceFiles | ForEach-Object {
    [pscustomobject]@{
        Path = [IO.Path]::GetRelativePath($moduleRoot, $_.FullName).Replace([char]92, [char]47)
        SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$sourceDescription = $sourceRecords | ConvertTo-Json -Compress
$sourceHashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceDescription))
$sourceHash = [Convert]::ToHexString($sourceHashBytes).ToLowerInvariant()
$stagedModule = Join-Path $resolvedOutput ("source-xray-v1.260327.0-$sourceHash")
if (-not (Test-Path -LiteralPath $stagedModule -PathType Container)) {
    $pendingSource = Join-Path $resolvedOutput ('pending-xray-source-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $pendingSource | Out-Null
    try {
        foreach ($item in Get-ChildItem -LiteralPath $moduleRoot -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $pendingSource -Recurse -Force
        }
        try { [IO.Directory]::Move($pendingSource, $stagedModule) } catch {
            if (-not (Test-Path -LiteralPath $stagedModule -PathType Container)) { throw }
        }
    } finally {
        if (Test-Path -LiteralPath $pendingSource) {
            $pendingFullPath = [IO.Path]::GetFullPath($pendingSource)
            if (-not $pendingFullPath.StartsWith($resolvedOutput.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                (Split-Path $pendingFullPath -Leaf) -notmatch '^pending-xray-source-[a-f0-9]{32}$') {
                throw 'Refusing to clean an unexpected XHTTP source-staging directory.'
            }
            Remove-Item -LiteralPath $pendingFullPath -Recurse -Force
        }
    }
}
$stagedFiles = @(Get-ChildItem -LiteralPath $stagedModule -File -Recurse -Force)
if ($stagedFiles.Count -ne $sourceRecords.Count) { throw 'Pinned XHTTP staged source contains unexpected files.' }
foreach ($record in $sourceRecords) {
    Assert-OverlaySHA256 -Path (Join-Path $stagedModule $record.Path) -Expected $record.SHA256 -Label 'staged module source'
}
$stagedReplace = [ordered]@{}
foreach ($file in $files) {
    $stagedReplace[(Resolve-ContainedOverlayPath -Root $stagedModule -RelativePath $file.upstreamPath)] =
        Resolve-ContainedOverlayPath -Root $overlayRoot -RelativePath $file.replacementPath
}

$manifestHash = (Get-FileHash -LiteralPath $resolvedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
$overlayPath = Join-Path $resolvedOutput ("xray-stage-v1.260327.0-$manifestHash-$($sourceHash.Substring(0, 16)).json")
$overlayJSON = ([ordered]@{ Replace = $stagedReplace } | ConvertTo-Json -Depth 4) + "`n"
if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
    if ([IO.File]::ReadAllText($overlayPath) -cne $overlayJSON) { throw 'Existing Android XHTTP overlay mapping is not the expected deterministic mapping.' }
} else { [IO.File]::WriteAllText($overlayPath, $overlayJSON, [Text.UTF8Encoding]::new($false)) }

$modfileDirectory = Join-Path $resolvedOutput ('build-modfile-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $modfileDirectory | Out-Null
$modfilePath = Join-Path $modfileDirectory 'dropoandroid.mod'
$bridgeDirectory = Join-Path $repositoryRoot 'app/mobile/dropoandroid'
Copy-Item -LiteralPath (Join-Path $bridgeDirectory 'go.mod') -Destination $modfilePath
Copy-Item -LiteralPath (Join-Path $bridgeDirectory 'go.sum') -Destination (Join-Path $modfileDirectory 'dropoandroid.sum')
Push-Location $bridgeDirectory
try {
    & $GoCommand mod edit "-modfile=$modfilePath" "-replace=github.com/xtls/xray-core=$stagedModule" "-replace=dropocore=$(Join-Path $repositoryRoot 'app/mobile/dropocore')"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to prepare the isolated Android XHTTP modfile.' }
} finally { Pop-Location }

# gomobile generates a separate gobind module per ABI. An inherited -modfile
# would override those generated modules and be shared by concurrent builds.
# Bind from an isolated bridge copy with local replacements instead, inheriting
# only -overlay. The original bridge go.mod/go.sum are never edited.
$bindingDirectory = Join-Path $modfileDirectory 'bind'
New-Item -ItemType Directory -Path $bindingDirectory | Out-Null
foreach ($source in Get-ChildItem -LiteralPath $bridgeDirectory -File | Where-Object { $_.Extension -ceq '.go' -or $_.Name -cin @('go.mod', 'go.sum') }) {
    $bindingSource = Join-Path $bindingDirectory $source.Name
    $bindingSourceHash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Copy-Item -LiteralPath $source.FullName -Destination $bindingSource
    Assert-OverlaySHA256 -Path $bindingSource -Expected $bindingSourceHash -Label 'isolated binding source'
}
Push-Location $bindingDirectory
try {
    & $GoCommand mod edit "-replace=github.com/xtls/xray-core=$stagedModule" "-replace=dropocore=$(Join-Path $repositoryRoot 'app/mobile/dropocore')"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to prepare the isolated Android gomobile binding module.' }
} finally { Pop-Location }
if ($overlayPath.Contains('"') -or $modfilePath.Contains('"')) { throw 'Android XHTTP output path contains an unsupported quote.' }
[pscustomobject]@{
    Path = $overlayPath
    # GOFLAGS uses Go's quoted-word parser: quote the entire flag, not only
    # its value, so Windows paths containing spaces remain one argument.
    GoFlag = '"-modfile=' + $modfilePath + '" "-overlay=' + $overlayPath + '"'
    BindingGoFlag = '"-overlay=' + $overlayPath + '"'
    BindingDirectory = $bindingDirectory
    ModuleDirectory = $stagedModule
    OriginalModuleDirectory = $moduleRoot
    ModfilePath = $modfilePath
    ManifestSHA256 = $manifestHash
    Files = $files.Count
}
