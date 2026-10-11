param(
    [switch]$RunGoTests,
    [switch]$Race,
    [string]$GoCommand = 'go'
)

$ErrorActionPreference = 'Stop'
if ($Race -and -not $RunGoTests) { throw '-Race requires -RunGoTests.' }
$repositoryRoot = Split-Path $PSScriptRoot
$preparer = Join-Path $PSScriptRoot 'prepare-android-xhttp-overlay.ps1'
$manifestPath = Join-Path $repositoryRoot 'app/mobile/dropoandroid/xray_overlay/manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$overlayRoot = Split-Path $manifestPath
$expectedFiles = @('client.go.txt', 'dialer.go.txt', 'managed_session.go.txt', 'managed_session_test.go.txt')
if ($manifest.moduleVersion -cne 'v1.260327.0' -or @($manifest.files).Count -ne 4) {
    throw 'Android XHTTP source/test overlay contract is incomplete.'
}
foreach ($name in $expectedFiles) {
    $entry = @($manifest.files | Where-Object { $_.replacementPath -ceq "files/$name" })
    if ($entry.Count -ne 1) { throw "Missing Android XHTTP corresponding source: $name" }
    foreach ($path in @((Join-Path $overlayRoot $entry[0].replacementPath), (Join-Path $repositoryRoot $entry[0].bundledAssetPath))) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[0].replacementSha256) {
            throw "Android XHTTP source/asset contract diverged: $name"
        }
    }
}
$pubspec = Get-Content -LiteralPath (Join-Path $repositoryRoot 'flutter_app/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^\s+- assets/licenses/xray-core-source/\s*$') {
    throw 'Android XHTTP corresponding source assets are not packaged.'
}
$buildScript = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts/build/build.ps1') -Raw
foreach ($marker in @('prepare-android-xhttp-overlay.ps1', '"*.go.txt"', '"manifest.json"', '$xhttpOverlay.BindingDirectory', '$xhttpOverlay.BindingGoFlag', '$env:GOFLAGS = $originalAndroidGoFlags')) {
    if (-not $buildScript.Contains($marker)) { throw 'Android XHTTP overlay is missing from the build/cache contract.' }
}

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$fixtureRoot = Join-Path $temporaryParent ('dropo-xhttp-overlay-fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$originalGoFlags = $env:GOFLAGS
$fixtureCount = 0

function Assert-OverlayRejected {
    param([string]$Path, [string]$Module, [string]$ExpectedMessage)
    $rejected = $false
    try {
        $null = & $preparer -ManifestPath $Path -ModuleDirectory $Module -OutputDirectory (Join-Path $fixtureRoot 'rejected output') -GoCommand $GoCommand
    } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'An invalid Android XHTTP overlay was accepted.' }
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot 'rejected output')) {
        throw 'An invalid Android XHTTP overlay produced output.'
    }
}

function Write-OverlayFixtureManifest {
    param([object]$Value, [string]$Name)
    $path = Join-Path $fixtureRoot $Name
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
    return $path
}

try {
    $fakeModule = Join-Path $fixtureRoot 'module'
    $fakeTransport = Join-Path $fakeModule 'transport/internet/splithttp'
    $fixtureFiles = Join-Path $fixtureRoot 'files'
    New-Item -ItemType Directory -Path $fakeTransport, $fixtureFiles | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeModule 'go.mod'), "module github.com/xtls/xray-core`n", [Text.UTF8Encoding]::new($false))
    foreach ($entry in $manifest.files) {
        Copy-Item -LiteralPath (Join-Path $overlayRoot $entry.replacementPath) -Destination (Join-Path $fixtureFiles (Split-Path $entry.replacementPath -Leaf))
    }
    $validFixtureManifest = Write-OverlayFixtureManifest -Value $manifest -Name 'valid.json'
    Assert-OverlayRejected -Path $validFixtureManifest -Module $fakeModule -ExpectedMessage 'upstream source did not match'
    $fixtureCount++

    $modified = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modified.moduleVersion = 'v1.260101.0'
    Assert-OverlayRejected -Path (Write-OverlayFixtureManifest $modified 'wrong-version.json') -Module $fakeModule -ExpectedMessage 'approved pinned source'
    $fixtureCount++

    $modified = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modified.files[0].replacementPath = '../outside.go.txt'
    Assert-OverlayRejected -Path (Write-OverlayFixtureManifest $modified 'escape.json') -Module $fakeModule -ExpectedMessage 'safe relative path'
    $fixtureCount++

    $modified = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modified.files[0].replacementSha256 = '0' * 64
    Assert-OverlayRejected -Path (Write-OverlayFixtureManifest $modified 'wrong-patch.json') -Module $fakeModule -ExpectedMessage 'replacement source did not match'
    $fixtureCount++

    $modified = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $modified.files[0].bundledAssetPath = 'tools/prepare-android-xhttp-overlay.ps1'
    Assert-OverlayRejected -Path (Write-OverlayFixtureManifest $modified 'wrong-asset.json') -Module $fakeModule -ExpectedMessage 'bundled corresponding source did not match'
    $fixtureCount++

    if ($RunGoTests) {
        $overlay = & $preparer -OutputDirectory (Join-Path $fixtureRoot 'valid output') -GoCommand $GoCommand
        $again = & $preparer -OutputDirectory (Join-Path $fixtureRoot 'valid output') -GoCommand $GoCommand
        if ($overlay.Path -cne $again.Path -or $overlay.Files -ne 4) { throw 'Android XHTTP overlay is not deterministic.' }
        $mapping = Get-Content -LiteralPath $overlay.Path -Raw | ConvertFrom-Json
        if (@($mapping.Replace.PSObject.Properties).Count -ne 4) { throw 'Android XHTTP Go overlay mapping is incomplete.' }
        foreach ($entry in $manifest.files | Where-Object { $_.operation -ceq 'replace' }) {
            Copy-Item -LiteralPath (Join-Path $overlay.ModuleDirectory $entry.upstreamPath) -Destination (Join-Path $fakeModule $entry.upstreamPath)
        }
        $fixtureOverlay = & $preparer -ManifestPath $validFixtureManifest -ModuleDirectory $fakeModule -OutputDirectory (Join-Path $fixtureRoot 'valid fixture output') -GoCommand $GoCommand
        if ($fixtureOverlay.Files -ne 4) { throw 'Pinned fixture sources were not accepted.' }
        $fixtureCount++

        $addedPath = Join-Path $fakeTransport 'dropo_managed_session.go'
        Copy-Item -LiteralPath (Join-Path $fixtureFiles 'managed_session.go.txt') -Destination $addedPath
        Assert-OverlayRejected -Path $validFixtureManifest -Module $fakeModule -ExpectedMessage 'added source already exists'
        $fixtureCount++

        if ($originalGoFlags -match '(?:^|\s|\")-(?:overlay|modfile)(?:=|\s)') { throw 'Native overlay tests cannot combine another existing Go overlay or modfile.' }
        $env:GOFLAGS = ("$originalGoFlags " + $overlay.GoFlag).Trim()
        Push-Location (Join-Path $repositoryRoot 'app/mobile/dropoandroid')
        try {
            $testNames = & $GoCommand test '-ldflags=-checklinkname=0' '-list=^TestDropoManaged' 'github.com/xtls/xray-core/transport/internet/splithttp'
            if ($LASTEXITCODE -ne 0 -or @($testNames | Where-Object { $_ -match '^TestDropoManaged' }).Count -eq 0) {
                throw 'Android XHTTP upstream lifecycle regression tests were not compiled.'
            }
            $testArguments = @('test', '-ldflags=-checklinkname=0', '-run=^TestDropoManaged', '-count=1')
            if ($Race) { $testArguments += '-race' }
            $testArguments += 'github.com/xtls/xray-core/transport/internet/splithttp'
            & $GoCommand @testArguments
            if ($LASTEXITCODE -ne 0) { throw 'Android XHTTP upstream lifecycle regression tests failed.' }
        } finally { Pop-Location }
    }
    if (-not $RunGoTests -and $env:GOFLAGS -cne $originalGoFlags) { throw 'Overlay preparation changed the caller GOFLAGS.' }
    Write-Host "Android XHTTP overlay contract passed ($fixtureCount rejection/determinism fixtures)."
} finally {
    $env:GOFLAGS = $originalGoFlags
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixture.StartsWith($temporaryParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedFixture -Leaf) -notmatch '^dropo-xhttp-overlay-fixtures-[a-f0-9]{32}$') {
        throw 'Refusing to remove an unexpected Android XHTTP fixture directory.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
