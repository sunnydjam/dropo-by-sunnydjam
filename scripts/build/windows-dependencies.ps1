function Ensure-SingBoxWindowsDependency {
    if ($VersionInfo.singbox.sourceBuild -eq $true) {
        & (Join-Path $ScriptRoot 'tools\build-runtime-source.ps1') -Component singbox
        Assert-FileSHA256 -Path $SingBoxExe -ExpectedSHA256 $SingBoxExeSHA256 -Label 'sing-box source build'
        return
    }
    if (Test-Path $SingBoxExe) {
        Assert-FileSHA256 -Path $SingBoxExe -ExpectedSHA256 $SingBoxExeSHA256 -Label "sing-box executable"
        return
    }

    Write-Host "[SING-BOX] Downloading sing-box v$SingBoxVersion for Windows..." -ForegroundColor Yellow
    $archiveUrl = "https://github.com/SagerNet/sing-box/releases/download/v$SingBoxVersion/sing-box-$SingBoxVersion-windows-amd64.zip"
    $tmpDir = Join-Path $env:TEMP ("dropo-sing-box-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tmpDir "sing-box.zip"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    try {
        Download-File -Url $archiveUrl -Destination $zipPath
        Assert-FileSHA256 -Path $zipPath -ExpectedSHA256 $SingBoxArchiveSHA256 -Label "sing-box archive"
        if (-not (Test-Path $SingBoxDir)) {
            New-Item -ItemType Directory -Path $SingBoxDir | Out-Null
        }
        $targetRoot = Join-Path $SingBoxDir "windows-amd64"
        if (Test-Path $targetRoot) {
            Remove-Item -LiteralPath $targetRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $targetRoot | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $targetRoot -Force
        if (-not (Test-Path $SingBoxExe)) {
            throw "Downloaded archive did not contain expected file: $SingBoxExe"
        }
        Assert-FileSHA256 -Path $SingBoxExe -ExpectedSHA256 $SingBoxExeSHA256 -Label "sing-box executable"
        Write-Host "[OK] Downloaded sing-box.exe v$SingBoxVersion" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-WinDivertWindowsDependency {
    $expected = Join-Path $WinDivertX64Dir "WinDivert.dll"
    if (Test-Path $expected) {
        Assert-FileSHA256 -Path $expected -ExpectedSHA256 $WinDivertDllSHA256 -Label "WinDivert DLL"
        Assert-FileSHA256 -Path (Join-Path $WinDivertX64Dir "WinDivert64.sys") -ExpectedSHA256 $WinDivertDriverSHA256 -Label "WinDivert driver"
        return
    }
    if ($WinDivertArchiveSHA256 -notmatch '^[0-9a-f]{64}$') {
        throw "version.json must pin windivert.archiveSha256 for WinDivert v$WinDivertVersion."
    }

    Write-Host "[WINDIVERT] Downloading official WinDivert v$WinDivertVersion..." -ForegroundColor Yellow
    $tmpDir = Join-Path $env:TEMP ("dropo-windivert-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tmpDir "windivert.zip"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    try {
        Download-File -Url $WinDivertArchiveURL -Destination $zipPath
        $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $WinDivertArchiveSHA256) {
            throw "WinDivert archive hash mismatch: expected $WinDivertArchiveSHA256, got $actualHash"
        }
        $extractRoot = Join-Path $tmpDir "extract"
        Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
        $extracted = Join-Path $extractRoot "WinDivert-$WinDivertVersion-A"
        if (-not (Test-Path (Join-Path $extracted "x64\WinDivert64.sys") -PathType Leaf)) {
            throw "Official archive did not contain the expected x64 WinDivert files."
        }
        if (Test-Path $WinDivertDir) {
            Remove-Item -LiteralPath $WinDivertDir -Recurse -Force
        }
        Copy-Item -LiteralPath $extracted -Destination $WinDivertDir -Recurse -Force
        if (-not (Test-Path $expected)) {
            throw "Downloaded archive did not contain expected file: $expected"
        }
        Assert-FileSHA256 -Path $expected -ExpectedSHA256 $WinDivertDllSHA256 -Label "WinDivert DLL"
        Assert-FileSHA256 -Path (Join-Path $WinDivertX64Dir "WinDivert64.sys") -ExpectedSHA256 $WinDivertDriverSHA256 -Label "WinDivert driver"
        Write-Host "[OK] Downloaded and SHA-256 verified official WinDivert v$WinDivertVersion" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-FileSHA256 {
    param(
        [string]$Path,
        [string]$ExpectedSHA256,
        [string]$Label
    )
    if ($ExpectedSHA256 -notmatch '^[0-9a-f]{64}$') {
        throw "$Label has no pinned SHA-256 in version.json."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSHA256) {
        throw "$Label SHA-256 mismatch: expected $ExpectedSHA256, got $actual"
    }
}

function Ensure-XrayWindowsDependency {
    if ($VersionInfo.xray.sourceBuild -eq $true) {
        & (Join-Path $ScriptRoot 'tools\build-runtime-source.ps1') -Component xray
        Assert-FileSHA256 -Path $XrayExe -ExpectedSHA256 $XrayExeSHA256 -Label 'Xray source build'
        return
    }
    if (Test-Path -LiteralPath $XrayExe -PathType Leaf) {
        Assert-FileSHA256 -Path $XrayExe -ExpectedSHA256 $XrayExeSHA256 -Label "Xray executable"
        return
    }
    $tmpDir = Join-Path $env:TEMP ("dropo-xray-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tmpDir "Xray-windows-64.zip"
    try {
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        Download-File -Url "https://github.com/XTLS/Xray-core/releases/download/v$XrayVersion/Xray-windows-64.zip" -Destination $zipPath
        Assert-FileSHA256 -Path $zipPath -ExpectedSHA256 $XrayArchiveSHA256 -Label "Xray archive"
        if (Test-Path -LiteralPath $XrayDir) {
            Remove-Item -LiteralPath $XrayDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $XrayDir | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $XrayDir -Force
        if (-not (Test-Path -LiteralPath $XrayExe -PathType Leaf)) {
            throw "Official Xray archive does not contain xray.exe."
        }
        Assert-FileSHA256 -Path $XrayExe -ExpectedSHA256 $XrayExeSHA256 -Label "Xray executable"
        Write-Host "[OK] Downloaded and verified Xray-core v$XrayVersion" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-WireGuardWindowsDependency {
    $wireGuardDir = Join-Path $DepsDir "wireguard-windows-v$WireGuardVersion"
    $expectedFiles = [ordered]@{
        "wireguard.exe" = $WireGuardExeSHA256
        "wg.exe"        = $WireGuardWgSHA256
        "wintun.dll"    = $WireGuardWintunSHA256
    }
    $complete = $true
    foreach ($entry in $expectedFiles.GetEnumerator()) {
        $candidate = Join-Path $wireGuardDir $entry.Key
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $complete = $false
            break
        }
        Assert-FileSHA256 -Path $candidate -ExpectedSHA256 $entry.Value -Label "WireGuard $($entry.Key)"
    }
    if ($complete) {
        return
    }

    $tmpDir = Join-Path $env:TEMP ("dropo-wireguard-" + [Guid]::NewGuid().ToString("N"))
    $msiPath = Join-Path $tmpDir "wireguard-amd64-$WireGuardVersion.msi"
    $extractDir = Join-Path $tmpDir "extract"
    try {
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        Download-File -Url "https://download.wireguard.com/windows-client/wireguard-amd64-$WireGuardVersion.msi" -Destination $msiPath
        $signature = Get-AuthenticodeSignature -LiteralPath $msiPath
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch 'WireGuard') {
            throw "Official WireGuard MSI has no valid WireGuard Authenticode signature."
        }
        New-Item -ItemType Directory -Path $extractDir | Out-Null
        $process = Start-Process msiexec.exe -ArgumentList @('/a', ('"' + $msiPath + '"'), '/qn', ('TARGETDIR="' + $extractDir + '"')) -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "WireGuard administrative MSI extraction failed with exit code $($process.ExitCode)."
        }
        if (Test-Path -LiteralPath $wireGuardDir) {
            Remove-Item -LiteralPath $wireGuardDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $wireGuardDir | Out-Null
        foreach ($entry in $expectedFiles.GetEnumerator()) {
            if ($entry.Key -eq "wintun.dll") {
                # WireGuard's MSI embeds Wintun and does not expose it in an
                # administrative extraction. Xray's official Windows archive
                # ships the same pinned upstream Wintun DLL as a normal file.
                $sourceFile = Join-Path $XrayDir "wintun.dll"
                if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                    # Source-built Xray does not include the third-party DLL.
                    # Extract this one pinned auxiliary asset from the reviewed
                    # official archive; never overwrite the source-built core.
                    $xrayAuxZip = Join-Path $tmpDir 'xray-auxiliary.zip'
                    Download-File -Url "https://github.com/XTLS/Xray-core/releases/download/v$XrayVersion/Xray-windows-64.zip" -Destination $xrayAuxZip
                    Assert-FileSHA256 -Path $xrayAuxZip -ExpectedSHA256 $XrayArchiveSHA256 -Label 'Xray auxiliary archive'
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $auxiliary = [IO.Compression.ZipFile]::OpenRead($xrayAuxZip)
                    try {
                        $entries = @($auxiliary.Entries | Where-Object { $_.FullName -ceq 'wintun.dll' })
                        if ($entries.Count -ne 1) { throw 'Expected exactly one pinned Wintun auxiliary entry.' }
                        $sourceFile = Join-Path $tmpDir 'wintun.dll'
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $sourceFile)
                    } finally { $auxiliary.Dispose() }
                }
            } else {
                $matches = @(Get-ChildItem -LiteralPath $extractDir -Recurse -File -Filter $entry.Key)
                if ($matches.Count -ne 1) {
                    throw "WireGuard MSI must contain exactly one $($entry.Key); found $($matches.Count)."
                }
                $sourceFile = $matches[0].FullName
            }
            Assert-FileSHA256 -Path $sourceFile -ExpectedSHA256 $entry.Value -Label "WireGuard $($entry.Key)"
            Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $wireGuardDir $entry.Key)
        }
        Download-File -Url "https://raw.githubusercontent.com/WireGuard/wireguard-windows/v$WireGuardVersion/COPYING" -Destination (Join-Path $wireGuardDir "LICENSE")
        Write-Host "[OK] Downloaded and verified WireGuard for Windows v$WireGuardVersion" -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
