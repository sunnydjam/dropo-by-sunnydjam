# Runs from any working directory with a Go SDK on PATH.
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../../bootstrap'
& go -C $module test ./...
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& go -C $module vet ./...
exit $LASTEXITCODE
