//go:build windows

package main

import (
	"testing"
	"unsafe"

	traffic "dropo/trafficorchestrator"
)

func TestSelectivePACConnectionStateEnablesDirectFallbackAndPAC(t *testing.T) {
	state := selectivePACConnectionState("http://127.0.0.1:32123/route.pac")
	if state.Flags != proxyTypeDirect|proxyTypeAutoProxyURL {
		t.Fatalf("connection flags = 0x%x", state.Flags)
	}
	if state.AutoConfigURL != "http://127.0.0.1:32123/route.pac" {
		t.Fatalf("PAC URL = %q", state.AutoConfigURL)
	}
}

func TestWinInetPerConnectionLayoutsMatchWindowsABI(t *testing.T) {
	pointerSize := unsafe.Sizeof(uintptr(0))
	if got := unsafe.Offsetof(internetPerConnectionOption{}.value); got != pointerSize {
		t.Fatalf("option union offset = %d, pointer size = %d", got, pointerSize)
	}
	wantOptionSize := pointerSize * 2
	if got := unsafe.Sizeof(internetPerConnectionOption{}); got != wantOptionSize {
		t.Fatalf("option size = %d, want %d", got, wantOptionSize)
	}
}

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
