package main

import (
	"strings"
	"testing"

	traffic "dropo/trafficorchestrator"
)

func TestNativeSelectiveCaptureCatalogIsBounded(t *testing.T) {
	catalog := nativeSelectiveCaptureCatalog()
	filter, err := traffic.BuildSelectiveWinDivertFilter(catalog, 32000)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(filter, "udp.DstPort == 53") || !strings.Contains(filter, "198.18.0.0") || !strings.Contains(filter, "66.22.192.0") || !strings.Contains(filter, "udp.DstPort >= 50000") {
		t.Fatalf("selective filter is missing DNS, fake-IP or Discord scope: %s", filter)
	}
	for _, forbidden := range []string{"steam", "27015", "udp.PayloadLength > 0", "tcp.DstPort > 0", "udp.DstPort == 853"} {
		if strings.Contains(strings.ToLower(filter), forbidden) {
			t.Fatalf("selective filter contains broad/game token %q", forbidden)
		}
	}
	discordFound := false
	for _, rule := range catalog {
		if rule.ID == "discord" {
			discordFound = true
			if len(rule.UDPPorts) != 0 || len(rule.ProcessDiscoveryUDPPortRanges) != 2 || rule.ProcessMatchPolicy != traffic.ProcessMatchIdentity || rule.IPMatchPolicy != traffic.IPMatchRequireContext {
				t.Fatalf("Discord capture rule is not process-scoped dynamic UDP: %+v", rule)
			}
		}
	}
	if !discordFound {
		t.Fatal("Discord is missing from the selective capture catalog")
	}
}

func TestNativeVPNOnlyCaptureLeavesUnrelatedHandshakesInKernel(t *testing.T) {
	filter, err := traffic.BuildSelectiveWinDivertFilterForMode(nativeSelectiveCaptureCatalog(), 32000, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"udp.DstPort == 53", "198.18.0.0", "66.22.192.0", "tcp.SrcPort == 32000", "tcp.DstPort == 443", "udp.DstPort >= 19294", "udp.DstPort <= 19344", "udp.DstPort >= 50000", "udp.DstPort <= 50100"} {
		if !strings.Contains(filter, required) {
			t.Fatalf("VPN-only filter is missing %q: %s", required, filter)
		}
	}
	for _, forbidden := range []string{"tcp.Payload", "udp.PayloadLength", "tcp.PayloadLength", "tcp.Syn", "!tcp.Ack"} {
		if strings.Contains(filter, forbidden) {
			t.Fatalf("VPN-only filter captures unrelated protocol evidence %q: %s", forbidden, filter)
		}
	}
}

func TestNativeSelectiveCaptureCatalogUsesOnlyNonDirectPolicies(t *testing.T) {
	settings := GlobalAppSettings{FreeAccessMethods: DefaultFreeAccessServiceMethodState()}
	if catalog := nativeSelectiveCaptureCatalogForSettings(settings); len(catalog) != 0 {
		t.Fatalf("all-direct settings produced capture services: %+v", catalog)
	}

	settings.FreeAccessMethods["youtube"] = FreeAccessMethodZapret
	catalog := nativeSelectiveCaptureCatalogForSettings(settings)
	if len(catalog) != 1 || catalog[0].ID != "youtube" {
		t.Fatalf("YouTube-only Zapret catalog = %+v", catalog)
	}
	if len(catalog[0].ProcessDiscoveryUDPPortRanges) != 0 {
		t.Fatalf("YouTube unexpectedly enabled UDP process discovery: %+v", catalog[0])
	}

	settings.FreeAccessMethods["discord"] = FreeAccessMethodVPN
	catalog = nativeSelectiveCaptureCatalogForSettings(settings)
	discordFound := false
	for _, rule := range catalog {
		if rule.ID != "discord" {
			continue
		}
		discordFound = true
		if len(rule.ProcessDiscoveryUDPPortRanges) != 2 || rule.ProcessDiscoveryUDPPortRanges[1].Last != 50100 {
			t.Fatalf("Discord discovery range = %+v", rule.ProcessDiscoveryUDPPortRanges)
		}
	}
	if !discordFound {
		t.Fatalf("Discord VPN policy is absent from capture catalog: %+v", catalog)
	}
}

func TestNativeCriticalAppsHaveExactBootstrapScope(t *testing.T) {
	wanted := map[string]struct {
		host    string
		process string
	}{
		"discord": {host: "updates.discord.com", process: "Discord.exe"},
		"openai":  {host: "ab.chatgpt.com", process: "ChatGPT.exe"},
	}
	for _, service := range DefaultFreeAccessServices {
		expected, ok := wanted[service.Tag]
		if !ok {
			continue
		}
		if !containsStringValue(service.ExactHosts, expected.host) {
			t.Fatalf("service %s is missing exact bootstrap host %s", service.Tag, expected.host)
		}
		if !containsStringValue(service.ProcessNames, expected.process) {
			t.Fatalf("service %s is missing native process %s", service.Tag, expected.process)
		}
		delete(wanted, service.Tag)
	}
	if len(wanted) != 0 {
		t.Fatalf("critical services are missing: %v", wanted)
	}
}

func TestNativeTrafficManagerSessionModeCanChangeOnlyWhileStopped(t *testing.T) {
	manager := NewNativeTrafficManager(t.TempDir(), nil)
	if err := manager.ConfigureSelectiveSession("127.0.0.1:2088", nativeSelectiveCaptureCatalog(), false); err != nil {
		t.Fatal(err)
	}
	if manager.selective == nil || manager.selective.proxyAddress != "127.0.0.1:2088" {
		t.Fatalf("selective session = %+v", manager.selective)
	}
	if manager.selective.captureProtocolEvidence {
		t.Fatal("VPN-only selective session retained global protocol capture")
	}
	if err := manager.ConfigureTUNSession(); err != nil {
		t.Fatal(err)
	}
	if manager.selective != nil {
		t.Fatal("TUN session retained selective configuration")
	}
}

func TestSelectivePlanScopeAllowsStrategyOnlyRevision(t *testing.T) {
	previous := traffic.TrafficPlan{
		Services: []traffic.ServiceRule{{ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.com"}, CandidateStrategyIDs: []string{"one", "two"}}},
		Routes:   []traffic.ServiceRoute{{ServiceID: "discord", Kind: traffic.ServiceRouteZapret}},
	}
	next := cloneTrafficPlan(previous)
	next.Services[0].CandidateStrategyIDs = []string{"two", "one"}
	if !sameSelectivePlanScope(previous, next) {
		t.Fatal("candidate rotation changed selective capture scope")
	}
	next.Routes[0].Kind = traffic.ServiceRouteVPN
	if !sameSelectivePlanScope(previous, next) {
		t.Fatal("typed route change unnecessarily changed the immutable capture scope")
	}
	if sameSelectiveRoutingOverlay(previous, next) {
		t.Fatal("typed VPN route change did not require a DNS/PAC overlay update")
	}
	next = cloneTrafficPlan(previous)
	next.Selections = []traffic.ServiceSelection{{ServiceID: "discord", StrategyID: "two"}}
	previous.Selections = []traffic.ServiceSelection{{ServiceID: "discord", StrategyID: "one"}}
	if !sameSelectiveRoutingOverlay(previous, next) {
		t.Fatal("strategy-only revision unnecessarily changed the DNS/PAC overlay")
	}
}
