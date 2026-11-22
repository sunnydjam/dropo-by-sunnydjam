# Supplemental publication preflight for the future installed Windows WFP guard.
# The caller must obtain ExpectedManifestSHA256 from the trusted build inputs
# used to link the signed core, never calculate it from the adjacent manifest.
# This script cannot independently extract that value from the signed core and
# is not a standalone proof of core/manifest binding. It does not install,
# start, or claim that a kill switch is active.
param(
    [string]$RuntimeFolder,
    [string]$ExpectedManifestSHA256,
    [string]$ExpectedSignerThumbprint,
    [switch]$FunctionsOnly
)

$ErrorActionPreference = 'Stop'

function Copy-VerifiedDropoWfpGuard {
    param(
        [Parameter(Mandatory = $true)][string]$BinaryPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSHA256,
        [Parameter(Mandatory = $true)][string]$BinFolder
    )

    if ($ExpectedSHA256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'The opt-in WFP guard binary requires an independently pinned SHA-256.'
    }
    $source = (Resolve-Path -LiteralPath $BinaryPath -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'The opt-in WFP guard source must be a regular file.'
    }
    if (((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The opt-in WFP guard source cannot be a reparse point.'
    }
    $bin = (Resolve-Path -LiteralPath $BinFolder -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $bin -PathType Container) -or
        ((Get-Item -LiteralPath $bin -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The WFP guard destination must be a regular bin directory.'
    }
    $destination = Join-Path $bin 'dropo-wfp-guard.exe'
    if (Test-Path -LiteralPath $destination) {
        throw 'Refusing to overwrite a stale or previously staged WFP guard binary.'
    }
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($sourceHash -ine $ExpectedSHA256) {
        throw 'The opt-in WFP guard source does not match its independently pinned SHA-256.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $source
    if ($null -eq $signature -or
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -eq $signature.SignerCertificate.Issuer) {
        throw 'The opt-in WFP guard source requires a Windows-trusted Authenticode signature.'
    }
    Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $ExpectedSHA256) {
        throw 'The staged WFP guard differs from its pinned source hash.'
    }
    $stagedSignature = Get-AuthenticodeSignature -LiteralPath $destination
    if ($null -eq $stagedSignature -or
        $stagedSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $stagedSignature.SignerCertificate -or
        $stagedSignature.SignerCertificate.Subject -eq $stagedSignature.SignerCertificate.Issuer) {
        throw 'The staged WFP guard lost its trusted Authenticode signature.'
    }
    return $destination
}

function Assert-DropoWfpGuardRelease {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeFolder,
        [Parameter(Mandatory = $true)][string]$ExpectedManifestSHA256,
        [string]$ExpectedSignerThumbprint
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeFolder)) {
        throw 'The runtime folder is required.'
    }
    $runtime = (Resolve-Path -LiteralPath $RuntimeFolder -ErrorAction Stop).ProviderPath
    $manifestPath = Join-Path $runtime 'runtime-manifest.json'
    $corePath = Join-Path $runtime 'dropo-core.exe'
    $binPath = Join-Path $runtime 'bin'
    $guardPath = Join-Path $binPath 'dropo-wfp-guard.exe'

    foreach ($path in @($manifestPath, $corePath, $guardPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "WFP guard preflight requires a regular release file: $path"
        }
        $file = Get-Item -LiteralPath $path -Force
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "WFP guard preflight rejects a reparse-point file: $path"
        }
    }
    $bin = Get-Item -LiteralPath $binPath -Force
    if (($bin.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "WFP guard preflight rejects a reparse-point directory: $binPath"
    }

    if ($ExpectedManifestSHA256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'ExpectedManifestSHA256 must be the SHA-256 embedded into the signed core.'
    }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if ($manifestHash -ine $ExpectedManifestSHA256) {
        throw 'The runtime manifest does not match the expected signed-core manifest SHA-256.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw 'The runtime manifest version is missing.'
    }
    $files = @($manifest.files)
    if ($files.Count -eq 0 -or $files.Count -gt 20000) {
        throw 'The runtime manifest file count is invalid.'
    }
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $files) {
        $relative = [string]$entry.path
        if ($relative -cnotmatch '^bin/(?:[^/\\:]+/)*[^/\\:]+$' -or
            @($relative.Split('/') | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -ne 0) {
            throw "The runtime manifest contains an unsafe path: $relative"
        }
        if (-not $seenPaths.Add($relative)) {
            throw "The runtime manifest contains a duplicate path: $relative"
        }
    }
    $guardEntries = @($files | Where-Object { [string]$_.path -ieq 'bin/dropo-wfp-guard.exe' })
    if ($guardEntries.Count -ne 1) {
        throw "The runtime manifest must contain exactly one bin/dropo-wfp-guard.exe entry (found $($guardEntries.Count))."
    }
    $guardEntry = $guardEntries[0]
    if ([string]$guardEntry.path -cne 'bin/dropo-wfp-guard.exe') {
        throw 'The WFP guard manifest path must use its canonical spelling.'
    }
    $expectedHash = [string]$guardEntry.sha256
    if ($expectedHash -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'The WFP guard manifest SHA-256 is missing or malformed.'
    }
    $expectedSize = -1L
    if (-not [long]::TryParse([string]$guardEntry.size, [ref]$expectedSize) -or $expectedSize -lt 0) {
        throw 'The WFP guard manifest size is missing or malformed.'
    }
    if ((Get-Item -LiteralPath $guardPath).Length -ne $expectedSize) {
        throw 'The WFP guard size does not match the runtime manifest.'
    }
    $actualHash = (Get-FileHash -LiteralPath $guardPath -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHash) {
        throw 'The WFP guard SHA-256 does not match the runtime manifest.'
    }

    $signers = @{}
    foreach ($path in @($corePath, $guardPath)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($null -eq $signature -or
            $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $null -eq $signature.SignerCertificate) {
            throw "A trusted Authenticode signature is required: $path"
        }
        $certificate = $signature.SignerCertificate
        if ($certificate.Subject -eq $certificate.Issuer) {
            throw "A self-signed Authenticode certificate is not accepted for the WFP guard: $path"
        }
        $thumbprint = ([string]$certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
        if ($thumbprint -cnotmatch '^[0-9A-F]{40}$') {
            throw "The Authenticode signer thumbprint is invalid: $path"
        }
        $signers[$path] = $thumbprint
    }
    if ($signers[$guardPath] -cne $signers[$corePath]) {
        throw 'The WFP guard and signed core must have the same Authenticode signer.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)) {
        $pinned = ($ExpectedSignerThumbprint -replace '\s', '').ToUpperInvariant()
        if ($pinned -cnotmatch '^[0-9A-F]{40}$') {
            throw 'ExpectedSignerThumbprint must be a 40-character certificate thumbprint.'
        }
        if ($signers[$guardPath] -cne $pinned) {
            throw 'The WFP guard signer does not match the pinned release certificate.'
        }
    }

    # Detect a guard that changed while its signature was being inspected.
    if ((Get-FileHash -LiteralPath $guardPath -Algorithm SHA256).Hash -ine $expectedHash) {
        throw 'The WFP guard changed during release preflight.'
    }
    [pscustomobject]@{
        GuardPath        = $guardPath
        ManifestVersion  = [string]$manifest.version
        SHA256           = $actualHash.ToLowerInvariant()
        SignerThumbprint = $signers[$guardPath]
    }
}

function Assert-DropoWfpGuardInstallerRelease {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeFolder,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedManifestSHA256,
        [string]$ExpectedSignerThumbprint
    )

    $guard = Assert-DropoWfpGuardRelease -RuntimeFolder $RuntimeFolder `
        -ExpectedManifestSHA256 $ExpectedManifestSHA256 `
        -ExpectedSignerThumbprint $ExpectedSignerThumbprint
    $installer = (Resolve-Path -LiteralPath $InstallerPath -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or
        (((Get-Item -LiteralPath $installer -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'The WFP guard installer must be a regular non-reparse-point file.'
    }
    $before = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($null -eq $signature -or
        $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -eq $signature.SignerCertificate.Issuer) {
        throw 'The WFP guard installer requires a Windows-trusted Authenticode signature.'
    }
    $thumbprint = ([string]$signature.SignerCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($thumbprint -cnotmatch '^[0-9A-F]{40}$' -or $thumbprint -cne $guard.SignerThumbprint) {
        throw 'The WFP guard installer, core and guard must have the same Authenticode signer.'
    }
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $before) {
        throw 'The WFP guard installer changed during release preflight.'
    }
    [pscustomobject]@{
        InstallerPath = $installer
        GuardPath = $guard.GuardPath
        ManifestVersion = $guard.ManifestVersion
        SignerThumbprint = $thumbprint
    }
}

if (-not $FunctionsOnly) {
    if ([string]::IsNullOrWhiteSpace($RuntimeFolder)) {
        throw 'Pass -RuntimeFolder pointing to the release resources directory.'
    }
    $result = Assert-DropoWfpGuardRelease -RuntimeFolder $RuntimeFolder -ExpectedManifestSHA256 $ExpectedManifestSHA256 -ExpectedSignerThumbprint $ExpectedSignerThumbprint
    Write-Host "[OK] Windows-trusted WFP guard release preflight: $($result.GuardPath)"
}
