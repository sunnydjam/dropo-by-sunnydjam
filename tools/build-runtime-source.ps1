# Build the bundled VPN sidecars from a checksum-locked module graph.
# Does not execute the resulting binaries, install services or change networking.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('singbox', 'xray')][string]$Component
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleRoot = Join-Path $PSScriptRoot 'runtime-source'
$lock = Get-Content -LiteralPath (Join-Path $moduleRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
$entry = $lock.components.$Component
if ($lock.schemaVersion -ne 1 -or -not $entry -or $lock.toolchain -ne 'go1.27.3') {
    throw 'Unsupported runtime source lock.'
}
function Assert-RuntimeHash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Runtime source checksum mismatch: $Path"
    }
}
foreach ($file in @('go.mod', 'go.sum')) {
    Assert-RuntimeHash (Join-Path $moduleRoot $file) $lock.files.$file
}
$version = Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json
if ($version.$Component.sourceBuild -ne $true -or
    $version.$Component.executableSha256 -ne $entry.executableSha256) {
    throw 'Runtime source lock and release metadata disagree.'
}
# Every path component must remain a normal file/directory inside this checkout.
function Assert-CheckoutPath([string]$Relative) {
    $full = [IO.Path]::GetFullPath((Join-Path $repo $Relative))
    if (-not $full.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Runtime destination escapes the checkout.'
    }
    $cursor = $repo
    foreach ($part in $Relative.Replace('/', '\').Split('\')) {
        if ($part -in @('', '.', '..')) { throw 'Invalid runtime path component.' }
        $cursor = Join-Path $cursor $part
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Runtime paths must not traverse a reparse point.'
        }
    }
    return $full
}
$destination = Assert-CheckoutPath ([string]$entry.destination)
$work = Assert-CheckoutPath ('dependencies/runtime-source-work/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$candidate = Join-Path $work ([IO.Path]::GetFileName($destination))
$savedEnvironment = @{}
foreach ($name in @('GOTOOLCHAIN', 'GOOS', 'GOARCH', 'GOAMD64', 'CGO_ENABLED', 'GOFLAGS', 'GOENV', 'GOWORK', 'GOPROXY', 'GOSUMDB', 'GOPRIVATE', 'GONOSUMDB', 'GONOPROXY')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $moduleRoot
try {
    $env:GOTOOLCHAIN = $lock.toolchain
    $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:GOAMD64 = 'v1'; $env:CGO_ENABLED = '0'
    $env:GOFLAGS = '-p=2'; $env:GOENV = 'off'; $env:GOWORK = 'off'
    $env:GOPROXY = 'https://proxy.golang.org,direct'; $env:GOSUMDB = 'sum.golang.org'
    $env:GOPRIVATE = ''; $env:GONOSUMDB = ''; $env:GONOPROXY = ''
    $actualGo = & go env GOVERSION
    if ($LASTEXITCODE -ne 0 -or $actualGo -ne $lock.toolchain) { throw 'Incorrect runtime build toolchain.' }
    $source = (& go mod download -json "$($entry.module)@$($entry.version)" | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $source.Error -or $source.Sum -ne $entry.moduleSum) {
        throw 'Upstream module download did not match the reviewed source.'
    }
    & go mod verify
    if ($LASTEXITCODE -ne 0) { throw 'Runtime module cache verification failed.' }
    if (Test-Path -LiteralPath $destination) {
        $existing = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existing -notin @($entry.executableSha256, $entry.originalExecutableSha256)) {
            throw 'Unknown runtime bytes are retained; refusing to overwrite them.'
        }
    } else { $existing = '' }
    if ($existing -ne $entry.executableSha256) {
        $arguments = @('build', '-mod=readonly', '-trimpath', '-buildvcs=false', "-ldflags=$($entry.ldflags)")
        if ($entry.tags) { $arguments += "-tags=$($entry.tags)" }
        & go @arguments -o $candidate $entry.package
        if ($LASTEXITCODE -ne 0) { throw 'Runtime source build failed; installed cache has not been replaced.' }
        Assert-RuntimeHash $candidate $entry.executableSha256
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        if ($existing) {
            # Retain the exact reviewed upstream binary. No recursive deletion.
            Copy-Item -LiteralPath $destination -Destination (Join-Path $work 'original.exe')
            Assert-RuntimeHash (Join-Path $work 'original.exe') $existing
        }
        Copy-Item -LiteralPath $candidate -Destination $destination -Force
    }
    Assert-RuntimeHash $destination $entry.executableSha256
    $license = Join-Path $source.Dir 'LICENSE'
    if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { throw 'Verified upstream module has no LICENSE.' }
    Copy-Item -LiteralPath $license -Destination (Join-Path (Split-Path $destination -Parent) 'LICENSE') -Force
    foreach ($file in @('go.mod', 'go.sum')) { Assert-RuntimeHash (Join-Path $moduleRoot $file) $lock.files.$file }
    Write-Host "[OK] ${Component}: locked source and executable verified."
} finally {
    Pop-Location
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
