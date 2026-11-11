# Publisher-only probe: a tag 404 plus a complete authenticated draft-aware list
# is required before a release may be considered absent.
# Requires PowerShell 7, as used by the publishing workflow's pwsh shell.
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Tag = '',
    [switch]$FunctionsOnly
)
$ErrorActionPreference = 'Stop'

function Test-GitHubReleaseExists {
    param([string]$Repository, [string]$Tag)
    if ($Repository -notmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
        $Tag -cnotmatch '\Av[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[1-9][0-9]*)?\z') {
        throw 'An explicit repository and release version tag are required.'
    }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw 'Authenticated release lookup is required, including private drafts.'
    }
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $env:GH_TOKEN"
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'dropo-release-publication-guard'
    }
    $request = {
        param([string]$Uri)
        try {
            Invoke-WebRequest -Method Get -Uri $Uri -Headers $headers `
                -TimeoutSec 30 -MaximumRedirection 0 -SkipHttpErrorCheck
        } catch {
            # Transport errors and their text must never mean absence. Do not
            # echo response/exception details that could contain credentials.
            throw 'Cannot verify existing GitHub release; publication stopped.'
        }
    }
    $validRecord = {
        param($Release)
        $Release -isnot [array] -and $Release -is [pscustomobject] -and
            ($Release.id -is [long] -or $Release.id -is [int]) -and
            $Release.id -gt 0 -and $Release.tag_name -is [string] -and
            $Release.draft -is [bool]
    }
    $response = & $request "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    if ([int]$response.StatusCode -notin @(200, 404)) {
        throw 'GitHub release lookup did not return 200 or 404; publication stopped.'
    }
    if ([int]$response.StatusCode -eq 200) {
        try { $release = ConvertFrom-Json -InputObject $response.Content -Depth 32 -NoEnumerate } catch {
            throw 'GitHub release lookup returned invalid JSON; publication stopped.'
        }
        if (-not (& $validRecord $release) -or $release.tag_name -cne $Tag) {
            throw 'GitHub release lookup returned an unexpected release; publication stopped.'
        }
        return $true
    }
    # GitHub's tag endpoint can return 404 for a draft that already exists.
    # This publisher has contents:write; its authenticated list includes drafts.
    # Construct pagination URLs ourselves; never follow a response-supplied URL.
    for ($page = 1; $page -le 10; $page++) {
        $response = & $request "https://api.github.com/repos/$Repository/releases?per_page=100&page=$page"
        if ([int]$response.StatusCode -ne 200) {
            throw 'Cannot verify the complete GitHub release list; publication stopped.'
        }
        try { $releases = ConvertFrom-Json -InputObject $response.Content -Depth 32 -NoEnumerate } catch {
            throw 'GitHub release list returned invalid JSON; publication stopped.'
        }
        if ($releases -isnot [array] -or $releases.Count -gt 100) {
            throw 'GitHub release list returned an unexpected page; publication stopped.'
        }
        foreach ($release in $releases) {
            if (-not (& $validRecord $release)) {
                throw 'GitHub release list returned an unexpected release; publication stopped.'
            }
            # Drafts and published releases are equally immutable.
            if ($release.tag_name -ceq $Tag) { return $true }
        }
        $hasNext = [string]$response.Headers.Link -match 'rel="?next"?'
        if ($releases.Count -lt 100 -and -not $hasNext) { return $false }
    }
    throw 'GitHub release list exceeds the verified page limit; publication stopped.'
}

if ($FunctionsOnly) { return }
$exists = Test-GitHubReleaseExists -Repository $Repository -Tag $Tag
if ($exists) { Write-Host "Release $Tag already exists; leaving it immutable." }
if ($env:GITHUB_OUTPUT) {
    "exists=$($exists.ToString().ToLowerInvariant())" | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
} else {
    Write-Output $exists
}
