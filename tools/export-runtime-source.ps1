# Accompany source-built GPL/MPL sidecars with their complete Go module sources.
param([Parameter(Mandatory = $true)][string]$DestinationDirectory)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$moduleRoot = Join-Path $PSScriptRoot 'runtime-source'
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
$releaseRoot = Join-Path $repo 'release'
if (-not $destination.StartsWith($releaseRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Corresponding source must be staged inside this checkout release directory.'
}
$cursor = $destination
while ($cursor.Length -ge $releaseRoot.Length) {
    if ((Test-Path -LiteralPath $cursor) -and
        ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Source export path traverses a reparse point.'
    }
    $cursor = Split-Path $cursor -Parent
}
$lock = Get-Content (Join-Path $moduleRoot 'runtime.lock.json') -Raw | ConvertFrom-Json
$saved = @{}
foreach ($name in @('GOTOOLCHAIN','GOOS','GOARCH','GOAMD64','CGO_ENABLED','GOFLAGS','GOENV','GOWORK','GOPROXY','GOSUMDB','GOPRIVATE','GONOSUMDB','GONOPROXY')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$archive = $null; $stream = $null
Push-Location $moduleRoot
try {
    $env:GOTOOLCHAIN=$lock.toolchain; $env:GOOS='windows'; $env:GOARCH='amd64'; $env:GOAMD64='v1'; $env:CGO_ENABLED='0'
    $env:GOFLAGS='-p=2'; $env:GOENV='off'; $env:GOWORK='off'
    $env:GOPROXY='https://proxy.golang.org,direct'; $env:GOSUMDB='sum.golang.org'
    $env:GOPRIVATE=''; $env:GONOSUMDB=''; $env:GONOPROXY=''
    $specs = @()
    foreach ($property in $lock.components.PSObject.Properties) {
        $component = $property.Value
        $arguments = @('list','-mod=readonly','-deps','-f','{{if .Module}}{{.Module.Path}}@{{.Module.Version}}{{end}}')
        if ($component.tags) { $arguments += "-tags=$($component.tags)" }
        $specs += @(& go @arguments $component.package | Where-Object { $_ -match '^.+@v[^\s]+$' })
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate the actual compiled module sources.' }
    }
    $specs = @($specs | Sort-Object -Unique)
    if ($specs.Count -lt 2) { throw 'Missing runtime source modules.' }
    $json = (& go mod download -json @specs | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Corresponding module source download failed.' }
    $modules = @((('[' + ($json -replace '(?m)^}\r?\n(?=\{)', '},') + ']') | ConvertFrom-Json))
    if ($modules.Count -ne $specs.Count) { throw 'Incomplete module source download receipt.' }
    foreach ($module in $modules) {
        if ($module.Error -or -not $module.Zip -or -not $module.Sum) { throw 'Module source archive is missing or unverified.' }
    }
    foreach ($file in @('go.mod','go.sum')) {
        if ((Get-FileHash (Join-Path $moduleRoot $file)).Hash.ToLowerInvariant() -ne $lock.files.$file) {
            throw 'Runtime source graph changed during source export.'
        }
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $final = Join-Path $destination 'dropo-Runtime-Sources.zip'
    $temporary = Join-Path $destination ('runtime-sources-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    function Add-SourceFile([string]$Source, [string]$Name) {
        $entry = $archive.CreateEntry($Name, [IO.Compression.CompressionLevel]::NoCompression)
        $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
        $inputStream = [IO.File]::OpenRead($Source); $outputStream = $entry.Open()
        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
    foreach ($file in @('go.mod','go.sum','runtime.lock.json','README.md')) {
        Add-SourceFile (Join-Path $moduleRoot $file) "build/tools/runtime-source/$file"
    }
    Add-SourceFile (Join-Path $repo 'version.json') 'build/version.json'
    Add-SourceFile (Join-Path $PSScriptRoot 'build-runtime-source.ps1') 'build/tools/build-runtime-source.ps1'
    Add-SourceFile (Join-Path $PSScriptRoot 'export-runtime-source.ps1') 'build/tools/export-runtime-source.ps1'
    $sourceManifest = @()
    foreach ($module in ($modules | Sort-Object Path,Version)) {
        $base = 'modules/' + $module.Path + '/@v/' + $module.Version
        Add-SourceFile $module.Zip ($base + '.zip')
        Add-SourceFile $module.GoMod ($base + '.mod')
        Add-SourceFile $module.Info ($base + '.info')
        $sourceManifest += [ordered]@{ path=$module.Path; version=$module.Version; sum=$module.Sum; archive=$base+'.zip'; sha256=(Get-FileHash $module.Zip).Hash.ToLowerInvariant() }
    }
    $entry = $archive.CreateEntry('modules.json')
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write(($sourceManifest | ConvertTo-Json -Depth 5)) } finally { $writer.Dispose() }
    $archive.Dispose(); $archive=$null; $stream=$null
    # Only a completed, closed archive replaces the previous generated export.
    [IO.File]::Move($temporary, $final, $true)
    $hash=(Get-FileHash $final).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($final+'.sha256', "$hash  dropo-Runtime-Sources.zip`n", [Text.UTF8Encoding]::new($false))
    Write-Host "[OK] Exported $($modules.Count) verified corresponding source modules."
} finally {
    if ($archive) { $archive.Dispose() } elseif ($stream) { $stream.Dispose() }
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
