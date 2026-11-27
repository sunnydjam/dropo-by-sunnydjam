package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"testing"
	"time"
)

func TestApplicationBindingEditsAndProtection(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows paths")
	}
	store := NewStorage(t.TempDir())
	if err := store.Init(); err != nil {
		t.Fatal(err)
	}
	a := NewApp()
	a.storage, a.initialized = store, true
	a.signalInitDone()
	path := `C:\Apps\Browser (test)\client.exe`
	call := func(old, path, tag string, ok bool) {
		t.Helper()
		result := a.SetApplicationBinding(old, path, tag)
		if apiResultSucceeded(result) != ok {
			t.Fatalf("binding %q: %v", path, result)
		}
	}
	call("", path, "discord", true)
	call("", path, "claude", false)
	call("", `C:\Unrelated\Claude.exe`, "discord", false)
	call("", "relative.exe", "discord", false)
	call("", `C:\Tools\client.exe`, "does-not-exist", false)
	call(path, path, "claude", true)
	reopened := NewStorage(filepath.Dir(store.GetResourcesPath()))
	// Reopen the same settings file through the normal storage constructor.
	if err := reopened.Init(); err != nil {
		t.Fatal(err)
	}
	prefs := reopened.GetAppSettings()
	if !slices.Equal(prefs.ApplicationBindings, []applicationBinding{{Path: path, Service: "claude"}}) {
		t.Fatalf("persisted bindings: %v", prefs.ApplicationBindings)
	}
	data, err := os.ReadFile(customVPNRuleSetPath(store.GetResourcesPath()))
	var parsed struct{ Rules []map[string][]string }
	if err != nil || json.Unmarshal(data, &parsed) != nil || len(parsed.Rules) != 1 || !slices.Contains(parsed.Rules[0]["process_path_regex"], applicationPathPattern(path)) {
		t.Fatalf("offline guard missing bound executable: %s, %v", data, err)
	}
	call(path, "", "", true)
	result := a.SetCustomVPNService("", "Protected test", "example.org", false)
	if !apiResultSucceeded(result) {
		t.Fatal(result)
	}
	customID := store.GetAppSettings().CustomVPNServices[0].ID
	call("", path, customID, true)
	if !apiResultSucceeded(a.SetCustomVPNService(customID, "", "", true)) {
		t.Fatal("failed to remove custom service")
	}
	if len(store.GetAppSettings().ApplicationBindings) != 0 {
		t.Fatal("binding retained")
	}
}

func TestBlockedCatalogPageBounded(t *testing.T) {
	c := blockedCatalog{IPCIDRs: []string{"104.29.136.208/28"}}
	for i := range 35 {
		c.Domains = append(c.Domains, fmt.Sprintf("site%02d.example", i))
	}
	first := blockedCatalogPage(c, "")
	items := first["items"].([]string)
	if first["total"] != 36 || len(items) != 10 || items[0] != c.IPCIDRs[0] || items[1] != "site34.example" {
		t.Fatal(first)
	}
	for _, tc := range []struct{ query, want string }{{"site00", "site00.example"}, {"104.29.136.217", c.IPCIDRs[0]}} {
		if !slices.Equal(blockedCatalogPage(c, tc.query)["items"].([]string), []string{tc.want}) {
			t.Fatal(tc)
		}
	}
	if len(blockedCatalogPage(c, "not-present")["items"].([]string)) != 0 {
		t.Fatal("unexpected matches")
	}
}

func TestCachedCatalogApplicationMigration(t *testing.T) {
	work := map[string]any{"rule_set": []string{"work-networks"}, "outbound": "work"}
	generic := map[string]any{"rule_set": []string{"refilter-domains"}, "outbound": "proxy"}
	route := map[string]any{"rules": []any{work, generic}, "final": "direct"}
	dnsRule := map[string]any{"domain_suffix": []string{"claude.ai"}, "action": "evaluate", "tag": "primary", "server": "dns-remote-fi"}
	config := map[string]any{"route": route, "dns": map[string]any{"rules": []any{dnsRule}}}
	migrateCatalogApplications(config)
	rules := route["rules"].([]any)
	if !hasCatalogApplicationRules(route) || rules[0].(map[string]any)["outbound"] != "work" || !slices.Contains(interfaceStringSlice(rules[len(rules)-1].(map[string]any)["rule_set"]), "refilter-domains") || !slices.Contains(interfaceStringSlice(dnsRule["domain_suffix"]), "discord.media") || dnsRule["tag"] != "primary" {
		t.Fatal(config)
	}
	migrateCatalogApplications(config)
	if len(route["rules"].([]any)) != len(rules) {
		t.Fatal("duplicate migration")
	}
}

func TestManualApplicationIngressCoversPublicDestinations(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows TUN")
	}
	exclude := []string{"10.23.0.0/16"}
	a, path := newDeepWindowsTestApp(t, map[string]any{
		"route":     map[string]any{"final": "direct", "rules": []any{map[string]any{"process_name": []string{"Discord.exe"}, "outbound": "auto-select"}}},
		"inbounds":  []any{map[string]any{"tag": "tun-in", "type": "tun", "address": []string{"172.19.0.1/30"}, "route_exclude_address": exclude}, map[string]any{"tag": "mixed-in", "type": "mixed", "listen_port": 2088}},
		"outbounds": []any{map[string]any{"tag": "auto-select", "type": "selector", "outbounds": []string{"fixture"}}, map[string]any{"tag": "fixture", "type": "socks", "server": "127.0.0.1", "server_port": 1}},
	})
	path, err := a.writeDeepWindowsProxyFallbackConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	config, err := readJSONConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	tun := config["inbounds"].([]any)[0].(map[string]any)
	if !slices.Equal(interfaceStringSlice(tun["route_address"]), []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}) || !slices.Equal(interfaceStringSlice(tun["route_exclude_address"]), exclude) || tun["route_address_set"] != nil || config["route"].(map[string]any)["final"] != "direct" {
		t.Fatalf("manual application ingress: %v", tun)
	}
}

// This subprocess sends only to the fixture listener on loopback.
func TestApplicationUDPFixtureSender(t *testing.T) {
	target := os.Getenv("DROPO_APPLICATION_UDP_FIXTURE")
	if target == "" {
		t.Skip("subprocess only")
	}
	conn, err := net.Dial("udp4", target)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for range 12 {
		if _, err := conn.Write([]byte("test media datagram")); err != nil {
			t.Fatal(err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestWindowsApplicationUDPRouting(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows process lookup")
	}
	binary := os.Getenv("DROPO_TEST_SINGBOX")
	if binary == "" {
		binaries, _ := filepath.Glob(filepath.Join("..", "dependencies", "sing-box-v"+SingBoxVersion, "windows-amd64", "sing-box-*", "sing-box.exe"))
		if len(binaries) == 0 {
			t.Skip("bundled runtime unavailable")
		}
		binary = binaries[0]
	}
	source, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	for _, file := range []string{"Discord.exe", "web-browser.exe"} {
		if err = os.WriteFile(filepath.Join(dir, file), data, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, mode := range []RoutingMode{RoutingModeAllTraffic, RoutingModeBlockedOnly} {
		t.Run(string(mode), func(t *testing.T) {
			listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			addr := listener.LocalAddr().(*net.UDPAddr)
			listener.Close()
			route := map[string]any{}
			b := ConfigBuilderForStorage{routingMode: mode, filterManager: &FilterManager{filtersPath: dir}}
			settings := GlobalAppSettings{RoutingMode: mode}
			if mode == RoutingModeAllTraffic {
				b.applyAllTrafficMode(route)
			} else {
				b.applyBlockedOnlyMode(route, settings, true)
			}
			// Closed loopback proxy ports keep the fixture entirely on this machine.
			var outbounds []any
			for _, tag := range []string{"direct", "proxy", "auto-select", discordRealtimeGroupTag} {
				outbounds = append(outbounds, map[string]any{"type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": 1})
			}
			for _, raw := range route["rules"].([]any) {
				rule := raw.(map[string]any)
				tag, _ := rule["outbound"].(string)
				if tag != "" && !outboundTagExists(outbounds, tag) {
					outbounds = append(outbounds, map[string]any{"type": "selector", "tag": tag, "outbounds": []string{"proxy"}})
				}
			}
			logPath := filepath.Join(t.TempDir(), "routing.log")
			config := map[string]any{"log": map[string]any{"level": "debug", "output": logPath}, "route": route, "outbounds": outbounds,
				"inbounds": []any{map[string]any{"type": "direct", "listen": "127.0.0.1", "listen_port": addr.Port, "network": "udp", "override_address": "104.29.136.217", "override_port": 19317}}}
			applyApplicationBindings(config, settings)
			confPath := filepath.Join(dir, string(mode)+".json")
			if err := writeJSONConfig(confPath, config); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(binary, "run", "-c", confPath)
			var startup bytes.Buffer
			cmd.Stderr = &startup
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
				if t.Failed() {
					t.Log(startup.String())
				}
			})
			waitLog := func(start int, match string) {
				t.Helper()
				until := time.Now().Add(5 * time.Second)
				for time.Now().Before(until) {
					log, _ := os.ReadFile(logPath)
					if len(log) >= start && bytes.Contains(log[start:], []byte(match)) {
						return
					}
					time.Sleep(20 * time.Millisecond)
				}
				log, _ := os.ReadFile(logPath)
				t.Fatalf("missing %q in %s", match, log)
			}
			waitLog(0, "started")
			target := "proxy"
			if mode == RoutingModeBlockedOnly {
				target = discordRealtimeGroupTag
			}
			for _, tc := range []struct{ file, route string }{{"Discord.exe", target}, {"web-browser.exe", "direct"}} {
				log, _ := os.ReadFile(logPath)
				sender := exec.Command(filepath.Join(dir, tc.file), "-test.run=^TestApplicationUDPFixtureSender$")
				sender.Env = append(os.Environ(), "DROPO_APPLICATION_UDP_FIXTURE="+addr.String())
				if out, err := sender.CombinedOutput(); err != nil {
					t.Fatalf("sender: %v %s", err, out)
				}
				waitLog(len(log), "outbound/socks["+tc.route+"]")
			}
		})
	}
}

func TestRepeatBindingPreservesOrderAndCase(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows paths")
	}
	settings := GlobalAppSettings{ApplicationBindings: []applicationBinding{{Path: "C:/Browser/one.exe", Service: "discord"}, {Path: "C:/Browser/two.exe", Service: "youtube"}}}
	for i := range settings.ApplicationBindings {
		settings.ApplicationBindings[i].Path = filepath.Clean(settings.ApplicationBindings[i].Path)
	}
	got, err := editApplicationBinding(settings, settings.ApplicationBindings[0].Path, "c:/BROWSER/one.exe", "discord")
	if err != nil || !slices.Equal(got, settings.ApplicationBindings) {
		t.Fatalf("repeat edit: %v %v", got, err)
	}
}

func TestExactCatalogHitPrecedesMoreThanTenSubstringMatches(t *testing.T) {
	c := blockedCatalog{Domains: []string{"app.example"}}
	for i := range 12 {
		c.Domains = append(c.Domains, fmt.Sprintf("site%02d.app.example", i))
	}
	got := blockedCatalogPage(c, "app.example")["items"].([]string)
	if len(got) != 10 || got[0] != "app.example" {
		t.Fatalf("exact match: %v", got)
	}
}
