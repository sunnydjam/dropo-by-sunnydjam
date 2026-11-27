package main

import (
	"bytes"
	traffic "dropo/trafficorchestrator"
	"dropocore/aicatalog"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Exercise sing-box itself without changing the machine's routes or contacting
// a public service. The ordinary and VPN exits both end at local HTTP proxies.
func TestWindowsServiceRoutingDataplane(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows runtime")
	}
	binary := os.Getenv("DROPO_TEST_SINGBOX")
	if binary == "" {
		binaries, _ := filepath.Glob(filepath.Join("..", "dependencies", "sing-box-v"+SingBoxVersion, "windows-amd64", "sing-box-*", "sing-box.exe"))
		if len(binaries) == 0 {
			t.Skip("bundled executable absent")
		}
		binary = binaries[0]
	}
	for _, mode := range []RoutingMode{RoutingModeBlockedOnly, RoutingModeAllTraffic} {
		t.Run(string(mode), func(t *testing.T) {
			observed := make(chan string, 4)
			outbounds := []any{}
			var vpnExit *httptest.Server
			for _, tag := range []string{"direct", "vpn-fixture"} {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { observed <- tag; w.WriteHeader(http.StatusBadGateway) }))
				if tag == "vpn-fixture" {
					vpnExit = server
				}
				t.Cleanup(server.Close)
				outbounds = append(outbounds, map[string]any{"type": "http", "tag": tag, "server": "127.0.0.1", "server_port": server.Listener.Addr().(*net.TCPAddr).Port})
			}
			outbounds = append(outbounds, buildVPNSourceFallbackOutbound([]string{"vpn-fixture"}),
				map[string]any{"type": "selector", "tag": "proxy", "outbounds": []string{"auto-select", "vpn-fixture"}})
			dir, err := filepath.Abs(filepath.Join("..", "dependencies", "filters"))
			if err != nil {
				t.Fatal(err)
			}
			b := ConfigBuilderForStorage{filterManager: &FilterManager{filtersPath: dir}, routingMode: mode}
			route := map[string]any{}
			if mode == RoutingModeAllTraffic {
				b.applyAllTrafficMode(route)
			} else {
				settings := GlobalAppSettings{FreeAccessMethods: map[string]string{"youtube": FreeAccessMethodDirect, "claude": FreeAccessMethodDirect}}
				b.applyBlockedOnlyMode(route, settings, true)
				for _, raw := range route["rules"].([]any) {
					rule := raw.(map[string]any)
					tag, _ := rule["outbound"].(string)
					if tag != "" && !outboundTagExists(outbounds, tag) {
						outbounds = append(outbounds, map[string]any{"type": "selector", "tag": tag, "outbounds": []string{"proxy"}})
					}
				}
			}
			ln, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			port := ln.Addr().(*net.TCPAddr).Port
			ln.Close()
			config := map[string]any{"log": map[string]any{"level": "error"}, "inbounds": []any{map[string]any{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}}, "outbounds": outbounds, "route": route}
			config["dns"] = map[string]any{"servers": []any{map[string]any{"type": "local", "tag": "dns-direct"}}, "final": "dns-direct"}
			fixture := t.TempDir()
			custom := customVPNRuleSetPath(fixture)
			if err = writeCustomVPNRuleSet(custom, nil); err != nil {
				t.Fatal(err)
			}
			config = withCustomVPNRules(config, custom)
			// Two actual Windows processes with the same basename and different paths.
			// Neither ever contacts the public destination; both exits terminate here.
			bound := filepath.Join(fixture, "alternate.exe")
			unbound := filepath.Join(t.TempDir(), "alternate.exe")
			curl, err := os.ReadFile(filepath.Join(os.Getenv("SystemRoot"), "System32", "curl.exe"))
			if err != nil {
				t.Fatal(err)
			}
			directApp := filepath.Join(fixture, "direct-app.exe")
			protectedApp := filepath.Join(fixture, "protected-app.exe")
			for _, path := range []string{bound, unbound, directApp, protectedApp} {
				if err = os.WriteFile(path, curl, 0700); err != nil {
					t.Fatal(err)
				}
			}
			applyApplicationBindings(config, GlobalAppSettings{RoutingMode: mode, FreeAccessMethods: map[string]string{"youtube": FreeAccessMethodDirect}, ApplicationBindings: []applicationBinding{{Path: bound, Service: "discord"}, {Path: directApp, Service: "youtube"}}})
			path := filepath.Join(fixture, "config.json")
			if err = writeJSONConfig(path, config); err != nil {
				t.Fatal(err)
			}
			var pacAddr, relayAddr string
			if mode == RoutingModeBlockedOnly {
				relayPort, err := findAvailableTCPPort("127.0.0.1")
				if err != nil {
					t.Fatal(err)
				}
				// Keep the simulated TUN traffic on its own test socket. PAC and relay
				// traffic must traverse precisely the listeners used at application startup.
				config["inbounds"] = append([]any{map[string]any{"type": "mixed", "tag": "relay", "listen": "127.0.0.1", "listen_port": relayPort}}, config["inbounds"].([]any)...)
				if err := writeJSONConfig(path, config); err != nil {
					t.Fatal(err)
				}
				a := &App{basePath: fixture}
				path, err = a.writeDeepWindowsProxyFallbackConfig(path)
				if err != nil {
					t.Fatal(err)
				}
				relayAddr = net.JoinHostPort("127.0.0.1", strconv.Itoa(relayPort))
				pacAddr, err = configuredPACAddress(path, relayAddr)
				if err != nil || pacAddr == relayAddr {
					t.Fatalf("PAC listener: %q %v", pacAddr, err)
				}
			}
			cmd := exec.Command(binary, "run", "-c", path)
			var logs bytes.Buffer
			cmd.Stdout = &logs
			cmd.Stderr = &logs
			if err = cmd.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
				if t.Failed() {
					t.Log(logs.String())
				}
			})
			addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
			deadline := time.Now().Add(4 * time.Second)
			for {
				c, e := net.DialTimeout("tcp4", addr, 100*time.Millisecond)
				if e == nil {
					c.Close()
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("mixed listener did not start")
				}
				time.Sleep(20 * time.Millisecond)
			}
			if mode == RoutingModeBlockedOnly {
				plan := traffic.TrafficPlan{Services: []traffic.ServiceRule{
					{ID: "claude", VPNOnly: true, ProcessNames: []string{protectedApp}, DomainSuffixes: []string{"claude.ai"}},
					{ID: "youtube", DomainSuffixes: []string{"youtube.com"}, TCPPorts: []int{443}},
					{ID: commonBlockedServiceTag, DomainSuffixes: []string{"rutracker.org"}}},
					Routes: []traffic.ServiceRoute{{ServiceID: "claude", Kind: traffic.ServiceRouteVPN}, {ServiceID: "youtube", Kind: traffic.ServiceRouteZapret}, {ServiceID: commonBlockedServiceTag, Kind: traffic.ServiceRouteVPN}}}
				z, err := startZapretConnectProxy(plan, relayAddr, nil)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = z.Close() })
				// Prevent any public dial if the owner check ever regresses.
				z.resolveMu.Lock()
				z.resolved["youtube.com"] = zapretResolvedTarget{addresses: []netip.Addr{netip.MustParseAddr("127.0.0.1")}, expires: time.Now().Add(time.Minute)}
				z.resolveMu.Unlock()
				script, _, err := buildSelectiveProxyPAC(pacAddr, z.Address(), selectiveDomainsForPlan(plan))
				if err != nil {
					t.Fatal(err)
				}
				for _, c := range []struct{ app, host, want string }{{directApp, "rutracker.org", "direct"}, {directApp, "claude.ai", "vpn-fixture"}, {protectedApp, "youtube.com", "vpn-fixture"}} {
					result, err := exec.Command("node", "-e", "function dnsDomainIs(h,s){return h.endsWith(s)};"+script+";console.log(FindProxyForURL('https://"+c.host+"/','"+c.host+"'))").CombinedOutput()
					if err != nil {
						t.Fatalf("evaluate PAC: %v %s", err, result)
					}
					addr, ok := strings.CutPrefix(strings.TrimSpace(string(result)), "PROXY ")
					if !ok {
						t.Fatalf("expected proxy: %s", result)
					}
					output, err := exec.Command(c.app, "--disable", "--noproxy", "", "--proxy", "http://"+addr, "--max-time", "3", "https://"+c.host+"/").CombinedOutput()
					select {
					case got := <-observed:
						if got != c.want {
							t.Fatalf("%s via PAC: got %s want %s", c.host, got, c.want)
						}
					case <-time.After(time.Second):
						t.Fatalf("%s missing expected exit %s: %v %s", c.host, c.want, err, output)
					}
				}
			}
			transport := &http.Transport{Proxy: http.ProxyURL(&url.URL{Scheme: "http", Host: addr}), DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := http.Client{Transport: transport, Timeout: 2 * time.Second}
			cases := map[string]string{"vk.com": "direct", "www.ozon.ru": "direct", "online.sberbank.ru": "direct", "ordinary.example": "direct", "rutracker.org": "proxy", "api.anthropic.com": "proxy", "chatgpt.com": "proxy", "gemini.google.com": "proxy", "slack.com": "proxy", "youtube.com": "proxy", "discord.com": "proxy", "gateway.discord.gg": "proxy", "c-arn02-85d3b23f.discord.media": "proxy", "discord.media.ordinary.example": "direct", "twitch.tv": "direct", "gql.twitch.tv": "proxy", "facetime.apple.com": "direct"}
			if mode == RoutingModeBlockedOnly {
				cases["youtube.com"] = "direct"
				delete(cases, "gql.twitch.tv") // The saved service policy takes precedence here.
			}
			for host, want := range cases {
				if want == "proxy" {
					want = "vpn-fixture"
				}
				resp, _ := client.Get(fmt.Sprintf("http://%s/", host))
				if resp != nil {
					resp.Body.Close()
				}
				select {
				case got := <-observed:
					if got != want {
						t.Errorf("%s exit %s, want %s", host, got, want)
					}
				case <-time.After(300 * time.Millisecond):
					t.Fatalf("%s did not reach either local exit", host)
				}
			}
			awaitCustomExit := func(services []aicatalog.CustomService, expected string) {
				t.Helper()
				if err := writeCustomVPNRuleSet(custom, services); err != nil {
					t.Fatal(err)
				}
				deadline := time.Now().Add(5 * time.Second)
				for time.Now().Before(deadline) {
					resp, _ := client.Get("http://media.vk.com/")
					if resp != nil {
						resp.Body.Close()
					}
					select {
					case exit := <-observed:
						if exit == expected {
							return
						}
					case <-time.After(300 * time.Millisecond):
						t.Fatal("custom-domain request did not reach either exit")
					}
					time.Sleep(100 * time.Millisecond)
				}
				t.Fatalf("edited rule-set did not reload to %s", expected)
			}
			awaitCustomExit([]aicatalog.CustomService{{Domains: []string{"vk.com"}}}, "vpn-fixture")
			awaitCustomExit(nil, "direct")
			for _, process := range []struct{ path, exit string }{{bound, "vpn-fixture"}, {unbound, "direct"}} {
				client := exec.Command(process.path, "--disable", "--noproxy", "", "--proxy", "http://"+addr, "--max-time", "3", "http://104.29.136.217:19317/")
				// The upstream fixture intentionally rejects CONNECT. The observed
				// listener establishes the route even when curl receives a reset.
				output, clientErr := client.CombinedOutput()
				select {
				case got := <-observed:
					if got != process.exit {
						t.Fatalf("%s routed to %s; want %s", process.path, got, process.exit)
					}
				case <-time.After(time.Second):
					t.Fatalf("no process routing observation: %v %s", clientErr, output)
				}
			}
			awaitCustomExit([]aicatalog.CustomService{{Domains: []string{"media.vk.com"}}}, "vpn-fixture")
			vpnExit.Close()
			for _, host := range []string{"chatgpt.com", "rutracker.org", "media.vk.com", "vk.com"} {
				resp, _ := client.Get("http://" + host + "/")
				if resp != nil {
					resp.Body.Close()
				}
				select {
				case got := <-observed:
					if host != "vk.com" || got != "direct" {
						t.Fatalf("VPN unavailable: %s escaped through %s", host, got)
					}
				default:
					if host == "vk.com" {
						t.Fatal("VPN unavailable: VK lost its ordinary direct route")
					}
				}
			}
		})
	}
}

// PAC evaluation also covers Secure-DNS browsers that never consume the
// native synthetic DNS response. Execute the exact PAC delivered to browsers.
func TestSelectiveBundledPACAndScopedIPRoutes(t *testing.T) {
	domains, err := readBlockedCatalogLines(filepath.Join("..", "dependencies", "filters", blockedDomainsFileName), true)
	if err != nil {
		t.Fatal(err)
	}
	script, _, err := buildSelectiveProxyPAC("127.0.0.1:2088", "127.0.0.1:2089", selectiveDomainPlan{catalog: domains, catalogRoute: "vpn"})
	if err != nil || len(script) > 1024*1024 {
		t.Fatalf("PAC bytes=%d, err=%v", len(script), err)
	}
	config := map[string]any{"route": map[string]any{"rule_set": []any{map[string]any{"type": "local", "tag": "refilter-ips"}}}, "inbounds": []any{map[string]any{"type": "tun", "strict_route": true}, map[string]any{"type": "mixed"}}}
	scopeSelectiveTunToCatalog(config)
	tun := config["inbounds"].([]any)[0].(map[string]any)
	if tun["dns_mode"] != "disabled" || tun["strict_route"] != false || !stringSetEqual(interfaceStringSlice(tun["route_address_set"]), []string{"refilter-ips"}) || strings.Contains(fmt.Sprint(tun["route_address"]), "/0") {
		t.Fatalf("selective TUN: %v", tun)
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("PAC engine test requires Node")
	}
	program := script + `
 for (const host of ['rutracker.org','forum.rutracker.org','vk.com','www.ozon.ru','online.sberbank.ru','rutracker.org.example']) {
  const want=host==='rutracker.org'||host==='forum.rutracker.org'?'PROXY 127.0.0.1:2088':'DIRECT';
  if(FindProxyForURL('https://'+host,host)!==want)throw new Error(host);
 }`
	file := filepath.Join(t.TempDir(), "catalog.js")
	if err = os.WriteFile(file, []byte(program), 0600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command(node, file).CombinedOutput(); err != nil {
		t.Fatalf("PAC: %v %s", err, output)
	}
}
