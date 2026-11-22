$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-release-readiness.ps1') -FunctionsOnly
$testRepo = 'owner/project'
$testSha = 'a' * 40
function New-Run([string]$Path, [long]$Id, [string]$Conclusion = 'success') {
    $event = if ($Path -eq '.github/workflows/windows-release-gate.yml') { 'workflow_dispatch' } else { 'push' }
    [pscustomobject]@{ path = $Path; id = $Id; run_attempt = 1; head_sha = $testSha;
        head_branch = 'main'; head_repository = @{ full_name = $testRepo };
        event = $event; status = 'completed'; conclusion = $Conclusion }
}
function Assert-Ready([object[]]$Runs, [bool]$Expected, [string]$Case) {
    $result = Get-ReleaseReadiness -Runs $Runs -Repository $testRepo -Sha $testSha -Branch 'main'
    if ($result.Ready -ne $Expected) { throw "Release gate fixture failed: $Case" }
    if ($Expected -and $result.PackageRunId -ne '20') { throw 'Wrong package artifact run selected' }
}
$ci = New-Run '.github/workflows/ci.yml' 10
$package = New-Run '.github/workflows/windows-release-gate.yml' 20
Assert-Ready @($ci, $package) $true 'both successful'
Assert-Ready @($package) $false 'missing CI'
Assert-Ready @($ci) $false 'missing package gate'
Assert-Ready @() $false 'no runs'
foreach ($conclusion in @('failure', 'cancelled', 'skipped', 'timed_out', 'action_required', '')) {
    Assert-Ready @((New-Run $ci.path 10 $conclusion), $package) $false "CI $conclusion"
    Assert-Ready @($ci, (New-Run $package.path 20 $conclusion)) $false "package $conclusion"
}
Assert-Ready @($ci, $package, (New-Run $ci.path 11 'failure')) $false 'newer failure beats old success'
$pending = New-Run $ci.path 11
$pending.status = 'in_progress'
Assert-Ready @($ci, $package, $pending) $false 'pending run beats old success'
$rerun = New-Run $ci.path 10 'failure'
$rerun.run_attempt = 2
Assert-Ready @($ci, $package, $rerun) $false 'failed rerun beats earlier attempt'
foreach ($field in @('head_sha', 'head_branch', 'event', 'path')) {
    $wrong = New-Run $ci.path 10
    $wrong.$field = 'wrong'
    Assert-Ready @($wrong, $package) $false "wrong $field"
}
$fork = New-Run $ci.path 10
$fork.head_repository.full_name = 'someone/fork'
Assert-Ready @($fork, $package) $false 'fork cannot satisfy release gate'
foreach ($ineligibleEvent in @('push', 'pull_request')) {
    $unrequestedPackage = New-Run $package.path 20
    $unrequestedPackage.event = $ineligibleEvent
    Assert-Ready @($ci, $unrequestedPackage) $false "package from $ineligibleEvent cannot publish"
}
$dispatchedCI = New-Run $ci.path 11
$dispatchedCI.event = 'workflow_dispatch'
Assert-Ready @($dispatchedCI, $package) $true 'main CI may be dispatched'
$package | Add-Member -NotePropertyName display_title -NotePropertyValue 'Prepare Dropo release'
$eventArgs = @{ Repository = $testRepo; Sha = $testSha; Branch = 'main'; ExpectedRunId = '20'; ExpectedAttempt = '1' }
if (-not (Get-ReleaseReadiness @eventArgs -Runs @($ci, $package)).Ready) { throw 'Release event must accept its exact package attempt' }
foreach ($field in 'id', 'run_attempt', 'display_title') {
    $other = $package.psobject.Copy()
    $other.$field = if ($field -eq 'display_title') { 'Validate Windows packages' } else { 22 }
    if ((Get-ReleaseReadiness @eventArgs -Runs @($ci, $other)).Ready) { throw "Unexpected package passed release gate: $field" }
}
Write-Host 'Release readiness fixtures passed.'
& (Join-Path $PSScriptRoot 'test-existing-release.ps1')
