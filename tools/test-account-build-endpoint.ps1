$ErrorActionPreference = 'Stop'
$buildScript = Join-Path $PSScriptRoot '../scripts/build/build.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $buildScript).Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Build script PowerShell parsing failed.' }

# Import only the pure helpers, never the build script's SDK/download/package
# entry point. Fixtures do not read process environment, credentials or DNS.
$helperNames = @('Test-DropoPublicAccountHost', 'Resolve-DropoAccountEndpoint', 'Get-DropoAccountBuildArguments')
$definitions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $helperNames
}, $true))
if ($definitions.Count -ne $helperNames.Count) { throw 'Expected build endpoint helpers not found.' }
foreach ($definition in $definitions) { . ([ScriptBlock]::Create($definition.Extent.Text)) }

function Assert-Endpoint([string]$Value, [string]$Expected, [string]$EnvironmentValue = '') {
    $actual = Resolve-DropoAccountEndpoint -Endpoint $Value -EnvironmentEndpoint $EnvironmentValue
    if ($actual -cne $Expected) { throw "Endpoint normalization fixture failed: expected '$Expected', got '$actual'." }
}
function Assert-Rejected([string]$Value, [string]$EnvironmentValue = '', [switch]$Reuse) {
    $rejected = $false
    try { $null = Resolve-DropoAccountEndpoint -Endpoint $Value -EnvironmentEndpoint $EnvironmentValue -ReuseWindowsOutput:$Reuse }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe or stale endpoint fixture accepted.' }
}

Assert-Endpoint '' ''
Assert-Endpoint '  ' ''
Assert-Endpoint 'https://accounts.example.com' 'https://accounts.example.com'
Assert-Endpoint ' HTTPS://ACCOUNTS.EXAMPLE.COM/ ' 'https://accounts.example.com'
Assert-Endpoint 'https://accounts.example.com:8443/' 'https://accounts.example.com:8443'
Assert-Endpoint 'https://8.8.8.8' 'https://8.8.8.8'
Assert-Endpoint 'https://[2001:4860:4860::8888]:8443/' 'https://[2001:4860:4860::8888]:8443'
Assert-Endpoint '' 'https://ci.example.com' 'https://ci.example.com/'
Assert-Endpoint 'https://explicit.example.com' 'https://explicit.example.com' 'http://unsafe.example.com'
foreach ($value in @(
    'http://accounts.example.com', 'https://user:secret@accounts.example.com', 'https://@accounts.example.com',
    'https://accounts.example.com?token=fixture', 'https://accounts.example.com#fragment', 'https://accounts.example.com/v1',
    'https://accounts.example.com//', 'https://accounts.example.com\', 'https://accounts.example.com:0', 'https://accounts.example.com:99999',
    'https://localhost', 'https://LOCALHOST.', 'https://vpn.local', 'https://vpn.localdomain', 'https://vpn.internal', 'https://vpn.lan', 'https://vpn.home.arpa', 'https://server',
    'https://127.0.0.1', 'https://127.1', 'https://2130706433', 'https://10.0.0.1', 'https://172.16.0.1', 'https://192.168.1.1',
    'https://100.64.0.1', 'https://169.254.1.1', 'https://0.1.2.3', 'https://224.0.0.1',
    'https://[::]', 'https://[::1]', 'https://[fd00::1]', 'https://[fe80::1]', 'https://[fec0::1]', 'https://[ff02::1]', 'https://[::ffff:192.168.1.1]',
    'https://bad..example.com', 'https://-bad.example.com'
)) { Assert-Rejected $value }
Assert-Rejected '' 'http://ci.example.com'
Assert-Rejected 'https://accounts.example.com' -Reuse
Assert-Rejected '' 'https://ci.example.com' -Reuse
if ((Resolve-DropoAccountEndpoint -ReuseWindowsOutput) -ne '') { throw 'Unconfigured legacy reuse behavior changed.' }

$configuredArgs = @(Get-DropoAccountBuildArguments 'https://accounts.example.com')
if ($configuredArgs.Count -ne 2 -or $configuredArgs[0] -ne '--dart-define' -or
    $configuredArgs[1] -ne 'DROPO_ACCOUNT_ENDPOINT=https://accounts.example.com') {
    throw 'Endpoint Dart define is not passed as a single value.'
}
if (@(Get-DropoAccountBuildArguments '').Count -ne 0) { throw 'Unconfigured build should not add a Dart define.' }
if (@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AccountEndpoint' }).Count -ne 1) {
    throw 'AccountEndpoint build parameter missing.'
}
$argumentCalls = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-DropoAccountBuildArguments'
}, $true))
if ($argumentCalls.Count -ne 2) { throw 'Windows and Android must both receive the endpoint Dart define.' }
Write-Host 'Account build endpoint fixtures passed (HTTPS origin, environment precedence, both platforms and fail-closed reuse).'
