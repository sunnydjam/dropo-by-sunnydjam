package main

import (
	"slices"
	"strings"
	"testing"

	traffic "dropo/trafficorchestrator"
	"dropocore/dnspolicy"
)

func TestGamePACMatchesExactAndWorkBoundaries(t *testing.T) {
	p := traffic.TrafficPlan{Services: []traffic.ServiceRule{{ID: "video", ExactHosts: []string{"one.test"}, DomainSuffixes: []string{"example.test"}}}, Routes: []traffic.ServiceRoute{{ServiceID: "video", Kind: traffic.ServiceRouteVPN}}, WorkNetworks: []traffic.WorkNetworkRule{{ID: "office", DomainSuffixes: []string{"office.example.test"}}}}
	d := selectiveDomainsForPlan(p)
	for host, want := range map[string]bool{"one.test": true, "child.one.test": false, "a.example.test": true, "office.example.test": false, "x.office.example.test": false} {
		if d.needsFake(host) != want {
			t.Errorf("fake DNS for %s", host)
		}
	}
	pac, _, err := buildSelectiveProxyPAC("127.0.0.1:32001", "", d)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(pac, "dnsDomainIs(host, \".\" + \"one.test\")") || strings.Index(pac, "office.example.test") < 0 || strings.Index(pac, "office.example.test") > strings.Index(pac, "PROXY") {
		t.Fatal(pac)
	}
}

func TestSplitResolversKeepWindowsNetworkAndCustomWorkDNS(t *testing.T) {
	custom := map[string]any{"type": "udp", "tag": "office", "server": "10.0.0.53"}
	dns := map[string]any{"servers": []any{dnspolicy.Server("dns-direct", false), dnspolicy.Server("dns-remote", false), custom}, "rules": []any{map[string]any{"domain_suffix": []string{"office.test"}, "action": "route", "server": "office"}}}
	config := map[string]any{"route": map[string]any{}, "dns": dns, "inbounds": []any{map[string]any{"type": "mixed", "tag": "mixed-in"}}}
	settings := GlobalAppSettings{RoutingMode: RoutingModeBlockedOnly, FreeAccessMethods: map[string]string{"youtube": "vpn"}}
	b := ConfigBuilderForStorage{routingMode: RoutingModeBlockedOnly}
	b.applyDNSRouting(config, settings, true)
	if dns["final"] != "dns-direct" {
		t.Fatal("wrong split default")
	}
	servers := dns["servers"].([]any)
	if servers[0].(map[string]any)["type"] != "local" {
		t.Fatal("ordinary DNS ignores system settings")
	}
	rules := dns["rules"].([]any)
	if rules[0].(map[string]any)["server"] != "office" {
		t.Fatal("private DNS lost precedence")
	}
	if !containsDNSDomainSuffixServer(config, "youtube.com", "dns-remote") {
		t.Fatal("selected service lost encrypted DNS")
	}
	for _, raw := range rules {
		r := raw.(map[string]any)
		if r["server"] == "dns-direct-fi" || r["server"] == "dns-direct-lv" {
			t.Fatal("regional lookup for direct DNS")
		}
	}
}

func TestSharedHostingParentsCannotBecomeBlockedDomainSuffixes(t *testing.T) {
	input := []string{"pages.dev", "site.pages.dev", "workers.dev", "site.workers.dev", "cloudflare-ech.com"}
	if got := excludeNamedServiceDomains(input); !slices.Equal(got, []string{"site.pages.dev", "site.workers.dev"}) {
		t.Fatalf("unexpected effective blocked domains %v", got)
	}
}

// Use the actual service catalog with every service selected as an upper-bound
// classification workload. Excludes socket attribution and network I/O.
func BenchmarkGameClassification(b *testing.B) {
	plan := traffic.TrafficPlan{Revision: 1, CatalogRevision: traffic.BuiltinCatalogRevision,
		DirectRules: []traffic.DirectRule{{ID: "latency-sensitive-direct", DomainSuffixes: DirectDomainSuffixes, IPCIDRs: DirectIPCIDRs, ProcessNames: DirectProcessNames}}}
	for _, svc := range DefaultFreeAccessServices {
		plan.Services = append(plan.Services, nativeServiceRule(svc, nil))
		plan.Routes = append(plan.Routes, traffic.ServiceRoute{ServiceID: svc.Tag, Kind: traffic.ServiceRouteVPN})
	}
	classifier, err := traffic.NewClassifier(plan)
	if err != nil {
		b.Fatal(err)
	}
	for _, flow := range []traffic.FlowEvidence{
		{Host: "cdn.game.test", ProcessName: "game.exe", Network: traffic.NetworkUDP, Port: 50005, Destination: "104.18.0.1"},
		{Host: "cdn.game.test", ProcessName: "game.exe", Network: traffic.NetworkUDP, Port: 50005, Destination: "2606:4700::1"},
		{Host: "gateway.discord.com", ProcessName: "Discord.exe", Network: traffic.NetworkTCP, Port: 443, Destination: "66.22.200.1"},
	} {
		b.Run(flow.Host+"_"+flow.Destination, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				classifier.Classify(flow)
			}
		})
	}
}
