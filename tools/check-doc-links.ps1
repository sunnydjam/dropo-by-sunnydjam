#requires -Version 7.3
$ErrorActionPreference = 'Stop'
$root = (Get-Item (Join-Path $PSScriptRoot '..')).FullName
# Use tracked names so case errors and links to uncommitted files also fail on Windows.
$paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$files = @(git -C $root -c core.quotepath=false ls-files)
if ($LASTEXITCODE -ne 0) { throw 'Could not list repository files' }
[void]$paths.Add('.')
foreach ($file in $files) {
    $path = $file
    while ($paths.Add($path) -and $path.Contains('/')) {
        $path = $path.Substring(0, $path.LastIndexOf('/'))
    }
}
$broken = @(
    foreach ($file in $files.Where({ $_ -like '*.md' })) {
        $source = Join-Path $root $file
        $document = (ConvertFrom-Markdown -LiteralPath $source).Tokens
        $links = [Markdig.Syntax.MarkdownObjectExtensions]::Descendants[Markdig.Syntax.Inlines.LinkInline]($document)
        foreach ($link in $links) {
            $url = $link.Url
            if (-not $url -or $url -match '^(?:[a-z][a-z0-9+.-]*:|//)') { continue }
            $target = [Uri]::UnescapeDataString(($url -split '[?#]', 2)[0])
            if (-not $target) { continue }
            $base = Split-Path -LiteralPath $source
            if ($target.StartsWith('/')) { $base = $root; $target = $target.TrimStart('/') }
            $absolute = [IO.Path]::GetFullPath((Join-Path $base $target)).TrimEnd([IO.Path]::DirectorySeparatorChar)
            $relative = [IO.Path]::GetRelativePath($root, $absolute).Replace('\','/')
            if (-not $paths.Contains($relative)) { '{0}:{1} -> {2}' -f $file, ($link.Line + 1), $url }
        }
    }
)
if ($broken.Count) { throw ("Unresolved documentation links:`n" + ($broken -join "`n")) }
Write-Host 'Tracked Markdown file links resolve.'
