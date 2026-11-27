package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestIndependentWindowsRouterUsesOnlyProtectedCatalog(t *testing.T) {
	custom := customVPNRuleSetPath(t.TempDir())
	if err := writeCustomVPNRuleSet(custom, nil); err != nil {
		t.Fatal(err)
	}
	config := buildWindowsProtectedRouterConfig(protectedRouterLink{Port: 43125, Password: "local-fixture"}, custom)
	route := config["route"].(map[string]any)
	if route["final"] != "direct" {
		t.Fatal("ordinary traffic must leave the router directly")
	}
	dns := config["dns"].(map[string]any)
	if dns["final"] != "dns-direct" {
		t.Fatal("ordinary DNS fallback must use a direct resolver")
	}
	for _, raw := range route["rules"].([]any) {
		rule := raw.(map[string]any)
		if rule["outbound"] == windowsProtectedLinkOutbound && rule["ip_cidr"] != nil {
			t.Fatalf("shared addresses must never imply a protected service: %v", rule)
		}
	}
	dump, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	packages, err := filepath.Glob(filepath.Join("..", "dependencies", "sing-box-v*", "windows-amd64", "sing-box-*", "sing-box.exe"))
	if err != nil || len(packages) == 0 {
		t.Skip("bundled Windows sing-box runtime is unavailable")
	}
	path := filepath.Join(t.TempDir(), "router.json")
	if err := os.WriteFile(path, dump, 0600); err != nil {
		t.Fatal(err)
	}
	if out, err := newBackgroundCommand(packages[0], "check", "-c", path).CombinedOutput(); err != nil {
		t.Fatalf("bundled sing-box check: %v\n%s", err, out)
	}
}

func TestCustomVPNServiceEditsPersistAndDoNotAcceptIPRules(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows settings API")
	}
	base := t.TempDir()
	store := NewStorage(base)
	if err := store.Init(); err != nil {
		t.Fatal(err)
	}
	app := NewApp()
	app.storage = store
	app.initialized = true
	app.signalInitDone()
	if result := app.SetCustomVPNService("", "Example", "EXAMPLE.com, api.example.org", false); !apiResultSucceeded(result) {
		t.Fatalf("add: %v", result)
	}
	services := store.GetAppSettings().CustomVPNServices
	if len(services) != 1 || !hostInCustomVPNList("api.example.com", services) || hostInCustomVPNList("unrelatedexample.com", services) {
		t.Fatalf("invalid domain scope: %v", services)
	}
	if result := app.SetCustomVPNService(services[0].ID, "Invalid", "203.0.113.20", false); apiResultSucceeded(result) {
		t.Fatal("IP-only custom rule accepted")
	}
	if result := app.SetCustomVPNService(services[0].ID, "Changed", "test.example.org", false); !apiResultSucceeded(result) {
		t.Fatalf("edit: %v", result)
	}
	reopened := NewStorage(base)
	if err := reopened.Init(); err != nil {
		t.Fatal(err)
	}
	updated := reopened.GetAppSettings().CustomVPNServices
	if len(updated) != 1 || updated[0].ID != services[0].ID || updated[0].Name != "Changed" || !hostInCustomVPNList("test.example.org", updated) || hostInCustomVPNList("example.com", updated) {
		t.Fatalf("edit did not replace the saved rule: %v", updated)
	}
	if result := app.SetCustomVPNService(services[0].ID, "", "", true); !apiResultSucceeded(result) || len(store.GetAppSettings().CustomVPNServices) != 0 {
		t.Fatalf("remove: %v", result)
	}
	data, err := os.ReadFile(customVPNRuleSetPath(store.GetResourcesPath()))
	var ruleSet struct{ Rules []json.RawMessage }
	if err != nil || json.Unmarshal(data, &ruleSet) != nil || len(ruleSet.Rules) != 0 {
		t.Fatalf("rule-set not updated after removal: %s, %v", data, err)
	}
}

func TestIndependentRouterLinkRejectsDirectSelectorChain(t *testing.T) {
	outbounds := []any{
		map[string]any{"type": "selector", "tag": "auto-select", "outbounds": []any{"fallback"}},
		map[string]any{"type": "selector", "tag": "fallback", "outbounds": []any{"vless-fixture", "direct"}},
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "vless", "tag": "vless-fixture"},
	}
	if protectedLinkUsesVPN(outbounds, "auto-select", map[string]bool{}) {
		t.Fatal("VPN-only traffic must not enter a selector admitting direct egress")
	}
	outbounds[1].(map[string]any)["outbounds"] = []any{"vless-fixture"}
	if !protectedLinkUsesVPN(outbounds, "auto-select", map[string]bool{}) {
		t.Fatal("valid VPN transport selector rejected")
	}
}

func TestProtectedRoutingDefaultsOnAndPersistsOptOut(t *testing.T) {
	path := t.TempDir()
	store := NewStorage(path)
	if err := store.Init(); err != nil {
		t.Fatal(err)
	}
	settings := store.GetAppSettings()
	if settings.DisableProtectedRouting {
		t.Fatal("fresh settings disabled the independent router")
	}
	settings.DisableProtectedRouting = true
	if err := store.UpdateAppSettings(settings); err != nil {
		t.Fatal(err)
	}
	reopened := NewStorage(path)
	if err := reopened.Init(); err != nil {
		t.Fatal(err)
	}
	if !reopened.GetAppSettings().DisableProtectedRouting {
		t.Fatal("reloading settings discarded the explicit opt-out")
	}
}
