package main

import (
	"dropocore/aicatalog"
	"path/filepath"
	"runtime"
	"testing"
)

func TestSaveAppConfigRejectsUnsupportedValues(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	stubApplyAutoStart(t)

	tests := []struct {
		name     string
		theme    string
		language string
		level    string
		interval int
	}{
		{name: "theme", theme: "neon", language: "ru", level: "info", interval: 24},
		{name: "language", theme: "system", language: "en", level: "info", interval: 24},
		{name: "log level", theme: "system", language: "ru", level: "verbose", interval: 24},
		{name: "short interval", theme: "system", language: "ru", level: "info", interval: 0},
		{name: "long interval", theme: "system", language: "ru", level: "info", interval: 721},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := app.SaveAppConfig(true, true, true, true, true, test.theme, test.language, test.level, test.interval)
			if success, _ := result["success"].(bool); success {
				t.Fatalf("SaveAppConfig accepted invalid %s: %#v", test.name, result)
			}
		})
	}
}

func TestSaveAppConfigAppliesThemeLiveButProtectsActiveLogging(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	stubApplyAutoStart(t)
	app.mu.Lock()
	app.isRunning = true
	app.mu.Unlock()

	result := app.SaveAppConfig(true, true, true, true, true, "dark", "ru", "info", 24)
	requireAPISuccess(t, result)
	if app.storage.GetAppSettings().Theme != ThemeDark {
		t.Fatal("theme was not saved while VPN was active")
	}

	result = app.SaveAppConfig(true, true, true, true, true, "dark", "ru", "debug", 24)
	if success, _ := result["success"].(bool); success {
		t.Fatal("logging level changed while VPN was active")
	}
}

func TestStorageNormalizesUnsupportedVisibleSettings(t *testing.T) {
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	storage.data.App.Theme = Theme("neon")
	storage.data.App.Language = LangEnglish
	storage.data.App.LogLevel = LogLevel("verbose")
	storage.data.App.RoutingMode = RoutingMode("unknown")
	storage.data.App.SubUpdateInterval = 9999
	storage.normalizeAppSettings()

	settings := storage.data.App
	if settings.Theme != ThemeSystem || settings.Language != LangRussian || settings.LogLevel != LogLevelInfo ||
		settings.RoutingMode != DefaultRoutingMode || settings.SubUpdateInterval != 24 {
		t.Fatalf("normalized settings = %+v", settings)
	}
}

func TestStorageMigratesLegacyDisabledServiceToVisibleDirectPolicy(t *testing.T) {
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	storage.data.App.FreeAccessServices["youtube"] = false
	storage.data.App.FreeAccessMethods["youtube"] = FreeAccessMethodAuto

	storage.normalizeAppSettings()

	settings := storage.data.App
	if got := settings.FreeAccessMethods["youtube"]; got != FreeAccessMethodDirect {
		t.Fatalf("migrated YouTube policy = %q, want direct", got)
	}
	if !settings.FreeAccessServices["youtube"] {
		t.Fatal("legacy hidden service flag was not normalized after migration")
	}
}

func TestFreshWindowsSettingsUseReleaseRecommendedRoutes(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows release defaults")
	}
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	methods := storage.GetAppSettings().FreeAccessMethods
	for _, service := range DefaultFreeAccessServices {
		want := FreeAccessMethodDirect
		if aicatalog.VPNOnly(service.Tag) || service.Tag == "youtube" || service.Tag == "discord" {
			want = FreeAccessMethodVPN
		}
		if got := methods[service.Tag]; got != want {
			t.Fatalf("fresh %s policy = %q", service.Tag, got)
		}
	}
}

func TestReleaseDefaultsDoNotOverwriteSavedExplicitRoutes(t *testing.T) {
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	storage.data.App.FreeAccessMethods["youtube"] = FreeAccessMethodVPN
	storage.data.App.FreeAccessMethods["discord"] = FreeAccessMethodZapret
	storage.normalizeAppSettings()

	methods := storage.GetAppSettings().FreeAccessMethods
	if methods["youtube"] != FreeAccessMethodVPN || methods["discord"] != FreeAccessMethodZapret {
		t.Fatalf("saved explicit routes were replaced: %+v", methods)
	}
}

func TestLegacyAIPolicyUpgrade(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows settings")
	}
	s := NewStorage(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatal(err)
	}
	s.data.Version = 6
	app := &s.data.App
	app.Notifications = false
	app.FreeAccessMethods["openai"] = FreeAccessMethodAuto
	app.FreeAccessMethods["ai-other"] = FreeAccessMethodDirect
	delete(app.FreeAccessMethods, "claude")
	s.normalizeAppSettings()
	if app.Notifications || app.FreeAccessMethods["openai"] != FreeAccessMethodVPN ||
		app.FreeAccessMethods["claude"] != FreeAccessMethodVPN || app.FreeAccessMethods["ai-other"] != FreeAccessMethodVPN {
		t.Errorf("incorrect AI migration: methods=%v notifications=%v", app.FreeAccessMethods, app.Notifications)
	}
	app.FreeAccessMethods["openai"] = FreeAccessMethodAuto
	app.RoutingMode = RoutingModeBlockedOnly
	plan := buildDeepWindowsRoutePlanForSettings(*app, false, false, false)
	if !planContainsString(plan.BlockedServices, "openai") {
		t.Fatal("automatic ChatGPT routed directly without a VPN")
	}
	b := ConfigBuilderForStorage{}
	for _, hasVPN := range []bool{true, false} {
		rules := append(protectedServiceRules(*app, hasVPN, false), b.buildFreeAccessRules(*app, hasVPN)...)
		config := map[string]interface{}{"route": map[string]interface{}{"rules": rules}}
		if !configHasClaudeRoutes(config) {
			t.Fatal("fresh selective config missing Claude routes")
		}
		want := ServiceBypassGroupTag("claude")
		if !hasVPN {
			want = NoRouteOutboundTag
		}
		for field, value := range map[string]string{"domain_suffix": "claudeusercontent.com", "process_name": "Claude.exe"} {
			found := false
			for _, raw := range rules {
				rule := raw.(map[string]interface{})
				if stringSliceContains(interfaceStringSlice(rule[field]), value) {
					found = true
					if rule["outbound"] != want {
						t.Errorf("route for %s = %v, want %s", value, rule["outbound"], want)
					}
					break
				}
			}
			if !found {
				t.Errorf("missing route for %s", value)
			}
		}
	}
}

func TestVPNOnlyServiceAPIsRejectLegacyAlternatives(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows settings API")
	}
	a := newInitializedSettingsScenarioApp(t)
	for _, tag := range []string{"openai", "claude", "ai-other", "canva", "notion", "slack", "miro", "wix", "coda", "grammarly", "docker", "clickup", "manychat", "helpscout", "atlassian"} {
		for _, method := range []string{"direct", "auto", "zapret"} {
			if result := a.SetFreeAccessServiceMethod(tag, method); result["success"] != false {
				t.Fatalf("%s accepted %s: %v", tag, method, result)
			}
		}
		if result := a.SetZapretServiceStrategy(tag, "auto", ""); result["success"] != false {
			t.Fatalf("%s allowed strategy discovery", tag)
		}
		if result := a.ToggleFreeAccessService(tag, false); result["success"] != false {
			t.Fatalf("%s allowed disabling mandatory VPN", tag)
		}
	}
}

func TestCatalogVPNUsesBundledDomainAndHostlessIPRules(t *testing.T) {
	route := map[string]any{}
	applyCatalogVPNRoutes(route, &FilterManager{filtersPath: filepath.Join("..", "dependencies", "filters")})
	if route["final"] != "direct" || len(route["rule_set"].([]any)) != 2 {
		t.Fatalf("missing bundled catalog or direct final")
	}
	stage := 0
	for _, raw := range route["rules"].([]any) {
		rule := raw.(map[string]any)
		switch {
		case stringSliceContains(interfaceStringSlice(rule["rule_set"]), "refilter-domains"):
			if stage != 0 || rule["outbound"] != "proxy" {
				t.Fatal("domain catalog priority")
			}
			stage++
		case rule["domain_regex"] != nil:
			if stage != 1 || rule["outbound"] != "direct" {
				t.Fatal("known-domain boundary")
			}
			stage++
		case stringSliceContains(interfaceStringSlice(rule["rule_set"]), "refilter-ips"):
			if stage != 2 || rule["outbound"] != "proxy" {
				t.Fatal("hostless IP catalog priority")
			}
			stage++
		}
	}
	if stage != 3 {
		t.Fatalf("incomplete catalog routing: %d", stage)
	}
}
