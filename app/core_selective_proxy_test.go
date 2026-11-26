package main

import (
	traffic "dropo/trafficorchestrator"
	"strings"
	"testing"
)

func TestSelectiveProxyPACRoutesOnlySelectedDomains(t *testing.T) {
	script, domains, err := buildSelectiveProxyPAC(
		"127.0.0.1:2088", "127.0.0.1:2089",
		selectiveDomainPlan{
			vpn:    selectiveDomains{suffix: map[string]struct{}{"chatgpt.com": {}}},
			zapret: selectiveDomains{suffix: map[string]struct{}{"youtube.com": {}, "discord.com": {}}},
			direct: selectiveDomains{suffix: map[string]struct{}{"steamcommunity.com": {}, "steamstatic.com": {}}},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(domains) != 3 || domains[0] != "chatgpt.com" || domains[1] != "discord.com" || domains[2] != "youtube.com" {
		t.Fatalf("ordered PAC domains = %v", domains)
	}
	for _, required := range []string{"host === \"youtube.com\"", "dnsDomainIs(host, \".\" + \"discord.com\")", "host === \"steamcommunity.com\"", "host === \"steamstatic.com\"", "PROXY 127.0.0.1:2088", "PROXY 127.0.0.1:2089", "https:", "return \"DIRECT\""} {
		if !strings.Contains(script, required) {
			t.Fatalf("PAC script is missing %q:\n%s", required, script)
		}
	}
	if strings.Index(script, "steamcommunity.com") > strings.Index(script, "PROXY 127.0.0.1:2088") {
		t.Fatal("explicit direct rule must precede selected VPN rules")
	}
	if strings.Index(script, "steamstatic.com") > strings.Index(script, "PROXY 127.0.0.1:2088") {
		t.Fatal("Steam CDN direct rule must precede selected VPN rules")
	}
	if strings.Index(script, "steamcommunity.com") > strings.Index(script, "PROXY 127.0.0.1:2089") {
		t.Fatal("explicit direct rule must precede selected Zapret rules")
	}
	for _, forbidden := range []string{"mistfall", "dnsResolve", "isInNet"} {
		if strings.Contains(strings.ToLower(script), forbidden) {
			t.Fatalf("PAC script contains broad/unwanted token %q", forbidden)
		}
	}
}

func TestProtectedDomainOverridesUserDirectAndCannotEnterZapret(t *testing.T) {
	service := traffic.ServiceRule{ID: "claude", DisplayName: "Claude", VPNOnly: true, DomainSuffixes: []string{"claude.ai"}}
	for _, kind := range []traffic.ServiceRouteKind{traffic.ServiceRouteVPN, traffic.ServiceRouteUnavailable} {
		plan := traffic.TrafficPlan{Revision: 1, CatalogRevision: traffic.BuiltinCatalogRevision, Services: []traffic.ServiceRule{service}, Routes: []traffic.ServiceRoute{{ServiceID: "claude", Kind: kind}}, DirectRules: []traffic.DirectRule{{ID: "legacy", DomainSuffixes: []string{"claude.ai"}}}}
		names := selectiveDomainsForPlan(plan)
		if !names.needsFake("api.claude.ai") || names.needsFake("vk.com") {
			t.Fatal("incorrect DNS classification")
		}
		script, _, err := buildSelectiveProxyPAC("127.0.0.1:1080", "127.0.0.1:2080", names)
		if err != nil {
			t.Fatal(err)
		}
		terminal := "127.0.0.1:1080"
		if kind == traffic.ServiceRouteUnavailable {
			terminal = "127.0.0.1:2080"
		}
		if at := strings.Index(script, "PROXY "+terminal); at < 0 || at > strings.Index(script, "return \"DIRECT\"") {
			t.Fatalf("Direct precedes protected route: %s", script)
		}
		scope, err := compileZapretConnectScope(plan)
		if err != nil || scope.allows("api.claude.ai", 443) {
			t.Fatalf("unexpected CONNECT scope: %v", err)
		}
	}
}
