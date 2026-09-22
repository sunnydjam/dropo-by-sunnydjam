param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeFolder,
    [string]$CMakeCachePath,
    [string]$DumpbinPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RuntimeFolder -PathType Container)) {
    throw "Windows UI runtime folder not found: $RuntimeFolder"
}

$uiExe = Join-Path $RuntimeFolder 'dropo-ui.exe'
if (-not (Test-Path -LiteralPath $uiExe -PathType Leaf)) {
    throw "Windows UI executable not found: $uiExe"
}

if ([string]::IsNullOrWhiteSpace($DumpbinPath) -and
    -not [string]::IsNullOrWhiteSpace($CMakeCachePath) -and
    (Test-Path -LiteralPath $CMakeCachePath -PathType Leaf)) {
    $cache = Get-Content -LiteralPath $CMakeCachePath -Raw
    $linker = [regex]::Match($cache, '(?m)^CMAKE_LINKER:FILEPATH=(.+)$')
    if ($linker.Success) {
        $candidate = Join-Path (Split-Path $linker.Groups[1].Value.Trim() -Parent) 'dumpbin.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $DumpbinPath = $candidate
        }
    }
}

if ([string]::IsNullOrWhiteSpace($DumpbinPath)) {
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($dumpbin) {
        $DumpbinPath = $dumpbin.Source
    }
}
if ([string]::IsNullOrWhiteSpace($DumpbinPath) -or
    -not (Test-Path -LiteralPath $DumpbinPath -PathType Leaf)) {
    throw 'dumpbin.exe is required to verify Windows UI imports; provide -DumpbinPath or a Flutter CMake cache.'
}

# Flutter installs native plugin DLLs beside the UI executable. Check each
# shipped PE instead of trusting the build host's System32/PATH, which may
# contain a VC++ runtime that is absent on a clean customer machine.
$nativeFiles = @($uiExe) + @(
    Get-ChildItem -LiteralPath $RuntimeFolder -File |
        Where-Object { $_.Extension -ieq '.dll' } |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
foreach ($nativeFile in $nativeFiles) {
    $output = @(& $DumpbinPath /dependents $nativeFile 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for $nativeFile (exit code $LASTEXITCODE): $($output -join ' ')"
    }
    $imports = @([regex]::Matches(($output -join "`n"), '(?im)^\s+([A-Za-z0-9_.-]+\.dll)\s*$') |
        ForEach-Object { $_.Groups[1].Value })
    $dynamicCRT = @($imports | Where-Object {
        $_ -match '^(?:MSVCP|VCRUNTIME|CONCRT|VCOMP|MFC|ATL)[A-Za-z0-9_]*\.dll$'
    } | Sort-Object -Unique)
    if ($dynamicCRT.Count -gt 0) {
        throw "$([IO.Path]::GetFileName($nativeFile)) imports a machine-wide MSVC runtime: $($dynamicCRT -join ', '). Rebuild Flutter with the static CRT before packaging."
    }
}

Write-Host "[OK] Windows UI native imports are self-contained ($($nativeFiles.Count) PE files)." -ForegroundColor Green
