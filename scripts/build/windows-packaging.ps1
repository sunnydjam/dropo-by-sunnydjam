function New-AppOnlyArchive {
    param(
        [string]$SourceAppFolder,
        [string]$DestinationZip
    )

    New-DeterministicZip -SourceDirectory $SourceAppFolder -DestinationZip $DestinationZip
}

function New-DeterministicZip {
    param(
        [string]$SourceDirectory,
        [string]$DestinationZip
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory).Path.TrimEnd('\')
    if (Test-Path -LiteralPath $DestinationZip) {
        Remove-Item -LiteralPath $DestinationZip -Force
    }
    $zipParent = Split-Path -Parent $DestinationZip
    if ($zipParent -and -not (Test-Path -LiteralPath $zipParent)) {
        New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
    }
    $fileStream = [IO.File]::Open($DestinationZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = [IO.Compression.ZipArchive]::new($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        $entryTime = [DateTimeOffset]::new($BuildDate)
        if ($entryTime.Year -lt 1980) {
            $entryTime = [DateTimeOffset]::new([DateTime]::new(1980, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart([char[]]"\/").Replace('\', '/')
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $entryTime
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $fileStream.Dispose()
    }
}

function Get-InnoSetupCommand {
    if ($env:DROPO_INNO_ISCC_PATH) {
        if (-not (Test-Path -LiteralPath $env:DROPO_INNO_ISCC_PATH -PathType Leaf)) {
            throw "DROPO_INNO_ISCC_PATH does not point to ISCC.exe: $env:DROPO_INNO_ISCC_PATH"
        }
        return $env:DROPO_INNO_ISCC_PATH
    }
    $toolchainInno = Join-Path $ToolchainRoot "inno\ISCC.exe"
    if (Test-Path -LiteralPath $toolchainInno -PathType Leaf) {
        return $toolchainInno
    }
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $fromPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }
    return $null
}

function New-WindowsInstaller {
    param(
        [string]$SourceAppFolder,
        [string]$DestinationExe,
        [string]$PackageVersion
    )

    $iscc = Get-InnoSetupCommand
    if (-not $iscc) {
        throw "Inno Setup 6 was not found. Install it with: winget install --id JRSoftware.InnoSetup -e"
    }
    $script = Join-Path $ScriptRoot "packaging\windows\dropo.iss"
    $setupIcon = Join-Path $ScriptRoot "flutter_app\windows\runner\resources\app_icon.ico"
    if (-not (Test-Path -LiteralPath $setupIcon -PathType Leaf)) {
        throw "Windows installer icon was not found: $setupIcon"
    }
    $outputDir = Split-Path -Parent $DestinationExe
    $baseName = [IO.Path]::GetFileNameWithoutExtension($DestinationExe)
    & $iscc "/DSourceDir=$SourceAppFolder" "/DOutputDir=$outputDir" "/DAppVersion=$PackageVersion" "/DSetupBaseName=$baseName" "/DSetupIconFile=$setupIcon" $script
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $DestinationExe -PathType Leaf)) {
        throw "Inno Setup did not create the expected installer: $DestinationExe"
    }
    Invoke-WindowsCodeSigning -Paths @($DestinationExe)
}
