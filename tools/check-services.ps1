# Route-aware compatibility entry point for the current Windows selective
# architecture. The detailed implementation lives in client-quick-check.ps1 so
# support checks and the in-app contract cannot drift into separate TUN-era
# assumptions again.

param(
    [switch]$Verbose,
    [switch]$Json,
    [int]$Timeout = 10,
    [switch]$Phase1Only,
    [switch]$Phase2Only,
    [switch]$SkipIPCheck,
    [switch]$AllCatalog,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Phase1Only -and $Phase2Only) {
    Write-Error "Phase1Only and Phase2Only cannot be used together."
    exit 2
}

$quickCheck = Join-Path $PSScriptRoot "client-quick-check.ps1"
if (-not (Test-Path $quickCheck -PathType Leaf)) {
    Write-Error "Route-aware diagnostic script not found: $quickCheck"
    exit 2
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $OutDir) {
    $OutDir = Join-Path ([Environment]::GetFolderPath("Desktop")) "dropo-service-check-$stamp"
}
$invokeArgs = @{
    Timeout = $Timeout
    MethodTimeout = $Timeout
    OutDir = $OutDir
    AllCatalog = $AllCatalog
    DirectOnly = $Phase1Only
    SelectedOnly = $Phase2Only
}

if ($Verbose) {
    Write-Host "Using route-aware proxy-only diagnostics." -ForegroundColor DarkGray
}
if (-not $SkipIPCheck) {
    Write-Host "Route identity is verified through the active mixed proxy and explicit direct probes." -ForegroundColor DarkGray
}

& $quickCheck @invokeArgs
$exitCode = $LASTEXITCODE

if ($Json) {
    $summaryPath = Join-Path $OutDir "summary.json"
    if (Test-Path $summaryPath -PathType Leaf) {
        Get-Content $summaryPath -Raw
    }
}
exit $exitCode
