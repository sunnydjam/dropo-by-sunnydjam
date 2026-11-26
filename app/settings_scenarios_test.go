package main

import (
	"dropocore/aicatalog"
	"dropocore/dnspolicy"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestWindowsServicePolicyAPIPersistsTheDisplayedChoices(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows desktop UI/API contract")
	}
	app := newInitializedSettingsScenarioApp(t)
	for _, method := range []string{FreeAccessMethodDirect, FreeAccessMethodVPN, FreeAccessMethodZapret} {
		requireAPISuccess(t, app.SetFreeAccessServiceMethod("youtube", method))
		if err := app.storage.Load(); err != nil {
			t.Fatal(err)
		}
		if got := FreeAccessServiceMethod(app.storage.GetAppSettings(), "youtube"); got != method {
			t.Fatalf("UI choice %q persisted as %q", method, got)
		}
	}
	requireAPISuccess(t, app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodAuto))
	if err := app.storage.Load(); err != nil {
		t.Fatal(err)
	}
	if got := FreeAccessServiceMethod(app.storage.GetAppSettings(), "youtube"); got != FreeAccessMethodAuto {
		t.Fatalf("saved automatic policy = %q", got)
	}
	requireAPISuccess(t, app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodZapret))
	requireAPISuccess(t, app.SetZapretServiceStrategy("youtube", ZapretStrategyModeAuto, ""))
	if got := FreeAccessServiceMethod(app.storage.GetAppSettings(), "youtube"); got != FreeAccessMethodZapret {
		t.Fatalf("strategy auto changed service policy to %q", got)
	}
}

func TestDefaultStorageSettingsMatchCurrentNetworkPolicy(t *testing.T) {
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}

	settings := storage.GetAppSettings()
	wantMode := RoutingModeBlockedOnly
	if runtime.GOOS == "windows" {
		wantMode = RoutingModeAllTraffic
	}
	if settings.RoutingMode != wantMode {
		t.Fatalf("fresh routing mode = %q, want %q", settings.RoutingMode, wantMode)
	}
	if settings.NetworkMode != NetworkModeWindowsUnified {
		t.Fatalf("default network mode = %q, want windows_unified", settings.NetworkMode)
	}
	if settings.DisableFreeAccess {
		t.Fatal("free methods must be allowed by default")
	}
	if !settings.FreeAccessEnabled {
		t.Fatal("free access state should remain enabled for legacy UI/API compatibility")
	}
	for _, svc := range DefaultFreeAccessServices {
		wantMethod := FreeAccessMethodDirect
		if svc.Tag == "youtube" || svc.Tag == "discord" || aicatalog.VPNOnly(svc.Tag) {
			wantMethod = FreeAccessMethodVPN
		}
		if got := settings.FreeAccessMethods[svc.Tag]; got != wantMethod {
			t.Fatalf("fresh route for %s = %q, want %q", svc.Tag, got, wantMethod)
		}
	}
	if !settings.Notifications {
		t.Fatal("notifications should be enabled by default")
	}
	if !settings.AutoUpdateSub {
		t.Fatal("subscription auto-update should be enabled by default")
	}
	if !settings.EnableLogging || settings.LogLevel != LogLevelInfo {
		t.Fatalf("logging defaults = enabled:%t level:%q, want enabled info", settings.EnableLogging, settings.LogLevel)
	}
	profile, err := storage.GetActiveProfile()
	if err != nil {
		t.Fatalf("get active profile failed: %v", err)
	}
	if profile.Name != DefaultProfileName {
		t.Fatalf("default profile name = %q, want %q", profile.Name, DefaultProfileName)
	}
}

func TestLegacyServiceDefaultsMigrateOnce(t *testing.T) {
	s := NewStorage(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatal(err)
	}
	s.data.Version = 7
	s.data.App.RoutingMode = RoutingModeBlockedOnly
	s.data.Profiles[0].SingboxConfig = map[string]interface{}{"outbounds": []interface{}{"legacy"}}
	s.data.App.FreeAccessMethods = map[string]string{"youtube": "auto", "meta": "vpn", "telegram": "auto", "twitch": "direct"}
	s.normalizeAppSettings()
	for tag, want := range map[string]string{"youtube": "vpn", "discord": "vpn", "telegram": "direct", "meta": "vpn", "twitch": "direct", "claude": "vpn"} {
		if got := s.data.App.FreeAccessMethods[tag]; got != want {
			t.Fatalf("migrated %s = %q, want %q", tag, got, want)
		}
	}
	if s.data.Profiles[0].SingboxConfig != nil {
		t.Fatal("the cached configuration still contains the old service selectors")
	}
	s.data.App.FreeAccessMethods["discord"] = "auto"
	s.normalizeAppSettings()
	if s.data.App.FreeAccessMethods["discord"] != "auto" {
		t.Fatal("new explicit automatic choice was overwritten")
	}
}

func TestWindowsServiceRouteOptionsInSelectionOrder(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows route controls are platform specific")
	}
	options := FreeAccessServiceMethodOptions()
	want := []struct {
		tag   string
		label string
	}{
		{FreeAccessMethodVPN, "Через VPN"},
		{FreeAccessMethodZapret, "Обход (Zapret)"},
		{FreeAccessMethodDirect, "Напрямую"},
		{FreeAccessMethodAuto, "Авто"},
	}
	if len(options) != len(want) {
		t.Fatalf("route options = %#v, want the supported choices", options)
	}
	for index, expected := range want {
		if options[index]["tag"] != expected.tag || options[index]["value"] != expected.tag || options[index]["label"] != expected.label {
			t.Fatalf("route option %d = %#v, want tag/value %q label %q", index, options[index], expected.tag, expected.label)
		}
	}
}

func TestSettingsAPIsMigrateLegacyRoutingAndPersistNetworkMode(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)

	result := app.SetRoutingMode(string(RoutingModeExceptRussia))
	requireAPISuccess(t, result)
	settings := app.storage.GetAppSettings()
	if settings.RoutingMode != RoutingModeBlockedOnly {
		t.Fatalf("stored routing mode = %q, want legacy mode migrated to blocked_only", settings.RoutingMode)
	}
	if app.configBuilder.GetRoutingMode() != RoutingModeBlockedOnly {
		t.Fatalf("builder routing mode = %q, want blocked_only", app.configBuilder.GetRoutingMode())
	}

	configPath := writeActiveScenarioConfig(t, app)
	plan := app.buildDeepWindowsRoutePlan(configPath)
	if plan.RUTraffic != DeepWindowsTrafficDirect || plan.ForeignTraffic != DeepWindowsTrafficDirect || plan.DefaultTraffic != DeepWindowsTrafficDirect {
		t.Fatalf("migrated plan ru/foreign/default = %s/%s/%s, want direct/direct/direct", plan.RUTraffic, plan.ForeignTraffic, plan.DefaultTraffic)
	}

	networkResult := app.SetNetworkMode(string(NetworkModeCompatTun))
	requireAPISuccess(t, networkResult)
	settings = app.storage.GetAppSettings()
	if settings.NetworkMode != NetworkModeWindowsUnified {
		t.Fatalf("stored network mode = %q, want legacy request migrated to windows_unified", settings.NetworkMode)
	}
	status := networkResult["status"].(map[string]interface{})
	active := status["active"].(string)
	if active != string(NetworkModeWindowsUnified) {
		t.Fatalf("active network mode = %q, want Windows Unified", active)
	}

	invalidResult := app.SetRoutingMode("bad-mode")
	if success, _ := invalidResult["success"].(bool); success {
		t.Fatalf("invalid routing mode unexpectedly succeeded: %+v", invalidResult)
	}
}

func TestSettingsAPIEnablesExplicitAllTrafficMode(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	if result := app.SetRoutingMode(string(RoutingModeAllTraffic)); result["success"] != true || result["sourceRequired"] != true {
		t.Fatalf("full VPN preference without a source was not saved as unready: %+v", result)
	}
	if got := app.storage.GetAppSettings().RoutingMode; got != RoutingModeAllTraffic {
		t.Fatalf("full VPN preference persisted routing mode %q", got)
	}
	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	source, err := newVPNSource("source-1", "Test VPN", "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#test")
	if err != nil {
		t.Fatal(err)
	}
	requireAPISuccess(t, app.AddVPNSource(source.Name, source.URI))

	result := app.SetRoutingMode(string(RoutingModeAllTraffic))
	requireAPISuccess(t, result)
	if restarted, _ := result["restarted"].(bool); restarted {
		t.Fatal("stopped VPN must not be reported as restarted")
	}
	settings := app.storage.GetAppSettings()
	if settings.RoutingMode != RoutingModeAllTraffic {
		t.Fatalf("stored routing mode = %q, want all_traffic", settings.RoutingMode)
	}
	if app.configBuilder.GetRoutingMode() != RoutingModeAllTraffic {
		t.Fatalf("builder routing mode = %q, want all_traffic", app.configBuilder.GetRoutingMode())
	}
	config, err := app.storage.GetProfileConfig(profile.ID)
	if err != nil {
		t.Fatal(err)
	}
	outbounds, _ := config["outbounds"].([]interface{})
	selector := configOutboundByTag(outbounds, "proxy")
	if selector == nil {
		t.Fatal("full VPN config has no proxy selector")
	}
	choices := interfaceStringSlice(selector["outbounds"])
	if stringSliceContains(choices, "direct") || !stringSliceContains(choices, "auto-select") {
		t.Fatalf("full VPN selector choices = %v, want VPN sources without direct", choices)
	}
	dns, _ := config["dns"].(map[string]interface{})
	if dns["final"] != "dns-direct" {
		t.Fatalf("full VPN DNS final = %v, want dns-direct", dns["final"])
	}
	remoteDNSFound := false
	for _, raw := range dns["servers"].([]interface{}) {
		server, _ := raw.(map[string]interface{})
		if server["tag"] == "dns-remote" {
			remoteDNSFound = true
			if server["type"] != "https" || server["detour"] != "proxy" {
				t.Fatalf("full VPN remote DNS does not use proxy DoH: %#v", server)
			}
		}
	}
	if !remoteDNSFound {
		t.Fatal("full VPN remote DNS server is missing")
	}
	if !containsDNSDomainSuffixServer(config, "vk.com", "dns-direct") || !containsDNSDomainSuffixServer(config, "claude.ai", "dns-remote") {
		t.Fatal("catalog and ordinary DNS must follow different paths")
	}
	route, _ := config["route"].(map[string]interface{})
	bootstrap, _ := route["default_domain_resolver"].(map[string]interface{})
	if bootstrap["server"] != "dns-direct" {
		t.Fatalf("VPN endpoint bootstrap DNS = %v, want dns-direct", bootstrap)
	}
	experimental, _ := config["experimental"].(map[string]interface{})
	cacheFile, _ := experimental["cache_file"].(map[string]interface{})
	if cacheFile["path"] != "cache-catalog-vpn-v2.db" {
		t.Fatalf("full VPN cache path = %v, want isolated selector cache", cacheFile["path"])
	}
	if configNeedsAllTrafficTunnelMigration(config, RoutingModeAllTraffic) {
		t.Fatal("new full VPN config was classified as stale")
	}
	selector["outbounds"] = append(choices, "direct")
	if !configNeedsAllTrafficTunnelMigration(config, RoutingModeAllTraffic) {
		t.Fatal("cached direct selector choice was not classified as stale")
	}
	if err := app.storage.UpdateProfileConfig(profile.ID, config); err != nil {
		t.Fatal(err)
	}
	if err := app.ensureActiveConfigForStart(); err != nil {
		t.Fatalf("rebuild stale full VPN config: %v", err)
	}
	rebuilt, err := app.storage.GetProfileConfig(profile.ID)
	if err != nil {
		t.Fatal(err)
	}
	if configNeedsAllTrafficTunnelMigration(rebuilt, RoutingModeAllTraffic) {
		t.Fatal("Start retained a cached direct choice in full VPN config")
	}
}

func TestFullVPNRequiresEnabledSupportedSource(t *testing.T) {
	valid := "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#test"
	cases := []struct {
		name      string
		sources   []VPNSource
		legacyURL string
		want      bool
	}{
		{name: "none"},
		{name: "disabled", sources: []VPNSource{{URI: valid, Disabled: true}}},
		{name: "invalid direct link", sources: []VPNSource{{URI: "vless://invalid"}}},
		{name: "unsupported transport", sources: []VPNSource{{URI: "vless://00000000-0000-0000-0000-000000000000@example.com:443?type=kcp#test"}}},
		{name: "valid direct link", sources: []VPNSource{{URI: valid}}, want: true},
		{name: "valid subscription", sources: []VPNSource{{URI: "https://example.com/sub"}}, want: true},
		{name: "legacy subscription field", legacyURL: "https://example.com/sub", want: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := hasConfiguredVPNSource(&ProfileData{VPNSources: tc.sources, SubscriptionURL: tc.legacyURL}); got != tc.want {
				t.Fatalf("configured VPN source = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPersistedFullVPNWithoutSourceCannotStartOrBuildDirectFallback(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	settings := app.storage.GetAppSettings()
	settings.RoutingMode = RoutingModeAllTraffic
	if err := app.storage.UpdateAppSettings(settings); err != nil {
		t.Fatal(err)
	}
	if err := app.ensureActiveConfigForStart(); err == nil || !strings.Contains(err.Error(), "VPN-источник") {
		t.Fatalf("cached config bypassed full VPN source gate: %v", err)
	}
	app.configBuilder.SetRoutingMode(RoutingModeAllTraffic)
	if err := app.configBuilder.BuildConfig(""); err == nil || !strings.Contains(err.Error(), "VPN-источник") {
		t.Fatalf("builder accepted direct-only full VPN: %v", err)
	}
}

func TestWindowsExplicitDialResolverUsesVerifiedRegionalTransport(t *testing.T) {
	for _, tag := range []string{"dns-direct", "dns-remote"} {
		primary := dnspolicy.Server(tag, tag == "dns-remote")
		config := map[string]any{
			"route": map[string]any{"default_domain_resolver": map[string]any{"server": tag, "strategy": "ipv4_only"}},
			"dns":   map[string]any{"servers": []any{primary}, "final": tag, "rules": []any{map[string]any{"domain_suffix": []any{"corp.example"}, "server": "wg-dns"}}},
		}
		stored := cloneJSONMap(config)
		runtime := windowsDialResolverConfig(stored)
		resolver := runtime["route"].(map[string]any)["default_domain_resolver"].(map[string]any)
		dns := runtime["dns"].(map[string]any)
		if resolver["server"] != tag+"-fi" || resolver["strategy"] != "ipv4_only" || len(dns["servers"].([]any)) != 2 {
			t.Fatal("cached configuration did not acquire a regional dial resolver")
		}
		reserve := dns["servers"].([]any)[1].(map[string]any)
		if reserve["server"] != dnspolicy.FinlandIPv4 || reserve["tls"].(map[string]any)["server_name"] != dnspolicy.FinlandHostname || reserve["detour"] != primary["detour"] {
			t.Fatal("explicit resolver changed DNS identity or detour")
		}
		if !reflect.DeepEqual(stored, cloneJSONMap(config)) || !reflect.DeepEqual(dns["rules"], stored["dns"].(map[string]any)["rules"]) {
			t.Fatal("cached settings or private DNS rules changed")
		}
		// The runtime also accepts already persisted numeric ports (float64).
		roundTrip := cloneJSONMap(runtime)
		roundTrip["route"] = stored["route"]
		if got := windowsDialResolverConfig(roundTrip)["route"].(map[string]any)["default_domain_resolver"].(map[string]any)["server"]; got != tag+"-fi" {
			t.Fatal("existing regional resolver was ignored")
		}
		roundTrip["dns"].(map[string]any)["servers"].([]any)[1].(map[string]any)["detour"] = "corporate"
		if got := windowsDialResolverConfig(roundTrip)["route"].(map[string]any)["default_domain_resolver"].(map[string]any)["server"]; got != tag {
			t.Fatal("custom resolver was hijacked")
		}
	}
}

func TestAllTrafficDNSPreservesWorkNetworkResolver(t *testing.T) {
	template := map[string]interface{}{
		"dns": map[string]interface{}{
			"servers": []interface{}{
				map[string]interface{}{"type": "udp", "tag": "dns-remote", "server": "8.8.8.8"},
				map[string]interface{}{"type": "udp", "tag": "dns-direct", "server": "77.88.8.8"},
				map[string]interface{}{"type": "udp", "tag": "wg-dns", "server": "10.0.0.53"},
			},
			"rules": []interface{}{
				map[string]interface{}{"domain_suffix": []string{"corp.example"}, "server": "wg-dns"},
				map[string]interface{}{"domain_suffix": []string{"ru"}, "server": "dns-direct"},
			},
		},
		"route": map[string]interface{}{},
	}
	builder := &ConfigBuilderForStorage{routingMode: RoutingModeAllTraffic}
	builder.applyDNSRouting(template, GlobalAppSettings{}, true)
	dns := template["dns"].(map[string]interface{})
	rules := dns["rules"].([]interface{})
	if len(rules) < 3 || rules[0].(map[string]interface{})["server"] != "wg-dns" || rules[1].(map[string]interface{})["server"] != "dns-local" || dns["final"] != "dns-direct" {
		t.Fatal("catalog VPN lost local/work DNS priority")
	}
	for _, tag := range []string{"dns-remote-fi", "dns-remote", "dns-remote-lv"} {
		if !containsDNSDomainSuffixServer(template, "claude.ai", tag) {
			t.Fatalf("missing protected Claude DNS %s", tag)
		}
	}
}

func TestGeneratedRoutingPreservesWireGuardOverlayAcrossModes(t *testing.T) {
	modes := []RoutingMode{RoutingModeBlockedOnly, RoutingModeExceptRussia, RoutingModeAllTraffic}
	for _, mode := range modes {
		t.Run(string(mode), func(t *testing.T) {
			app := newInitializedSettingsScenarioApp(t)
			profile, err := app.storage.GetActiveProfile()
			if err != nil {
				t.Fatal(err)
			}
			source, err := newVPNSource("source-1", "Test VPN", "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#test")
			if err != nil {
				t.Fatal(err)
			}
			workNetwork := UserWireGuardConfig{
				Tag:               "work",
				DNS:               "10.60.0.53",
				AllowedIPs:        []string{"198.51.100.0/24", "10.60.0.0/16"},
				Endpoint:          "wg.corp.example",
				EndpointPort:      51820,
				CamouflageEnabled: true,
			}
			if err := app.storage.UpdateProfileVPNSources(profile.ID, []VPNSource{source}, []UserWireGuardConfig{workNetwork}); err != nil {
				t.Fatal(err)
			}
			settings := app.storage.GetAppSettings()
			settings.RoutingMode = mode
			if err := app.storage.UpdateAppSettings(settings); err != nil {
				t.Fatal(err)
			}
			app.configBuilder.SetRoutingMode(mode)
			if err := app.configBuilder.BuildConfigForProfileSources(profile.ID, []VPNSource{source}, []UserWireGuardConfig{workNetwork}); err != nil {
				t.Fatalf("build %s config: %v", mode, err)
			}

			config, err := app.storage.GetProfileConfig(profile.ID)
			if err != nil {
				t.Fatal(err)
			}
			route, _ := config["route"].(map[string]interface{})
			rules, _ := route["rules"].([]interface{})
			workRuleIndex := -1
			privateRuleIndex := -1
			for index, raw := range rules {
				rule, _ := raw.(map[string]interface{})
				cidrs := interfaceStringSlice(rule["ip_cidr"])
				if rule["outbound"] == "direct" && stringSliceContains(cidrs, "198.51.100.0/24") && stringSliceContains(cidrs, "10.60.0.0/16") {
					workRuleIndex = index
				}
				if private, _ := rule["ip_is_private"].(bool); private {
					privateRuleIndex = index
				}
			}
			if workRuleIndex < 0 {
				t.Fatalf("%s config lost the WireGuard public/private AllowedIPs rule: %#v", mode, rules)
			}
			if privateRuleIndex < 0 || workRuleIndex >= privateRuleIndex {
				t.Fatalf("%s WireGuard rule index = %d, generic private rule index = %d; work overlay must win", mode, workRuleIndex, privateRuleIndex)
			}
			if mode == RoutingModeAllTraffic && route["final"] != "direct" {
				t.Fatalf("all-traffic final = %v, want direct after the work-network exception", route["final"])
			}

			dns, _ := config["dns"].(map[string]interface{})
			workDNSFound := false
			for _, raw := range dns["servers"].([]interface{}) {
				server, _ := raw.(map[string]interface{})
				if server["tag"] == "dns-work" && server["server"] == workNetwork.DNS {
					workDNSFound = true
					break
				}
			}
			if !workDNSFound {
				t.Fatalf("%s config lost the WireGuard DNS server", mode)
			}
			workDNSRuleFound := false
			for _, raw := range dns["rules"].([]interface{}) {
				rule, _ := raw.(map[string]interface{})
				if rule["server"] == "dns-work" && stringSliceContains(interfaceStringSlice(rule["domain_suffix"]), "corp.example") {
					workDNSRuleFound = true
					break
				}
			}
			if !workDNSRuleFound {
				t.Fatalf("%s config lost the WireGuard DNS rule", mode)
			}
			if runtime.GOOS == "windows" && !app.wireGuardCamouflageRequested() {
				t.Fatalf("%s config update lost the WireGuard camouflage request", mode)
			}
		})
	}
}

func TestFullVPNGeneratedConfigPassesBundledSingBoxCheck(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("bundled sing-box check uses the Windows binary")
	}
	matches, err := filepath.Glob(filepath.Join("..", "dependencies", "sing-box-v"+SingBoxVersion, "windows-amd64", "sing-box-*", "sing-box.exe"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) == 0 {
		t.Skip("bundled sing-box is absent")
	}
	app := newInitializedSettingsScenarioApp(t)
	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	source, err := newVPNSource("source-1", "Offline fixture", "vless://00000000-0000-0000-0000-000000000000@203.0.113.10:443?security=tls#offline")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.storage.UpdateProfileVPNSources(profile.ID, []VPNSource{source}, nil); err != nil {
		t.Fatal(err)
	}
	requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeAllTraffic)))
	configPath, err := app.storage.WriteActiveConfigToFile()
	if err != nil {
		t.Fatal(err)
	}
	if output, err := newBackgroundCommand(matches[0], "check", "-c", configPath).CombinedOutput(); err != nil {
		t.Fatalf("bundled sing-box rejected generated full-VPN config: %v\n%s", err, output)
	}
}

func TestSettingsAPIsPersistFreeAccessPolicy(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	if runtime.GOOS == "windows" {
		requireAPISuccess(t, app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodZapret))
		for _, tag := range []string{"discord", "meta", "openai"} {
			requireAPISuccess(t, app.SetFreeAccessServiceMethod(tag, FreeAccessMethodVPN))
		}
	}

	result := app.SetDisableFreeAccess(true)
	requireAPISuccess(t, result)
	settings := app.storage.GetAppSettings()
	if !settings.DisableFreeAccess || !settings.FreeAccessEnabled || settings.FreeAccessReverse {
		t.Fatalf("free access settings = disable:%t enabled:%t reverse:%t, want disable=true enabled=true reverse=false",
			settings.DisableFreeAccess, settings.FreeAccessEnabled, settings.FreeAccessReverse)
	}
	plan := buildDeepWindowsRoutePlanForSettings(settings, true, true, true)
	if runtime.GOOS == "windows" {
		if !planContainsString(plan.TransparentServices, "youtube") || !planContainsString(plan.ProxyServices, "discord") ||
			!planContainsString(plan.ProxyServices, "meta") || !planContainsString(plan.ProxyServices, "openai") {
			t.Fatalf("disable-free plan = %+v, want explicit release routes preserved", plan)
		}
	} else if !planContainsString(plan.ProxyServices, "youtube") || len(plan.TransparentServices) != 0 {
		t.Fatalf("disable-free plan = %+v, want default YouTube VPN route", plan)
	}

	result = app.SetDisableFreeAccess(false)
	requireAPISuccess(t, result)
	if runtime.GOOS == "windows" {
		result = app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodZapret)
		requireAPISuccess(t, result)
		settings = app.storage.GetAppSettings()
		if got := FreeAccessServiceMethod(settings, "youtube"); got != FreeAccessMethodZapret {
			t.Fatalf("YouTube route policy = %q, want strict zapret", got)
		}
		plan = buildDeepWindowsRoutePlanForSettings(settings, true, true, true)
		if !planContainsString(plan.TransparentServices, "youtube") || planContainsString(plan.ProxyServices, "youtube") {
			t.Fatalf("strict YouTube zapret plan = %+v, want transparent without VPN fallback", plan)
		}
		manualStrategy := rankedMethodsForService("youtube")[1]
		result = app.SetZapretServiceStrategy("youtube", ZapretStrategyModeManual, manualStrategy.Tag)
		requireAPISuccess(t, result)
		settings = app.storage.GetAppSettings()
		if mode := ZapretStrategyMode(settings, "youtube"); mode != ZapretStrategyModeManual {
			t.Fatalf("YouTube Zapret strategy mode = %q, want manual", mode)
		}
		if selected, ok := ZapretManualStrategy(settings, "youtube"); !ok || selected.Tag != manualStrategy.Tag {
			t.Fatalf("YouTube manual strategy = %#v/%t, want %q", selected, ok, manualStrategy.Tag)
		}
		result = app.SetZapretServiceStrategy("youtube", ZapretStrategyModeAuto, "")
		requireAPISuccess(t, result)
		settings = app.storage.GetAppSettings()
		if mode := ZapretStrategyMode(settings, "youtube"); mode != ZapretStrategyModeAuto {
			t.Fatalf("YouTube Zapret strategy mode = %q, want auto", mode)
		}
		result = app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodDirect)
		requireAPISuccess(t, result)

		unsupported := app.SetFreeAccessServiceMethod("telegram", FreeAccessMethodZapret)
		if success, _ := unsupported["success"].(bool); success {
			t.Fatalf("unsupported strict Telegram zapret unexpectedly succeeded: %+v", unsupported)
		}
	}
	result = app.SetFreeAccessServiceMethod("telegram", "subscription")
	requireAPISuccess(t, result)
	settings = app.storage.GetAppSettings()
	if got := settings.FreeAccessMethods["telegram"]; got != FreeAccessMethodVPN {
		t.Fatalf("telegram method = %q, want vpn alias normalization", got)
	}
	plan = buildDeepWindowsRoutePlanForSettings(settings, false, true, true)
	if !planContainsString(plan.BlockedServices, "telegram") {
		t.Fatalf("forced-vpn-without-candidate plan = %+v, want telegram blocked", plan)
	}

	if runtime.GOOS == "windows" {
		result = app.SetFreeAccessServiceMethod("telegram", DefaultZapretTransparentStrategies[0].Tag)
		requireAPISuccess(t, result)
		settings = app.storage.GetAppSettings()
		plan = buildDeepWindowsRoutePlanForSettings(settings, true, true, true)
		if !planContainsString(plan.DirectServices, "telegram") || planContainsString(plan.TransparentServices, "telegram") {
			t.Fatalf("legacy manual zapret plan = %+v, want unsupported legacy method migrated to direct", plan)
		}
	}

	invalidResult := app.SetFreeAccessServiceMethod("unknown-service", FreeAccessMethodDirect)
	if success, _ := invalidResult["success"].(bool); success {
		t.Fatalf("invalid service method unexpectedly succeeded: %+v", invalidResult)
	}

	result = app.ToggleFreeAccessService("youtube", false)
	requireAPISuccess(t, result)
	settings = app.storage.GetAppSettings()
	if got := FreeAccessServiceMethod(settings, "youtube"); got != FreeAccessMethodDirect {
		t.Fatalf("legacy disabled YouTube method = %q, want explicit direct", got)
	}
	if candidates := FreeAccessServiceCandidateTagsForSettings(DefaultFreeAccessServices[1], settings, true); len(candidates) != 1 || candidates[0] != "direct" {
		t.Fatalf("legacy disabled YouTube candidates = %v, want direct", candidates)
	}
}

func TestAppSettingsMapsAreIsolatedAndFailedWritesRollback(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)

	detached := app.storage.GetAppSettings()
	detached.FreeAccessMethods["discord"] = FreeAccessMethodZapret
	detached.FreeAccessServices["youtube"] = false
	stored := app.storage.GetAppSettings()
	if stored.FreeAccessMethods["discord"] == FreeAccessMethodZapret || !FreeAccessServiceEnabled(stored, "youtube") {
		t.Fatal("GetAppSettings leaked mutable maps into storage")
	}

	detached = app.storage.GetAppSettings()
	detached.FreeAccessMethods["discord"] = FreeAccessMethodZapret
	if err := app.storage.UpdateAppSettings(detached); err != nil {
		t.Fatalf("update app settings failed: %v", err)
	}
	detached.FreeAccessMethods["discord"] = FreeAccessMethodDirect
	if got := app.storage.GetAppSettings().FreeAccessMethods["discord"]; got != FreeAccessMethodZapret {
		t.Fatalf("UpdateAppSettings retained caller map: got %q, want zapret", got)
	}

	beforeFailure := app.storage.GetAppSettings()
	updated := beforeFailure
	updated.Theme = ThemeLight
	originalPath := app.storage.settingsPath
	app.storage.settingsPath = t.TempDir()
	if err := app.storage.UpdateAppSettings(updated); err == nil {
		t.Fatal("UpdateAppSettings unexpectedly succeeded with a directory as settings path")
	}
	app.storage.settingsPath = originalPath
	if got := app.storage.GetAppSettings().Theme; got != beforeFailure.Theme {
		t.Fatalf("failed settings write changed in-memory state: got %q, want %q", got, beforeFailure.Theme)
	}
}

func TestServicePolicyAPIsRejectUnknownMethodsAndRollbackRebuildFailures(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)

	before := app.storage.GetAppSettings()
	result := app.SetFreeAccessServiceMethod("discord", "not-a-route")
	if success, _ := result["success"].(bool); success {
		t.Fatalf("unknown route method unexpectedly succeeded: %+v", result)
	}
	if got := app.storage.GetAppSettings().FreeAccessMethods["discord"]; got != before.FreeAccessMethods["discord"] {
		t.Fatalf("unknown method changed stored policy: got %q, want %q", got, before.FreeAccessMethods["discord"])
	}

	app.configBuilder = nil
	targetMethod := FreeAccessMethodVPN
	if FreeAccessServiceMethod(before, "discord") == targetMethod {
		targetMethod = FreeAccessMethodDirect
	}
	result = app.SetFreeAccessServiceMethod("discord", targetMethod)
	if success, _ := result["success"].(bool); success {
		t.Fatalf("service method unexpectedly survived rebuild failure: %+v", result)
	}
	afterMethodFailure := app.storage.GetAppSettings()
	if got := afterMethodFailure.FreeAccessMethods["discord"]; got != before.FreeAccessMethods["discord"] {
		t.Fatalf("service method rollback = %q, want %q", got, before.FreeAccessMethods["discord"])
	}

	wasEnabled := FreeAccessServiceEnabled(before, "youtube")
	result = app.ToggleFreeAccessService("youtube", !wasEnabled)
	if success, _ := result["success"].(bool); success {
		t.Fatalf("service toggle unexpectedly survived rebuild failure: %+v", result)
	}
	if got := FreeAccessServiceEnabled(app.storage.GetAppSettings(), "youtube"); got != wasEnabled {
		t.Fatalf("service toggle rollback = %t, want %t", got, wasEnabled)
	}
}

func TestSettingsAPIsPersistHideRuTrafficPolicy(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)

	result := app.SetHideRuTraffic(true, "")
	requireAPISuccess(t, result)
	settings := app.storage.GetAppSettings()
	if !settings.HideRuTraffic {
		t.Fatal("hide RU traffic setting was not stored")
	}
	configPath := writeActiveScenarioConfig(t, app)
	plan := app.buildDeepWindowsRoutePlan(configPath)
	if plan.RUTraffic != DeepWindowsTrafficProxy {
		t.Fatalf("RU traffic action = %s, want proxy when hide-RU is enabled", plan.RUTraffic)
	}
	if !plan.RequiresSingBoxProxy || !plan.RequiresRedirector {
		t.Fatalf("hide-RU plan should require local proxy endpoint under Deep Windows: %+v", plan)
	}
}

func newInitializedSettingsScenarioApp(t *testing.T) *App {
	t.Helper()

	app, _ := newDeepWindowsTestApp(t, map[string]interface{}{
		"inbounds": []interface{}{
			map[string]interface{}{"type": "tun", "tag": "tun-in", "auto_route": true},
			map[string]interface{}{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2088, "set_system_proxy": false},
		},
		"outbounds": []interface{}{
			map[string]interface{}{"type": "direct", "tag": "direct"},
		},
	})
	app.configBuilder = NewConfigBuilderForStorage(app.storage)
	app.logBuffer = make([]string, 0, MaxLogBufferSize)
	app.initialized = true
	app.initializedReady.Store(true)
	if err := app.configBuilder.BuildConfig(""); err != nil {
		t.Fatalf("initial config build failed: %v", err)
	}
	return app
}

func writeActiveScenarioConfig(t *testing.T, app *App) string {
	t.Helper()

	configPath, err := app.storage.WriteActiveConfigToFile()
	if err != nil {
		t.Fatalf("write active config failed: %v", err)
	}
	return configPath
}

func requireAPISuccess(t *testing.T, result map[string]interface{}) {
	t.Helper()

	success, _ := result["success"].(bool)
	if !success {
		t.Fatalf("API result failed: %+v", result)
	}
}
