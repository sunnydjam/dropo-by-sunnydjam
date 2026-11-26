package main

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
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
			path := filepath.Join(t.TempDir(), "config.json")
			if err = writeJSONConfig(path, config); err != nil {
				t.Fatal(err)
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
			transport := &http.Transport{Proxy: http.ProxyURL(&url.URL{Scheme: "http", Host: addr}), DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := http.Client{Transport: transport, Timeout: 2 * time.Second}
			cases := map[string]string{"vk.com": "direct", "www.ozon.ru": "direct", "online.sberbank.ru": "direct", "ordinary.example": "direct", "rutracker.org": "proxy", "api.anthropic.com": "proxy", "chatgpt.com": "proxy", "gemini.google.com": "proxy", "slack.com": "proxy", "youtube.com": "proxy", "discord.com": "proxy", "twitch.tv": "direct", "gql.twitch.tv": "proxy", "facetime.apple.com": "direct"}
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
			vpnExit.Close()
			for _, host := range []string{"chatgpt.com", "rutracker.org", "vk.com"} {
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
