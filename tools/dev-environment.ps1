# Shared local development-environment discovery for Dropo build scripts.
#
# Keep SDKs outside the repository and point DROPO_TOOLCHAIN_ROOT at their
# common parent. A repository-local .toolchain remains a compatibility fallback
# for CI and existing developer checkouts.

function Get-DropoToolchainRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $configuredRoot = [string]$env:DROPO_TOOLCHAIN_ROOT
    if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
        $expandedRoot = [Environment]::ExpandEnvironmentVariables($configuredRoot.Trim())
        if (-not [IO.Path]::IsPathRooted($expandedRoot)) {
            throw "DROPO_TOOLCHAIN_ROOT must be an absolute path: $expandedRoot"
        }
        return [IO.Path]::GetFullPath($expandedRoot)
    }

    return Join-Path $RepositoryRoot ".toolchain"
}

function Add-DropoGoSdkToPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolchainRoot
    )

    if (Get-Command go -ErrorAction SilentlyContinue) {
        return
    }

    $goBin = Join-Path $ToolchainRoot "go-1.25.13\go\bin"
    $goExe = Join-Path $goBin "go.exe"
    if (Test-Path -LiteralPath $goExe -PathType Leaf) {
        $env:Path = "$goBin;$env:Path"
    }
}
