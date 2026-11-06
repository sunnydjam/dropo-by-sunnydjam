# Real filesystem publication/lock fixture; no application or VPN is started.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'export-runtime-source.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'Source exporter syntax failed.' }
$functions = @($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Publish-CompletedSourceArchive'
}, $false))
if ($functions.Count -ne 1) { throw 'Expected exactly one archive publication function.' }
. ([ScriptBlock]::Create($functions[0].Extent.Text))
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$fixture = Join-Path $parent ('dropo-source-publication-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $fixture) { throw 'Existing fixture retained.' }
New-Item -ItemType Directory -Path $fixture | Out-Null
$locked = $null
try {
    $temporary = Join-Path $fixture 'candidate.tmp'
    $final = Join-Path $fixture 'sources.zip'
    [IO.File]::WriteAllText($temporary, 'complete first archive')
    Publish-CompletedSourceArchive $temporary $final
    if ([IO.File]::Exists($temporary) -or [IO.File]::ReadAllText($final) -cne 'complete first archive') {
        throw 'First publication lost the completed archive.'
    }
    [IO.File]::WriteAllText($temporary, 'complete replacement archive')
    $locked = [IO.File]::Open($final, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $rejected = $false
    try { Publish-CompletedSourceArchive $temporary $final } catch { $rejected = $true }
    $locked.Dispose(); $locked = $null
    if (-not $rejected -or -not [IO.File]::Exists($temporary) -or
        [IO.File]::ReadAllText($final) -cne 'complete first archive') {
        throw 'Locked destination did not preserve both completed archives.'
    }
    Publish-CompletedSourceArchive $temporary $final
    if ([IO.File]::Exists($temporary) -or [IO.File]::ReadAllText($final) -cne 'complete replacement archive') {
        throw 'Atomic replacement failed after releasing the lock.'
    }
    Write-Host "Source publication passed (PowerShell $($PSVersionTable.PSVersion)): new, locked, replacement."
} finally {
    if ($locked) { $locked.Dispose() }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ((Split-Path $resolved -Parent).TrimEnd('\','/') -cne $parent -or
        (Split-Path $resolved -Leaf) -notmatch '^dropo-source-publication-[a-f0-9]{32}$' -or
        ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count) { throw 'Unsafe publication fixture cleanup; retained.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
