param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$SHA256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$isolation = Get-Content -LiteralPath 'C:\ProgramData\DropoLab\isolation.json' -Raw | ConvertFrom-Json
if ($env:COMPUTERNAME -ne 'DROPO-LAB' -or !$isolation.guestOnly -or $isolation.platform -ne 'hyper-v' -or
    (Split-Path -Parent $Root) -cne 'C:\DropoLab' -or (Split-Path -Leaf $Root) -notmatch '^independent-router-[a-f0-9]{32}$') {
    throw 'Run the fixture only in the isolated Dropo Hyper-V guest.'
}
if (Get-Process -Name 'dropo-core' -ErrorAction SilentlyContinue) {
    throw 'An existing Dropo core is active in the guest.'
}
$archive = Join-Path $Root 'portable.zip'
if ((Get-FileHash -LiteralPath $archive).Hash -ne $SHA256) { throw 'Portable archive SHA-256 mismatch.' }
$package = Join-Path $Root 'app'
Expand-Archive -LiteralPath $archive -DestinationPath $package
$exe = Get-ChildItem -LiteralPath $package -Filter dropo-core.exe -Recurse -File | Select-Object -First 1
if (!$exe) { throw 'Portable core missing.' }
$env:DROPO_DATA_DIR = Join-Path $Root 'data'
$tokenPath = Join-Path $env:DROPO_DATA_DIR 'bridge-token'
$bridge = 'http://127.0.0.1:32890'
$routerAlias = 'Dropo Protected Routing'
$script:token = $null
$core = $null
$fixtureVPN = $null
$fixtureHTTP = $null
$checks = [ordered]@{}
$result = [ordered]@{ success = $false; checks = $checks; cleaned = $false }

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class DropoLabProtectedRoute {
    [DllImport("iphlpapi.dll")]
    public static extern uint GetBestInterface(uint address, out uint index);
}
'@

function Invoke-Bridge($path, $value = $null) {
    $headers = @{'X-Dropo-Token' = $script:token}
    if ($null -eq $value) {
        return Invoke-RestMethod -Uri "$bridge$path" -Headers $headers -TimeoutSec 10
    }
    Invoke-RestMethod -Uri "$bridge$path" -Headers $headers -Method Post -TimeoutSec 50 `
        -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $value -Compress -Depth 8)
}
function Invoke-Core($method, $parameters = @()) {
    Invoke-Bridge '/api/call' @{ method = $method; args = @($parameters) }
}
function Require-Success($response, $stage) {
    if ($response.success -ne $true) { throw "$stage failed: $($response.error)" }
}
function Wait-Status($condition, $seconds = 25) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        try {
            $state = Invoke-Bridge '/api/status'
            if (& $condition $state) { return $state }
        } catch {}
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    throw "Status timed out: connected=$($state.connected) router=$($state.protectedRoutingReady) state=$($state.vpnState) error=$($state.protectedRoutingError)"
}
function Get-OwnedSingBox($role) {
    Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" | Where-Object {
        $_.ParentProcessId -eq $core.Id -and $_.CommandLine -like "*$role*"
    }
}
function Get-RouteIndex {
    $ip = [BitConverter]::ToUInt32(([Net.IPAddress]'203.0.113.9').GetAddressBytes(), 0)
    [uint32]$index = 0
    if ([DropoLabProtectedRoute]::GetBestInterface($ip, [ref]$index) -eq 0) { return $index }
    return 0
}
function Get-InterfaceAlias([uint32]$index) {
    if ($index) {
        return (Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $index -ErrorAction SilentlyContinue).InterfaceAlias
    }
}
function Test-OrdinaryHTTPS([string]$referenceIP = '', [switch]$IPv4) {
    $arguments = @('-s','--noproxy','*','--connect-timeout','8','--max-time','12','-o','NUL','-w','%{http_code}')
    if ($IPv4) { $arguments += '-4' }
    if ($referenceIP) { $arguments += @('--resolve', ('example.com:443:' + $referenceIP)) }
    $response = & curl.exe @arguments 'https://example.com/'
    return ($LASTEXITCODE -eq 0 -and [int]$response -ge 200 -and [int]$response -lt 400)
}
function Get-OpenLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

try {
    $result.physicalIPv6DefaultBeforeLaunch = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
        Where-Object State -eq 'Alive').Count -gt 0
    $referenceIP = Resolve-DnsName -Name 'example.com' -Type A -DnsOnly -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'A' | Select-Object -First 1 -ExpandProperty IPAddress
    $core = Start-Process -FilePath $exe.FullName -ArgumentList '--listen','127.0.0.1:32890','--no-tray' -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(25)
    while (!(Test-Path -LiteralPath $tokenPath) -and (Get-Date) -lt $deadline) {
        if ($core.HasExited) { throw 'Packaged core exited.' }
        Start-Sleep -Milliseconds 250
    }
    $script:token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    $initial = Wait-Status { param($s) $s.protectedRoutingReady -or $s.protectedRoutingError }
    $initialSettings = Invoke-Core 'GetAppConfig'
    $routerIndex = Get-RouteIndex
    $result.initial = @{ route = Get-InterfaceAlias $routerIndex; error = $initial.protectedRoutingError }
    $checks.defaultEnabled = $initialSettings.protectedRoutingEnabled -and !$initial.connected
    $checks.independentWintun = $initial.protectedRoutingReady -and $result.initial.route -eq $routerAlias
    if (!$checks.independentWintun) { throw 'The startup route did not select the independent Wintun.' }
    $guard = @(Get-OwnedSingBox 'protected-router.json')
    if ($guard.Count -ne 1) { throw 'Expected exactly one lab-owned protected router.' }
    $guardPID = $guard[0].ProcessId

    $page = Invoke-WebRequest -UseBasicParsing -Uri "$bridge/vpn-required" -TimeoutSec 5
    $checks.localHelpPage = $page.StatusCode -eq 200 -and $page.Content.Contains('id="vpn-required"')
    $checks.offlineOrdinaryHTTPS = Test-OrdinaryHTTPS
    if (!$checks.offlineOrdinaryHTTPS -and $referenceIP) {
        $result.offlineOrdinaryHTTPSWithKnownAddress = Test-OrdinaryHTTPS $referenceIP
        $result.offlineOrdinaryHTTPSWithIPv4 = Test-OrdinaryHTTPS -IPv4
    }
    $addresses = @(Resolve-DnsName -Name 'claude.ai' -Type A -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress)
    $result.offlineDNS = $addresses
    $checks.offlineProtectedDNS = $addresses.Count -gt 0 -and @($addresses | Where-Object { $_ -notmatch '^198\.19\.' }).Count -eq 0
    if ($referenceIP) {
        $checks.sharedAddressOrdinaryTLS = Test-OrdinaryHTTPS $referenceIP
        & curl.exe -s --noproxy '*' --connect-timeout 2 --max-time 3 -o NUL --resolve "claude.ai:443:$referenceIP" 'https://claude.ai/'
        $checks.sharedAddressProtectedTLSStopped = $LASTEXITCODE -ne 0
        $checks.sharedAddressProtectedRouteEvent = @((Invoke-Bridge '/api/events').events | Where-Object name -eq 'protected-route-denied').Count -gt 0
    }
    & curl.exe -s --noproxy '*' --connect-timeout 2 --max-time 3 -o NUL 'https://claude.ai/'
    $checks.offlineProtectedHTTPS = $LASTEXITCODE -ne 0
    $checks.offlineNotice = @((Invoke-Bridge '/api/events').events | Where-Object name -eq 'protected-route-denied').Count -gt 0

    $httpPort = Get-OpenLoopbackPort
    $vpnPort = Get-OpenLoopbackPort
    $fixtureHTTP = Start-Job -ArgumentList $httpPort -ScriptBlock {
        param($port)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
        try {
            $listener.Start()
            while ($true) {
                if (!$listener.Pending()) {
                    Start-Sleep -Milliseconds 50
                    continue
                }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 2500
                    $reader = [IO.StreamReader]::new($stream)
                    while ($reader.ReadLine()) {}
                    $body = 'dropo-vpn-only-fixture'
                    $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nConnection: close`r`nContent-Length: $($body.Length)`r`n`r`n$body")
                    $stream.Write($response, 0, $response.Length)
                } catch {} finally {
                    $client.Dispose()
                }
            }
        } finally {
            $listener.Stop()
        }
    }
    $mock = (New-Item -ItemType Directory -Path (Join-Path $Root 'mock-vpn')).FullName
    $vendorExe = Get-ChildItem -LiteralPath $package -Filter sing-box.exe -Recurse -File | Select-Object -First 1
    $mockExe = Join-Path $mock 'sing-box.exe'
    Copy-Item -LiteralPath $vendorExe.FullName -Destination $mockExe
    $uuid = '00000000-0000-4000-8000-000000000001'
    $mockConfig = Join-Path $mock 'vpn.json'
    @{
        log = @{ level = 'debug' }
        inbounds = @(@{ type = 'vless'; tag = 'fixture-in'; listen = '127.0.0.1'; listen_port = $vpnPort; users = @(@{ uuid = $uuid }) })
        outbounds = @(@{ type = 'direct'; tag = 'fixture-local' })
        route = @{ rules = @(
            @{ domain = @('claude.ai'); port = @(80); action = 'route'; outbound = 'fixture-local'; override_address = '127.0.0.1'; override_port = $httpPort },
            @{ action = 'reject' }
        ) }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mockConfig -Encoding ASCII
    $fixtureLog = Join-Path $mock 'fixture.log'
    $fixtureVPN = Start-Process -FilePath $mockExe -ArgumentList 'run','-c',$mockConfig -WindowStyle Hidden -PassThru -RedirectStandardError $fixtureLog
    $uri = "vless://$uuid@127.0.0.1:${vpnPort}?security=none&type=tcp#fixture"
    Require-Success (Invoke-Core 'AddVPNSource' @('Local transport fixture',$uri)) 'Add source'
    foreach ($mode in 'all_traffic', 'blocked_only') {
        Require-Success (Invoke-Core 'SetRoutingMode' @($mode)) "Set $mode"
        Require-Success (Invoke-Bridge '/api/connect' @{}) "Connect $mode"
        $null = Wait-Status { param($s) $s.connected -and $s.protectedRoutingReady }
        $result["route_$mode"] = Get-InterfaceAlias (Get-RouteIndex)
        $checks["ordinaryHTTPS_$mode"] = Test-OrdinaryHTTPS
        if (!$checks["ordinaryHTTPS_$mode"]) {
            $result["ordinaryDNS_$mode"] = @(Resolve-DnsName -Name 'example.com' -Type A -DnsOnly -ErrorAction SilentlyContinue |
                Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress)
            if ($referenceIP) { $result["ordinaryWithKnownIP_$mode"] = Test-OrdinaryHTTPS $referenceIP }
            $result["ordinaryWithIPv4_$mode"] = Test-OrdinaryHTTPS -IPv4
        }
        if ($checks.offlineProtectedDNS) {
            $aliasAddress = $addresses[0]
            $body = & curl.exe -s --noproxy '*' --connect-timeout 4 --max-time 6 --resolve "claude.ai:80:$aliasAddress" 'http://claude.ai/dropo-protected-check'
            $checks["cachedProtectedDomainViaVPN_$mode"] = $LASTEXITCODE -eq 0 -and $body -eq 'dropo-vpn-only-fixture'
        }
        Require-Success (Invoke-Bridge '/api/disconnect' @{}) "Disconnect $mode"
        $null = Wait-Status { param($s) !$s.connected -and $s.protectedRoutingReady }
        $checks["manualStop_$mode"] = (Get-RouteIndex) -eq $routerIndex -and @(Get-OwnedSingBox 'protected-router.json')[0].ProcessId -eq $guardPID
    }

    Require-Success (Invoke-Core 'SetRoutingMode' @('all_traffic')) 'Set crash mode'
    Require-Success (Invoke-Bridge '/api/connect' @{}) 'Connect for transport crash'
    $transport = @(Get-OwnedSingBox 'active_config.json')
    if ($transport.Count -ne 1) { throw 'Expected exactly one lab-owned VPN transport.' }
    Stop-Process -Id $transport[0].ProcessId -Force
    $deadline = (Get-Date).AddMilliseconds(1800)
    do {
        if ((Get-RouteIndex) -eq $routerIndex) { $checks.crashRetainsIndependentRoute = $true; break }
        Start-Sleep -Milliseconds 15
    } while ((Get-Date) -lt $deadline)
    $null = Wait-Status { param($s) $s.connected -and $s.vpnState -ne 'reconnecting' -and @(Get-OwnedSingBox 'active_config.json')[0].ProcessId -ne $transport[0].ProcessId }
    $checks.crashRetainsRouterProcess = @(Get-OwnedSingBox 'protected-router.json')[0].ProcessId -eq $guardPID
    Require-Success (Invoke-Bridge '/api/disconnect' @{}) 'Disconnect after recovery'
    Require-Success (Invoke-Core 'SetProtectedRouting' @($false)) 'Disable protection'
    $null = Wait-Status { param($s) !$s.protectedRoutingReady }
    $disabled = Invoke-Core 'GetAppConfig'
    $checks.switchOff = !$disabled.protectedRoutingEnabled -and (Get-RouteIndex) -ne $routerIndex -and (Test-OrdinaryHTTPS)
    Require-Success (Invoke-Core 'SetProtectedRouting' @($true)) 'Re-enable protection'
    $null = Wait-Status { param($s) $s.protectedRoutingReady }
    $checks.switchOn = (Get-InterfaceAlias (Get-RouteIndex)) -eq $routerAlias
    if (Test-Path -LiteralPath $fixtureLog) {
        $result.mockObservedProtectedFlow = [bool](Select-String -LiteralPath $fixtureLog -Pattern 'inbound connection to claude.ai:80' -SimpleMatch -Quiet)
        $result.mockFatal = @(Select-String -LiteralPath $fixtureLog -Pattern 'FATAL' | Select-Object -Last 2 -ExpandProperty Line)
    }
    $result.success = $checks.crashRetainsIndependentRoute -and @($checks.Values | Where-Object { $_ -ne $true }).Count -eq 0
} catch {
    $result.error = $_.Exception.Message
    if ($_.ErrorDetails.Message) { $result.error += " :: $($_.ErrorDetails.Message)" }
    try {
        $result.diagnostics = @((Invoke-Bridge '/api/logs?lastN=100').logs |
            Where-Object { $_ -match '\[ProtectedRouting\]|\[Start\]|FATAL|bind:' } | Select-Object -Last 8)
    } catch {}
} finally {
    if ($fixtureVPN -and !$fixtureVPN.HasExited) {
        Stop-Process -Id $fixtureVPN.Id -Force
        $null = $fixtureVPN.WaitForExit(5000)
    }
    if ($fixtureHTTP) {
        Stop-Job -Job $fixtureHTTP -ErrorAction SilentlyContinue
        Remove-Job -Job $fixtureHTTP -ErrorAction SilentlyContinue
    }
    if ($core -and !$core.HasExited) {
        if ($script:token) {
            try {
                $null = Invoke-Bridge '/api/disconnect' @{}
                $null = Invoke-Core 'SetProtectedRouting' @($false)
            } catch {}
        }
        Stop-Process -Id $core.Id -Force
        $null = $core.WaitForExit(5000)
    }
    $result.cleaned = [bool]$core -and $core.HasExited -and
        !(Get-NetAdapter -Name $routerAlias -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
}
[PSCustomObject]$result
