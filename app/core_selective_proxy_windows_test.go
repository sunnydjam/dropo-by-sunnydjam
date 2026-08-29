//go:build windows

package main

import (
	"testing"

	traffic "dropo/trafficorchestrator"
)

func TestSelectivePACUnchangedPlanKeepsOneURL(t *testing.T) {
	plan := traffic.TrafficPlan{
		Revision: 1,
		Services: []traffic.ServiceRule{{
			ID: "youtube", DisplayName: "YouTube", DomainSuffixes: []string{"youtube.com"},
			CandidateStrategyIDs: []string{"unused"}, AllowVPNFallback: true,
		}},
		Routes: []traffic.ServiceRoute{{ServiceID: "youtube", Kind: traffic.ServiceRouteVPN}},
	}
	script, domains, err := buildSelectiveProxyPAC("127.0.0.1:2088", "127.0.0.1:2089", selectedVPNDomainSuffixes(plan), selectedZapretDomainSuffixes(plan), nil)
	if err != nil {
		t.Fatal(err)
	}
	lease := &windowsSelectiveProxyLease{
		vpnProxy: "127.0.0.1:2088", zapretProxy: "127.0.0.1:2089", script: script, domainCount: len(domains), revision: 7,
		pacURLBase: "http://127.0.0.1:32123/dropo-selective-test.pac",
		pacURL:     "http://127.0.0.1:32123/dropo-selective-test.pac?revision=1",
	}
	beforeURL := lease.PACURL()
	if err := lease.Update(plan); err != nil {
		t.Fatal(err)
	}
	if lease.PACURL() != beforeURL || lease.revision != 7 {
		t.Fatalf("unchanged PAC update changed identity: url=%q revision=%d", lease.PACURL(), lease.revision)
	}
}
