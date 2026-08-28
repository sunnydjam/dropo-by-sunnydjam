package trafficorchestrator

import (
	"encoding/binary"
	"testing"
)

func TestProcessorReflectsAndRestoresSelectiveVPNUDP(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("www.youtube.com")
	if !ok {
		t.Fatal("YouTube fake IP is missing")
	}
	registry := NewUDPRedirectRegistry()
	redirector, err := NewUDPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithFullSelectiveRuntime(plan, nil, nil, redirector, directory)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4UDPPacket(target.Address.String(), 443, []byte("quic"))
	decision := processor.Process(original)
	if decision.Dropped || !decision.Transformed || decision.Direction != PacketDirectionInbound || decision.ServiceID != "youtube" || decision.Reason != "reflected to selective VPN UDP relay" {
		t.Fatalf("UDP reflection decision = %+v", decision)
	}
	reflected, err := parsePacket(decision.Packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if reflected.source != target.Address || reflected.destination.String() != "192.0.2.1" || reflected.sourcePort != 40000 || reflected.destinationPort != 34010 {
		t.Fatalf("reflected UDP tuple = %+v", reflected.flowTuple())
	}

	response := testIPv4UDPPacket(target.Address.String(), 40000, []byte("reply"))
	binary.BigEndian.PutUint16(response[20:22], 34010)
	calculateChecksums(response)
	restoredDecision := processor.Process(response)
	if restoredDecision.Dropped || !restoredDecision.Transformed || restoredDecision.Direction != PacketDirectionInbound || restoredDecision.Reason != "restored selective VPN UDP relay response" {
		t.Fatalf("UDP restore decision = %+v", restoredDecision)
	}
	restored, err := parsePacket(restoredDecision.Packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if restored.source != target.Address || restored.destination.String() != "192.0.2.1" || restored.sourcePort != 443 || restored.destinationPort != 40000 {
		t.Fatalf("restored UDP tuple = %+v", restored.flowTuple())
	}
}

func TestUDPRedirectRegistryRejectsAmbiguousClientTuple(t *testing.T) {
	registry := NewUDPRedirectRegistry()
	first := UDPRedirectTarget{
		Flow: FlowTuple{Network: NetworkUDP, Source: testMustAddr("192.0.2.1"), SourcePort: 40000, Destination: testMustAddr("198.18.1.1"), DestinationPort: 443},
		Host: "youtube.com", ServiceID: "youtube", Route: ServiceRouteVPN,
	}
	if err := registry.Register(first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.Flow.Source = testMustAddr("192.0.2.2")
	if err := registry.Register(second); err == nil {
		t.Fatal("ambiguous UDP client tuple was accepted")
	}
}

func TestProcessorRoutesProcessScopedDiscordMediaOutsideStaticCIDR(t *testing.T) {
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: "discord-process-media",
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.media"},
			ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
			ProcessDiscoveryUDPPortRanges: []PortRange{{First: 50000, Last: 50099}},
		}},
		Routes: []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}},
	}
	registry := NewUDPRedirectRegistry()
	redirector, err := NewUDPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithFullSelectiveRuntime(plan, &fixedFlowIdentityResolver{name: `C:\Users\sunny\AppData\Local\Discord\Discord.exe`}, nil, redirector, nil)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4UDPPacket("35.217.47.13", 50005, []byte("discord encrypted media"))
	decision := processor.Process(original)
	if decision.Dropped || !decision.Transformed || decision.ServiceID != "discord" || decision.Route != ServiceRouteVPN || decision.Reason != "reflected to selective VPN UDP relay" {
		t.Fatalf("Discord process media decision = %+v", decision)
	}
}
