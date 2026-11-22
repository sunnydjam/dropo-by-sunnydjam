package trafficorchestrator

import (
	"net/netip"
	"testing"
)

func fakeIPTestPlan() TrafficPlan {
	return TrafficPlan{
		Revision: 1, CatalogRevision: "fakeip-test",
		Services: []ServiceRule{
			{ID: "youtube", DisplayName: "YouTube", DomainSuffixes: []string{"youtube.com"}, TCPPorts: []int{80, 443}},
			{ID: "openai", DisplayName: "ChatGPT", DomainSuffixes: []string{"chatgpt.com"}, TCPPorts: []int{80, 443}},
		},
		Routes: []ServiceRoute{
			{ServiceID: "youtube", Kind: ServiceRouteVPN},
			{ServiceID: "openai", Kind: ServiceRouteDirect},
		},
	}
}

func TestFakeIPDirectoryMapsOnlySelectedVPNDomains(t *testing.T) {
	directory, err := NewFakeIPDirectory(fakeIPTestPlan())
	if err != nil {
		t.Fatal(err)
	}
	first, ok := directory.ResolveHost("WWW.YouTube.com.")
	if !ok || first.ServiceID != "youtube" || first.Host != "www.youtube.com" || !selectiveVPNFakeIPv4Prefix.Contains(first.Address) {
		t.Fatalf("YouTube fake target = %+v, found=%t", first, ok)
	}
	second, ok := directory.ResolveHost("www.youtube.com")
	if !ok || second != first {
		t.Fatalf("fake mapping is not stable: first=%+v second=%+v", first, second)
	}
	if reverse, ok := directory.LookupAddress(first.Address); !ok || reverse != first {
		t.Fatalf("reverse fake mapping = %+v, found=%t", reverse, ok)
	}
	for _, host := range []string{"chatgpt.com", "store.steampowered.com", "notyoutube.com"} {
		if target, ok := directory.ResolveHost(host); ok {
			t.Fatalf("direct/unrelated host %q received fake target %+v", host, target)
		}
	}
}

func TestFakeIPDirectoryRespectsDirectRulePriority(t *testing.T) {
	plan := fakeIPTestPlan()
	plan.DirectRules = []DirectRule{{ID: "direct-video", DomainSuffixes: []string{"media.youtube.com"}}}
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	if target, ok := directory.ResolveHost("media.youtube.com"); ok {
		t.Fatalf("direct-rule host received fake target %+v", target)
	}
}

func TestFakeIPDirectoryAppliesTypedRouteRevision(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("www.youtube.com")
	if !ok {
		t.Fatal("initial VPN route did not map YouTube")
	}
	plan.Revision++
	plan.Routes[0].Kind = ServiceRouteDirect
	if err := directory.ApplyPlan(plan); err != nil {
		t.Fatal(err)
	}
	if _, ok := directory.ResolveHost("m.youtube.com"); ok {
		t.Fatal("direct route received a new fake IP after revision")
	}
	if _, ok := directory.LookupAddress(target.Address); ok {
		t.Fatal("stale fake IP remained active after service became direct")
	}
}

func TestFakeIPDirectoryMapsOnlyExactZapretBootstrapHosts(t *testing.T) {
	plan := fakeIPTestPlan()
	plan.Services = append(plan.Services, ServiceRule{
		ID: "discord", DisplayName: "Discord", ExactHosts: []string{"updates.discord.com"},
		DomainSuffixes: []string{"discord.com"}, TCPPorts: []int{443},
	})
	plan.Routes = append(plan.Routes, ServiceRoute{ServiceID: "discord", Kind: ServiceRouteZapret})
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("updates.discord.com")
	if !ok || target.ServiceID != "discord" || target.Route != ServiceRouteZapret {
		t.Fatalf("Zapret bootstrap target = %+v, found=%t", target, ok)
	}
	if _, ok := directory.ResolveHost("images.discord.com"); ok {
		t.Fatal("suffix-only Zapret host received a fake IP")
	}
	if _, ok := directory.ResolveHost("store.steampowered.com"); ok {
		t.Fatal("unrelated Steam host received a fake IP")
	}
}

func TestProcessorRedirectsExactZapretFakeIPFromInitialSYN(t *testing.T) {
	plan := fakeIPTestPlan()
	plan.Services = append(plan.Services, ServiceRule{
		ID: "discord", DisplayName: "Discord", ExactHosts: []string{"updates.discord.com"},
		DomainSuffixes: []string{"discord.com"}, TCPPorts: []int{443},
	})
	plan.Routes = append(plan.Routes, ServiceRoute{ServiceID: "discord", Kind: ServiceRouteZapret})
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("updates.discord.com")
	if !ok {
		t.Fatal("Discord updater did not receive a fake IP")
	}
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithSelectiveRuntime(plan, nil, redirector, directory)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacketTo(t, target.Address.String(), "unrelated.example")
	packet[33] = 0x02
	calculateChecksums(packet)
	decision := processor.Process(packet)
	if decision.Dropped || !decision.Transformed || decision.ServiceID != "discord" || decision.Route != ServiceRouteZapret {
		t.Fatalf("fake-IP Zapret decision = %+v", decision)
	}
	if !registry.contains(TCPRedirectTarget{
		Flow: FlowTuple{
			Network: NetworkTCP, Source: testMustAddr("10.0.0.1"), SourcePort: 50000,
			Destination: target.Address, DestinationPort: 443,
		},
		Host: "updates.discord.com", ServiceID: "discord", Route: ServiceRouteZapret,
	}) {
		t.Fatal("Zapret fake-IP redirect target was not registered")
	}
}

func TestProcessorRedirectsFakeIPFromInitialSYN(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("www.youtube.com")
	if !ok {
		t.Fatal("YouTube did not receive a fake IP")
	}
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithSelectiveRuntime(plan, nil, redirector, directory)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacketTo(t, target.Address.String(), "unrelated.example")
	packet[33] = 0x02
	calculateChecksums(packet)
	decision := processor.Process(packet)
	if decision.Dropped || !decision.Transformed || decision.ServiceID != "youtube" || decision.Route != ServiceRouteVPN || decision.Direction != PacketDirectionInbound {
		t.Fatalf("fake-IP VPN decision = %+v", decision)
	}
	if !registry.contains(TCPRedirectTarget{
		Flow: FlowTuple{
			Network: NetworkTCP, Source: testMustAddr("10.0.0.1"), SourcePort: 50000,
			Destination: target.Address, DestinationPort: 443,
		},
		Host: "www.youtube.com", ServiceID: "youtube", Route: ServiceRouteVPN,
	}) {
		t.Fatal("fake-IP redirect target was not registered")
	}
}

func testMustAddr(value string) netip.Addr {
	return netip.MustParseAddr(value)
}
