# Verifies the active Dropo routing contract without assuming that the selected
# services use a global TUN. Windows selective sessions use the generated deep
# proxy-only config, a local mixed proxy and the in-process traffic engine.

param([int]$Timeout = 5)

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Find-FirstFile([string[]]$Candidates) {
    foreach ($path in $Candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path $path -PathType Leaf) { return $path }
    }
    return ""
}

function Test-LoopbackPort([int]$Port) {
    if ($Port -le 0) { return $false }
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $pending = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $ready = $pending.AsyncWaitHandle.WaitOne([Math]::Max(250, $Timeout * 1000), $false)
        if ($ready) { $client.EndConnect($pending) }
        $client.Dispose()
        return $ready
    } catch { return $false }
}

$resources = Join-Path $env:LOCALAPPDATA "dropo\resources"
$configPath = Find-FirstFile @(
    (Join-Path $resources "deep_windows_proxy_config.json"),
    (Join-Path (Get-Location) "resources\deep_windows_proxy_config.json"),
    (Join-Path $resources "active_config.json"),
    (Join-Path (Get-Location) "resources\active_config.json")
)
$settingsPath = Find-FirstFile @(
    (Join-Path $resources "settings.json"),
    (Join-Path (Get-Location) "resources\settings.json")
)

Write-Host ""
Write-Host "dropo route contract check" -ForegroundColor Cyan
Write-Host ""

if (-not $configPath) {
    Write-Host "[FAIL] No active routing config found. Start Dropo first." -ForegroundColor Red
    exit 1
}

try { $config = Get-Content $configPath -Raw | ConvertFrom-Json } catch {
    Write-Host "[FAIL] Invalid config: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$appSettings = $null
if ($settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $appSettings = if ($settings.app) { $settings.app } else { $settings }
    } catch {}
}

$mixed = @($config.inbounds | Where-Object type -eq "mixed" | Select-Object -First 1)
$tun = @($config.inbounds | Where-Object type -eq "tun")
$mode = if ($mixed.Count -gt 0 -and $tun.Count -eq 0) { "proxy-only selective" } elseif ($tun.Count -gt 0) { "TUN" } else { "unknown" }
$mixedPort = if ($mixed.Count -gt 0) { [int]$mixed[0].listen_port } else { 0 }
$mixedReady = Test-LoopbackPort $mixedPort
$mixedPin = @($config.route.rules | Where-Object {
    @($_.inbound) -contains "mixed-in" -and $_.outbound -eq "auto-select"
})
$gameDomainRule = @($config.route.rules | Where-Object {
    $_.outbound -eq "direct" -and (@($_.domain_suffix) -contains "steampowered.com") -and (@($_.domain_suffix) -contains "steamcommunity.com")
})
$gameProcessRule = @($config.route.rules | Where-Object {
    $_.outbound -eq "direct" -and (@($_.process_name) -contains "steam.exe") -and (@($_.process_name) -contains "MistfallHunter-Win64-Shipping.exe")
})

$failures = [System.Collections.Generic.List[string]]::new()
if ($mode -eq "unknown") { $failures.Add("No mixed or TUN inbound") }
if ($mode -eq "proxy-only selective" -and $config.route.final -ne "direct") { $failures.Add("Selective route.final is not direct") }
if ($mode -eq "proxy-only selective" -and $mixedPin.Count -eq 0) { $failures.Add("Mixed inbound is not pinned to auto-select") }
if ($mode -eq "proxy-only selective" -and -not $mixedReady) { $failures.Add("Mixed proxy port $mixedPort is not listening") }
if ($gameDomainRule.Count -eq 0) { $failures.Add("Steam direct-domain guard is missing") }
if ($gameProcessRule.Count -eq 0) { $failures.Add("Steam/Mistfall direct-process guard is missing") }

Write-Host "Config:       $configPath"
Write-Host "Mode:         $mode"
Write-Host "Final route:  $($config.route.final)"
if ($mixedPort -gt 0) { Write-Host "Mixed proxy:  127.0.0.1:$mixedPort (ready=$mixedReady)" }
Write-Host "Steam guard:  domains=$($gameDomainRule.Count -gt 0), processes=$($gameProcessRule.Count -gt 0)"
Write-Host ""

if ($appSettings -and $appSettings.free_access_methods) {
    Write-Host "Configured service routes" -ForegroundColor Cyan
    $rows = foreach ($property in $appSettings.free_access_methods.PSObject.Properties) {
        $method = ([string]$property.Value).Trim().ToLowerInvariant()
        if ($method -eq "direct") { continue }
        $group = $config.outbounds | Where-Object tag -eq ("bypass-" + $property.Name) | Select-Object -First 1
        [PSCustomObject]@{
            Service = $property.Name
            Method = $method
            Group = if ($group) { $group.tag } else { "native/direct" }
            Active = if ($group) { $group.default } else { $method }
        }
        if ($method -eq "vpn" -and (-not $group -or $group.default -ne "auto-select")) {
            $failures.Add("VPN service $($property.Name) is not pinned to auto-select")
        }
    }
    $rows | Sort-Object Service | Format-Table -AutoSize
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "[OK] Active routing contract is consistent." -ForegroundColor Green
    exit 0
}

foreach ($failure in $failures) { Write-Host "[FAIL] $failure" -ForegroundColor Red }
exit 1
