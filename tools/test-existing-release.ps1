$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-existing-release.ps1') -FunctionsOnly
$script:releaseProbeCases = 0
$script:releaseProbeStatus = 200
$script:releaseProbeBody = '{"id":123,"tag_name":"v3.1.5","draft":true}'
$script:releaseProbeFailure = $false
$script:releaseProbePages = @([pscustomobject]@{StatusCode=200; Content='[]'; Headers=@{}})
$savedToken = $env:GH_TOKEN
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection, [switch]$SkipHttpErrorCheck)
    if ($Method -ne 'Get' -or
        $Headers.Authorization -cne 'Bearer synthetic-test-token' -or $TimeoutSec -ne 30 -or
        $MaximumRedirection -ne 0 -or -not $SkipHttpErrorCheck) {
        throw 'Release probe request contract changed.'
    }
    if ($script:releaseProbeFailure) { throw 'Synthetic transport error mentions HTTP 404; not an HTTP response.' }
    if ($Uri -ceq 'https://api.github.com/repos/owner/project/releases/tags/v3.1.5') {
        return [pscustomobject]@{StatusCode=$script:releaseProbeStatus; Content=$script:releaseProbeBody; Headers=@{}}
    }
    if ($Uri -cmatch '\Ahttps://api\.github\.com/repos/owner/project/releases\?per_page=100&page=([1-9][0-9]*)\z') {
        $index = [int]$Matches[1] - 1
        if ($index -lt $script:releaseProbePages.Count) { return $script:releaseProbePages[$index] }
    }
    throw 'Unexpected release probe destination or pagination.'
}
function Assert-ReleaseExists([bool]$Expected, [string]$Case) {
    $actual = Test-GitHubReleaseExists -Repository 'owner/project' -Tag 'v3.1.5'
    if ($actual -isnot [bool] -or $actual -ne $Expected) { throw "Release probe fixture failed: $Case" }
    $script:releaseProbeCases++
}
function Assert-ReleaseProbeRejected([scriptblock]$Action, [string]$Case) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Release lookup incorrectly permitted publication: $Case" }
    $script:releaseProbeCases++
}
try {
    $env:GH_TOKEN = 'synthetic-test-token'
    Assert-ReleaseExists $true 'existing draft stays immutable'
    $script:releaseProbeBody = '{"id":123,"tag_name":"v3.1.5","draft":false}'
    Assert-ReleaseExists $true 'existing published release stays immutable'
    $script:releaseProbeStatus = 404
    $script:releaseProbeBody = '{"message":"Not Found","status":"404"}'
    Assert-ReleaseExists $false 'tag 404 plus complete empty list permits creation'
    $draftPage = '[{"id":123,"tag_name":"v3.1.5","draft":true}]'
    $script:releaseProbePages = @([pscustomobject]@{StatusCode=200; Content=$draftPage; Headers=@{}})
    Assert-ReleaseExists $true 'tag 404 cannot hide an existing draft'
    $fullPage = '[' + ((1..100 | ForEach-Object { '{"id":' + $_ + ',"tag_name":"v0.0.' + $_ + '","draft":false}' }) -join ',') + ']'
    $script:releaseProbePages = @(
        [pscustomobject]@{StatusCode=200; Content=$fullPage; Headers=@{}},
        [pscustomobject]@{StatusCode=200; Content=$draftPage; Headers=@{}})
    Assert-ReleaseExists $true 'draft on later page remains immutable'
    $script:releaseProbePages[1].Content = '[]'
    Assert-ReleaseExists $false 'all pages checked before allowing creation'
    $script:releaseProbePages[0].Content = '[]'
    $script:releaseProbePages[0].Headers = @{Link='<https://untrusted.invalid/ignored>; rel="next"'}
    $script:releaseProbePages[1].Content = $draftPage
    Assert-ReleaseExists $true 'next page uses fixed GitHub URL rather than supplied Link URL'
    $script:releaseProbePages = @(1..10 | ForEach-Object { [pscustomobject]@{StatusCode=200; Content=$fullPage; Headers=@{}} })
    Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } 'unproven absence after pagination limit'
    foreach ($status in @(404, 401, 403, 429, 500, 503)) {
        $script:releaseProbePages = @([pscustomobject]@{StatusCode=$status; Content='[]'; Headers=@{}})
        Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } 'failed authenticated list'
    }
    foreach ($body in @('null', '{}', 'not json', '[{"id":123,"tag_name":"v3.1.5"}]')) {
        $script:releaseProbePages = @([pscustomobject]@{StatusCode=200; Content=$body; Headers=@{}})
        Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } 'malformed release list'
    }
    $script:releaseProbePages = @([pscustomobject]@{StatusCode=200; Content='[]'; Headers=@{}})
    foreach ($status in @(0, 204, 301, 302, 401, 403, 429, 500, 502, 503)) {
        $script:releaseProbeStatus = $status
        # A body claiming 404 must not override the actual response status.
        Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } "HTTP $status"
    }
    $script:releaseProbeStatus = 200
    foreach ($body in @('not json', 'null', '[]', '{}', '[{"id":123,"tag_name":"v3.1.5","draft":true}]',
        '{"id":123,"tag_name":"v3.1.4","draft":true}',
        '{"id":"123","tag_name":"v3.1.5","draft":true}',
        '{"id":0,"tag_name":"v3.1.5","draft":true}',
        '{"id":123,"tag_name":"v3.1.5","draft":"false"}')) {
        $script:releaseProbeBody = $body
        Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } "malformed successful response: $body"
    }
    $script:releaseProbeFailure = $true
    Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } 'transport failure mentioning 404'
    $script:releaseProbeFailure = $false
    $script:releaseProbeBody = '{"id":123,"tag_name":"v3.1.5","draft":true}'
    foreach ($tag in @('', "v3.1.5`nexists=false", "v3.1.5`n", 'v3.1.5/../other', 'V3.1.5', 'v3.1.5?name=other')) {
        Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' $tag } 'invalid or output-injecting tag'
    }
    Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project/../../other' 'v3.1.5' } 'invalid repository'
    $env:GH_TOKEN = ''
    Assert-ReleaseProbeRejected { Test-GitHubReleaseExists 'owner/project' 'v3.1.5' } 'anonymous lookup cannot see drafts'
} finally {
    $env:GH_TOKEN = $savedToken
    Remove-Item Function:\Invoke-WebRequest
}
Write-Host "Existing-release fixtures passed ($script:releaseProbeCases cases)."
