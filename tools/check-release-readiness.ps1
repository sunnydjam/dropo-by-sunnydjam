param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Sha = "",
    [string]$Branch = "Dzhamuha-develop",
    [switch]$FunctionsOnly
)

$ErrorActionPreference = "Stop"

# Pure decision function, also exercised by offline fixture tests. Never use a
# successful older run to override a newer failed/pending run for the same SHA.
function Get-ReleaseReadiness {
    param([object[]]$Runs, [string]$Repository, [string]$Sha, [string]$Branch)
    $packageRun = $null
    foreach ($path in @('.github/workflows/ci.yml', '.github/workflows/windows-release-gate.yml')) {
        $latest = @($Runs | Where-Object {
            $_.path -eq $path -and $_.head_sha -ceq $Sha -and
            $_.head_branch -ceq $Branch -and
            $_.head_repository.full_name -ceq $Repository -and
            $_.event -in @('push', 'workflow_dispatch')
        } | Sort-Object @{ Expression = { [long]$_.id }; Descending = $true },
            @{ Expression = { [int]$_.run_attempt }; Descending = $true } | Select-Object -First 1)
        if ($latest.Count -ne 1 -or $latest[0].status -ne 'completed' -or
            $latest[0].conclusion -ne 'success') {
            return [pscustomobject]@{ Ready = $false; PackageRunId = ''; Reason = "$path has no latest successful completed run for $Sha" }
        }
        if ($path -eq '.github/workflows/windows-release-gate.yml') { $packageRun = $latest[0] }
    }
    return [pscustomobject]@{ Ready = $true; PackageRunId = [string]$packageRun.id; Reason = 'CI and Windows package gate passed for the exact release commit' }
}

if ($FunctionsOnly) { return }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Sha -notmatch '^[0-9a-f]{40}$') {
    throw 'An explicit repository and full commit SHA are required.'
}
$runs = @()
foreach ($workflow in @('ci.yml', 'windows-release-gate.yml')) {
    $endpoint = "repos/$Repository/actions/workflows/$workflow/runs?head_sha=$Sha&per_page=100"
    $response = & gh api $endpoint --paginate --slurp
    if ($LASTEXITCODE -ne 0) { throw "Cannot verify required workflow $workflow" }
    foreach ($page in ($response | ConvertFrom-Json)) { $runs += @($page.workflow_runs) }
}
$result = Get-ReleaseReadiness -Runs $runs -Repository $Repository -Sha $Sha -Branch $Branch
Write-Host $result.Reason
if ($env:GITHUB_OUTPUT) {
    "ready=$($result.Ready.ToString().ToLowerInvariant())" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "package_run_id=$($result.PackageRunId)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
} elseif (-not $result.Ready) {
    throw $result.Reason
}
