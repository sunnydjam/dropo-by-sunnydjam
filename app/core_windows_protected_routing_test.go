package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestIndependentWindowsRouterUsesOnlyProtectedCatalog(t *testing.T) {
	config := buildWindowsProtectedRouterConfig(protectedRouterLink{Port: 43125, Password: "local-fixture"})
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
