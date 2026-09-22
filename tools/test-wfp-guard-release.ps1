$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-wfp-guard-release.ps1') -FunctionsOnly

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('dropo-wfp-guard-preflight-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $testRoot 'resources'
$bin = Join-Path $runtime 'bin'
$core = Join-Path $runtime 'dropo-core.exe'
$guard = Join-Path $bin 'dropo-wfp-guard.exe'
$sourceGuard = Join-Path $testRoot 'guard-source.exe'
$installer = Join-Path $testRoot 'dropo-setup.exe'
$manifestPath = Join-Path $runtime 'runtime-manifest.json'
[void][IO.Directory]::CreateDirectory($bin)

$script:validThumbprint = 'A' * 40
$script:guardThumbprint = $script:validThumbprint
$script:coreThumbprint = $script:validThumbprint
$script:installerThumbprint = $script:validThumbprint
$script:guardStatus = [System.Management.Automation.SignatureStatus]::Valid
$script:coreStatus = [System.Management.Automation.SignatureStatus]::Valid
$script:installerStatus = [System.Management.Automation.SignatureStatus]::Valid
$script:selfSigned = $false

# The test substitutes Authenticode readback only. Hash and size still use
# real files so corruption and manifest mismatch are exercised end to end.
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    $isGuard = $LiteralPath -eq $guard -or $LiteralPath -eq $sourceGuard
    $isInstaller = $LiteralPath -eq $installer
    $subject = 'CN=Dropo Publisher'
    [pscustomobject]@{
        Status = if ($isGuard) { $script:guardStatus } elseif ($isInstaller) { $script:installerStatus } else { $script:coreStatus }
        SignerCertificate = [pscustomobject]@{
            Subject = $subject
            Issuer = if ($script:selfSigned) { $subject } else { 'CN=Public CA' }
            Thumbprint = if ($isGuard) { $script:guardThumbprint } elseif ($isInstaller) { $script:installerThumbprint } else { $script:coreThumbprint }
        }
    }
}

function Set-TestManifest {
    param([object[]]$Files)
    $document = [ordered]@{ version = 'abcdef012345'; files = $Files }
    [IO.File]::WriteAllText($manifestPath, ($document | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $script:manifestSHA = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
}

function New-GuardEntry {
    $file = Get-Item -LiteralPath $guard
    [ordered]@{
        path = 'bin/dropo-wfp-guard.exe'
        size = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Reset-Fixture {
    [IO.File]::WriteAllBytes($core, [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes($guard, [byte[]](4, 5, 6))
    [IO.File]::WriteAllBytes($sourceGuard, [byte[]](4, 5, 6))
    [IO.File]::WriteAllBytes($installer, [byte[]](7, 8, 9))
    $script:guardSHA = (Get-FileHash -LiteralPath $sourceGuard -Algorithm SHA256).Hash
    $script:guardThumbprint = $script:validThumbprint
    $script:coreThumbprint = $script:validThumbprint
    $script:installerThumbprint = $script:validThumbprint
    $script:guardStatus = [System.Management.Automation.SignatureStatus]::Valid
    $script:coreStatus = [System.Management.Automation.SignatureStatus]::Valid
    $script:installerStatus = [System.Management.Automation.SignatureStatus]::Valid
    $script:selfSigned = $false
    Set-TestManifest -Files @((New-GuardEntry))
}

$caseCount = 0
function Assert-Passes {
    param([string]$Case, [scriptblock]$Action)
    & $Action | Out-Null
    $script:caseCount++
}
function Assert-Fails {
    param([string]$Case, [scriptblock]$Action, [string]$ExpectedMessage)
    try {
        & $Action | Out-Null
    } catch {
        if ($ExpectedMessage -and $_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "WFP guard preflight rejected '$Case' for the wrong reason: $($_.Exception.Message)"
        }
        $script:caseCount++
        return
    }
    throw "Expected WFP guard preflight to reject: $Case"
}

try {
    Reset-Fixture
    Assert-Passes 'valid manifest, hash and matching trusted signer' {
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA -ExpectedSignerThumbprint $validThumbprint
    }
    Assert-Passes 'installer, core and guard signed by one trusted publisher' {
        Assert-DropoWfpGuardInstallerRelease -RuntimeFolder $runtime -InstallerPath $installer -ExpectedManifestSHA256 $manifestSHA -ExpectedSignerThumbprint $validThumbprint
    }
    Reset-Fixture
    Assert-Fails 'missing guard installer' {
        Remove-Item -LiteralPath $installer
        Assert-DropoWfpGuardInstallerRelease -RuntimeFolder $runtime -InstallerPath $installer -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'unsigned guard installer' {
        $script:installerStatus = [System.Management.Automation.SignatureStatus]::NotSigned
        Assert-DropoWfpGuardInstallerRelease -RuntimeFolder $runtime -InstallerPath $installer -ExpectedManifestSHA256 $manifestSHA
    } 'Windows-trusted'
    Reset-Fixture
    Assert-Fails 'installer signed by another publisher' {
        $script:installerThumbprint = 'B' * 40
        Assert-DropoWfpGuardInstallerRelease -RuntimeFolder $runtime -InstallerPath $installer -ExpectedManifestSHA256 $manifestSHA
    } 'same Authenticode signer'
    Reset-Fixture
    Assert-Fails 'manifest does not match pinned build identity' {
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 ('B' * 64)
    }
    Reset-Fixture
    Assert-Fails 'missing guard binary' {
        Remove-Item -LiteralPath $guard
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'missing guard manifest entry' {
        Set-TestManifest -Files @([ordered]@{ path = 'bin/other.exe'; size = 1; sha256 = '0' * 64 })
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'duplicate guard manifest entry' {
        $entry = New-GuardEntry
        Set-TestManifest -Files @($entry, $entry)
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'noncanonical guard manifest path' {
        $entry = New-GuardEntry
        $entry.path = 'bin\dropo-wfp-guard.exe'
        Set-TestManifest -Files @($entry)
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'manifest traversal path alongside guard' {
        Set-TestManifest -Files @((New-GuardEntry), [ordered]@{ path = 'bin/../other.exe'; size = 1; sha256 = '0' * 64 })
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'case-folded duplicate guard path' {
        $alias = New-GuardEntry
        $alias.path = 'BIN/DROPO-WFP-GUARD.EXE'
        Set-TestManifest -Files @((New-GuardEntry), $alias)
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'malformed manifest SHA-256' {
        $entry = New-GuardEntry
        $entry.sha256 = 'bad'
        Set-TestManifest -Files @($entry)
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'manifest size mismatch' {
        $entry = New-GuardEntry
        $entry.size++
        Set-TestManifest -Files @($entry)
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'guard modified after manifest' {
        [IO.File]::WriteAllBytes($guard, [byte[]](4, 5, 7))
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'unsigned guard' {
        $script:guardStatus = [System.Management.Automation.SignatureStatus]::NotSigned
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'untrusted guard signature' {
        $script:guardStatus = [System.Management.Automation.SignatureStatus]::NotTrusted
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'unsigned core' {
        $script:coreStatus = [System.Management.Automation.SignatureStatus]::NotSigned
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'guard signed by another publisher' -ExpectedMessage 'same Authenticode signer' {
        $script:guardThumbprint = 'B' * 40
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }
    Reset-Fixture
    Assert-Fails 'signer does not match pinned certificate' {
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA -ExpectedSignerThumbprint ('B' * 40)
    }
    Reset-Fixture
    Assert-Fails 'self-signed release certificate' {
        $script:selfSigned = $true
        Assert-DropoWfpGuardRelease -RuntimeFolder $runtime -ExpectedManifestSHA256 $manifestSHA
    }

    Reset-Fixture
    Remove-Item -LiteralPath $guard
    Assert-Passes 'opt-in guard staging with pinned signed source' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 $guardSHA -BinFolder $bin
        if ((Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash -ine $guardSHA) {
            throw 'Staged guard hash did not match the pinned source.'
        }
    }
    Reset-Fixture
    Assert-Fails 'stale staged guard cannot be overwritten' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 $guardSHA -BinFolder $bin
    } 'stale or previously staged'
    Reset-Fixture
    Remove-Item -LiteralPath $guard
    Assert-Fails 'guard staging requires an independently pinned hash' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 'bad' -BinFolder $bin
    } 'independently pinned'
    Reset-Fixture
    Remove-Item -LiteralPath $guard
    Assert-Fails 'guard staging rejects hash mismatch' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 ('B' * 64) -BinFolder $bin
    } 'pinned SHA-256'
    Reset-Fixture
    Remove-Item -LiteralPath $guard
    $script:guardStatus = [System.Management.Automation.SignatureStatus]::NotSigned
    Assert-Fails 'guard staging rejects unsigned input' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 $guardSHA -BinFolder $bin
    } 'Windows-trusted'
    Reset-Fixture
    Remove-Item -LiteralPath $guard
    $script:selfSigned = $true
    Assert-Fails 'guard staging rejects self-signed input' {
        Copy-VerifiedDropoWfpGuard -BinaryPath $sourceGuard -ExpectedSHA256 $guardSHA -BinFolder $bin
    } 'Windows-trusted'
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedRoot)).StartsWith('dropo-wfp-guard-preflight-', [StringComparison]::Ordinal)) {
        throw "Refusing to remove unexpected test directory: $resolvedRoot"
    }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}

Write-Host "WFP guard release preflight fixtures passed ($caseCount cases)."
