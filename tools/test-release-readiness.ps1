$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-release-readiness.ps1') -FunctionsOnly
$testRepo = 'owner/project'
$testSha = 'a' * 40
function New-Run([string]$Path, [long]$Id, [string]$Conclusion = 'success') {
    [pscustomobject]@{ path = $Path; id = $Id; run_attempt = 1; head_sha = $testSha;
        head_branch = 'Dzhamuha-develop'; head_repository = @{ full_name = $testRepo };
        event = 'push'; status = 'completed'; conclusion = $Conclusion }
}
function Assert-Ready([object[]]$Runs, [bool]$Expected, [string]$Case) {
    $result = Get-ReleaseReadiness -Runs $Runs -Repository $testRepo -Sha $testSha -Branch 'Dzhamuha-develop'
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
Write-Host 'Release readiness fixtures passed (24 cases).'
