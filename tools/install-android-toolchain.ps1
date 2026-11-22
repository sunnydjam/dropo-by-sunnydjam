param(
    [string]$InstallRoot = "D:\CodexTools\DropoAndroid"
)

$ErrorActionPreference = "Stop"
$installPath = [IO.Path]::GetFullPath($InstallRoot)
if (-not [IO.Path]::IsPathRooted($InstallRoot) -or
    $installPath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($installPath).TrimEnd('\')) {
    throw "Use an absolute, dedicated Android toolchain directory."
}
New-Item -ItemType Directory -Force -Path $installPath | Out-Null
$downloadPath = Join-Path $installPath "downloads"
$sdkPath = Join-Path $installPath "sdk"
$javaPath = Join-Path $installPath "java"
New-Item -ItemType Directory -Force -Path $downloadPath, $sdkPath, $javaPath | Out-Null

function Get-VerifiedArchive {
    param([string]$Url, [string]$Path, [string]$ExpectedHash, [string]$Algorithm)
    if ((Test-Path -LiteralPath $Path) -and
        (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant() -eq $ExpectedHash.ToLowerInvariant()) {
        return
    }
    Write-Host "Downloading $([IO.Path]::GetFileName($Path))"
    Invoke-WebRequest -Uri $Url -OutFile $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant() -ne $ExpectedHash.ToLowerInvariant()) {
        throw "Archive checksum mismatch: $Path"
    }
}

# Both archive URLs and expected hashes come from the publishers' APIs.
[xml]$catalog = (Invoke-WebRequest -Uri "https://dl.google.com/android/repository/repository2-3.xml").Content
$cliPackage = $catalog.SelectNodes("//*[local-name()='remotePackage']") |
    Where-Object { $_.path -eq "cmdline-tools;latest" }
$cliArchive = $cliPackage.archives.archive | Where-Object { $_.'host-os' -eq "windows" }
if (-not $cliArchive) { throw "Android catalog has no Windows command-line tools." }
$cliZip = Join-Path $downloadPath $cliArchive.complete.url
$hashAlgorithm = switch ($cliArchive.complete.checksum.type) {
    "sha1" { "SHA1" }
    "sha256" { "SHA256" }
    default { throw "Unknown publisher checksum algorithm." }
}
Get-VerifiedArchive -Url ("https://dl.google.com/android/repository/" + $cliArchive.complete.url) `
    -Path $cliZip -ExpectedHash $cliArchive.complete.checksum.'#text' -Algorithm $hashAlgorithm
$cliLatest = Join-Path $sdkPath "cmdline-tools\latest"
if (-not (Test-Path -LiteralPath (Join-Path $cliLatest "bin\sdkmanager.bat"))) {
    $extractPath = Join-Path $downloadPath ([IO.Path]::GetFileNameWithoutExtension($cliZip))
    Expand-Archive -LiteralPath $cliZip -DestinationPath $extractPath -Force
    $extractedTools = [IO.Path]::GetFullPath((Join-Path $extractPath "cmdline-tools"))
    if (-not $extractedTools.StartsWith($installPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected extraction path."
    }
    if (Test-Path -LiteralPath $cliLatest) { throw "Incomplete tools at $cliLatest; inspect them before replacing." }
    New-Item -ItemType Directory -Force -Path (Split-Path $cliLatest) | Out-Null
    Move-Item -LiteralPath $extractedTools -Destination $cliLatest
}

$jdkAssets = Invoke-RestMethod -Uri "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
$jdkPackage = $jdkAssets[0].binary.package
if (-not $jdkPackage.link -or -not $jdkPackage.checksum) { throw "Adoptium returned no JDK archive." }
$jdkZip = Join-Path $downloadPath $jdkPackage.name
Get-VerifiedArchive -Url $jdkPackage.link -Path $jdkZip -ExpectedHash $jdkPackage.checksum -Algorithm SHA256
$jdkVersion = $jdkAssets[0].version.openjdk_version -replace '\+', '-'
$jdkExtractPath = Join-Path $javaPath $jdkVersion
if (-not (Test-Path -LiteralPath $jdkExtractPath)) {
    Expand-Archive -LiteralPath $jdkZip -DestinationPath $jdkExtractPath
}
$jdkDirectory = Get-ChildItem -LiteralPath $jdkExtractPath -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "bin\java.exe") } |
    Select-Object -First 1
if (-not $jdkDirectory) { throw "Extracted JDK has no java.exe." }
$env:JAVA_HOME = $jdkDirectory.FullName
$env:ANDROID_HOME = $sdkPath
$env:ANDROID_SDK_ROOT = $sdkPath
$env:GRADLE_USER_HOME = Join-Path $installPath "gradle-cache"
$env:Path = "$env:JAVA_HOME\bin;$sdkPath\platform-tools;$env:Path"
$androidCli = Join-Path $cliLatest "bin\android.exe"
$sdkManager = Join-Path $cliLatest "bin\sdkmanager.bat"
Write-Host "Installing platform tools, Android 36, build tools and NDK."
if (Test-Path -LiteralPath $androidCli) {
    & $androidCli --no-metrics "--sdk=$sdkPath" sdk install "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
} else {
    Write-Host "Accepting SDK licenses for the requested Android installation."
    1..100 | ForEach-Object { "y" } | & $sdkManager "--sdk_root=$sdkPath" --licenses | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SDK license setup failed." }
    & $sdkManager "--sdk_root=$sdkPath" "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
}
if ($LASTEXITCODE -ne 0) { throw "Android SDK installation failed." }
foreach ($requiredFile in @("platform-tools\adb.exe", "platforms\android-36\android.jar", "build-tools\36.0.0\apksigner.bat", "ndk\28.2.13676358\source.properties")) {
    if (-not (Test-Path -LiteralPath (Join-Path $sdkPath $requiredFile))) { throw "Android package installation incomplete: $requiredFile" }
}
[Environment]::SetEnvironmentVariable("DROPO_ANDROID_TOOLCHAIN_ROOT", $installPath, "User")
$env:DROPO_ANDROID_TOOLCHAIN_ROOT = $installPath
$repositoryRoot = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot "dev-environment.ps1")
Add-DropoGoSdkToPath -ToolchainRoot (Get-DropoToolchainRoot -RepositoryRoot $repositoryRoot)
if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw "Dropo's Go toolchain is required to install the Android bridge tools." }
$mobileModule = Get-Content -LiteralPath (Join-Path $repositoryRoot "app\mobile\dropoandroid\go.mod") -Raw
$mobileVersionMatch = [regex]::Match($mobileModule, '(?m)^\s*golang\.org/x/mobile\s+(v\S+)')
if (-not $mobileVersionMatch.Success) { throw "Android module has no pinned golang.org/x/mobile version." }
$originalGoBin = $env:GOBIN
$originalGoCache = $env:GOCACHE
try {
    $env:GOBIN = Join-Path $installPath "bin"
    $env:GOCACHE = Join-Path $installPath "go-build-cache"
    $mobileVersion = $mobileVersionMatch.Groups[1].Value
    foreach ($tool in @("gomobile", "gobind")) {
        Write-Host "Installing $tool ($mobileVersion)"
        & go install "golang.org/x/mobile/cmd/$tool@$mobileVersion"
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $tool." }
    }
} finally {
    $env:GOBIN = $originalGoBin
    $env:GOCACHE = $originalGoCache
}
Write-Host "Android tools ready at $installPath"
& "$env:JAVA_HOME\bin\java.exe" -version
& "$sdkPath\platform-tools\adb.exe" version
