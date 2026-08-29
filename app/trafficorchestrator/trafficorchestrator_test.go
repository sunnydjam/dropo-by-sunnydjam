package trafficorchestrator

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"
)

func testStrategy(id string, risk int) TrafficStrategy {
	return TrafficStrategy{
		ID:          id,
		Revision:    1,
		Label:       id,
		TCP:         []PacketAction{{Kind: ActionFake, Payload: "tls_client_hello", Repeats: 2}, {Kind: ActionSplit, Position: 2}},
		UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_initial", Repeats: 2}},
		Constraints: StrategyConstraints{Networks: []Network{NetworkTCP, NetworkUDP}, IPv4: true, IPv6: true, MaxFlowData: 64 * 1024},
		Cost:        StrategyCost{SyntheticPackets: 2, BufferedBytes: 4096, Risk: risk},
	}
}

func testPlan() TrafficPlan {
	return TrafficPlan{
		Revision:        1,
		CatalogRevision: "test-1",
		Strategies:      []TrafficStrategy{testStrategy("safe", 1), testStrategy("strong", 3)},
		Services: []ServiceRule{{
			ID:                   "discord",
			DisplayName:          "Discord",
			DomainSuffixes:       []string{"discord.com", "discord.media"},
			IPCIDRs:              []string{"66.22.192.0/18"},
			IPMatchPolicy:        IPMatchRequireContext,
			ProcessNames:         []string{"Discord.exe"},
			TCPPorts:             []int{443},
			UDPPorts:             []int{3478, 50000},
			Fingerprints:         []string{"discord-media", "stun"},
			CandidateStrategyIDs: []string{"safe", "strong"},
			ProbeTargets: []ProbeTarget{
				{ID: "web", Network: NetworkTCP, Kind: ProbeHTTP, URL: "https://discord.com/api/v10/gateway", Port: 443},
				{ID: "media", Network: NetworkUDP, Kind: ProbeDiscordMedia, Host: "66.22.200.1", Port: 50000},
			},
			AllowVPNFallback: true,
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: "safe"}},
	}
}

func TestValidatePlanAndClassifier(t *testing.T) {
	plan := testPlan()
	if err := ValidatePlan(plan); err != nil {
		t.Fatalf("ValidatePlan() error = %v", err)
	}
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatalf("NewClassifier() error = %v", err)
	}

	web := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "1.1.1.1", Port: 443, Host: "cdn.discord.com", ProcessName: `C:\\Users\\u\\Discord.exe`})
	if !web.Matched || web.ServiceID != "discord" {
		t.Fatalf("web classification = %+v", web)
	}
	media := classifier.Classify(FlowEvidence{Network: NetworkUDP, Destination: "66.22.200.1", Port: 50000, Fingerprints: []string{"discord-media"}})
	if !media.Matched || media.ServiceID != "discord" {
		t.Fatalf("media classification = %+v", media)
	}
	processOnly := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "8.8.8.8", Port: 443, ProcessName: "Discord.exe"})
	if processOnly.Matched {
		t.Fatalf("process-only classification must fail safe: %+v", processOnly)
	}
	wrongPort := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "66.22.200.1", Port: 80, Host: "discord.com"})
	if wrongPort.Matched {
		t.Fatalf("wrong-port classification must fail safe: %+v", wrongPort)
	}
}

func TestValidatePlanBoundsProcessUDPDiscoveryRanges(t *testing.T) {
	plan := testPlan()
	plan.Services[0].ProcessMatchPolicy = ProcessMatchIdentity
	plan.Services[0].ProcessDiscoveryUDPPortRanges = []PortRange{{First: 50000, Last: 50100}}
	if err := ValidatePlan(plan); err != nil {
		t.Fatalf("valid bounded discovery range rejected: %v", err)
	}
	plan.Services[0].ProcessDiscoveryUDPPortRanges = []PortRange{{First: 1, Last: 1000}}
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("oversized process UDP discovery range accepted")
	}
	plan.Services[0].ProcessMatchPolicy = ProcessMatchCorroborate
	plan.Services[0].ProcessDiscoveryUDPPortRanges = []PortRange{{First: 50000, Last: 50100}}
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("process UDP discovery without identity accepted")
	}
}

func TestExplicitProcessIdentityClassifiesNamedDesktopService(t *testing.T) {
	plan := testPlan()
	plan.Services[0].ProcessMatchPolicy = ProcessMatchIdentity
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	got := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "203.0.113.10", Port: 443, ProcessName: `C:\Users\u\Discord.exe`})
	_, hasProcessIdentity := stringSet(got.Evidence, normalizeToken)["process-identity"]
	if !got.Matched || got.ServiceID != "discord" || !hasProcessIdentity {
		t.Fatalf("process identity classification = %+v", got)
	}
}

func TestProcessIdentityCannotRedirectPrivateDestination(t *testing.T) {
	plan := testPlan()
	plan.Services[0].ProcessMatchPolicy = ProcessMatchIdentity
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	got := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "192.168.1.20", Port: 443, ProcessName: "Discord.exe"})
	if !got.WorkNetwork || got.Matched || got.WorkNetworkID != "local-private" {
		t.Fatalf("private process flow = %+v", got)
	}
}

func TestProcessorSelectionOnlyRevisionReusesImmutableClassifier(t *testing.T) {
	plan := testPlan()
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	before := processor.snapshot.Load().classifier
	plan.Revision++
	plan.Selections[0].StrategyID = "strong"
	if err := processor.ApplyPlan(plan); err != nil {
		t.Fatal(err)
	}
	if after := processor.snapshot.Load().classifier; after != before {
		t.Fatal("selection-only revision rebuilt the immutable classifier")
	}

	plan.Revision++
	plan.Selections[0].StrategyID = "missing"
	if err := processor.ApplyPlan(plan); err == nil {
		t.Fatal("selection-only revision accepted an unknown strategy")
	}
}

func TestWorkNetworkWinsBeforeBlockedService(t *testing.T) {
	plan := testPlan()
	plan.WorkNetworks = []WorkNetworkRule{{ID: "corporate", DomainSuffixes: []string{"discord.com"}, IPCIDRs: []string{"66.22.192.0/18"}}}
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	classification := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "66.22.200.1", Port: 443, Host: "discord.com"})
	if !classification.WorkNetwork || classification.Matched || classification.WorkNetworkID != "corporate" {
		t.Fatalf("classification = %+v", classification)
	}
}

func TestDirectRuleWinsBeforeBlockedCatalogIP(t *testing.T) {
	plan := testPlan()
	plan.DirectRules = []DirectRule{{ID: "steam-direct", DomainSuffixes: []string{"steam.com"}}}
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	classification := classifier.Classify(FlowEvidence{
		Network: NetworkTCP, Destination: "66.22.200.1", Port: 443, Host: "store.steam.com",
	})
	if !classification.Direct || classification.Matched || classification.DirectRuleID != "steam-direct" {
		t.Fatalf("classification = %+v", classification)
	}
}

func TestKnownUnblockedHostWinsOverSharedServiceIP(t *testing.T) {
	plan := testPlan()
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	classification := classifier.Classify(FlowEvidence{
		Network: NetworkTCP, Destination: "66.22.200.1", Port: 443, Host: "api.epicgames.dev",
	})
	if classification.Matched || classification.Direct || classification.WorkNetwork {
		t.Fatalf("classification = %+v, want fail-safe pass for the known unrelated host", classification)
	}
}

func TestHostlessServiceIPRequiresCorroboratingEvidence(t *testing.T) {
	plan := testPlan()
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	unknown := classifier.Classify(FlowEvidence{
		Network: NetworkUDP, Destination: "66.22.200.1", Port: 50000,
	})
	if unknown.Matched {
		t.Fatalf("unidentified shared-IP flow must pass unchanged: %+v", unknown)
	}
	media := classifier.Classify(FlowEvidence{
		Network: NetworkUDP, Destination: "66.22.200.1", Port: 50000, Fingerprints: []string{"discord-media"},
	})
	if !media.Matched || media.ServiceID != "discord" {
		t.Fatalf("corroborated Discord media classification = %+v", media)
	}
}

func TestGenericBlockedIPMatchesOnlyWithoutKnownHost(t *testing.T) {
	plan := testPlan()
	plan.Services[0].IPMatchPolicy = IPMatchHostless
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	if got := classifier.Classify(FlowEvidence{Network: NetworkUDP, Destination: "66.22.200.1", Port: 50000}); !got.Matched {
		t.Fatalf("hostless blocked-IP flow = %+v, want catalog fallback", got)
	}
	if got := classifier.Classify(FlowEvidence{Network: NetworkTCP, Destination: "66.22.200.1", Port: 443, Host: "accounts.ea.com"}); got.Matched {
		t.Fatalf("known EA host on the same IP = %+v, want unchanged pass", got)
	}
}

func TestProcessorSharedAddressEmulationKeepsUnblockedTLSDirect(t *testing.T) {
	processor, err := NewProcessor(testPlan())
	if err != nil {
		t.Fatal(err)
	}

	blockedPacket := testIPv4TCPPacketTo(t, "66.22.200.1", "gateway.discord.com")
	blockedDecision := processor.Process(blockedPacket)
	if !blockedDecision.Transformed || blockedDecision.ServiceID != "discord" {
		t.Fatalf("blocked service decision = %+v, want selected strategy", blockedDecision)
	}

	directPacket := testIPv4TCPPacketTo(t, "66.22.200.1", "accounts.ea.com")
	directDecision := processor.Process(directPacket)
	if directDecision.Transformed || directDecision.ServiceID != "" || len(directDecision.Packets) != 1 {
		t.Fatalf("unblocked service decision = %+v, want one unchanged packet", directDecision)
	}
	if string(directDecision.Packets[0]) != string(directPacket) {
		t.Fatal("direct-first decision changed the emulated EA packet")
	}
}

func TestDirectProcessWinsBeforeBroadBlockedCIDR(t *testing.T) {
	plan := testPlan()
	plan.DirectRules = []DirectRule{{ID: "game-direct", ProcessNames: []string{"steam.exe", "cs2.exe", "MistfallHunter-Win64-Shipping.exe"}}}
	plan.Services[0].IPCIDRs = []string{"0.0.0.0/0"}
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	got := classifier.Classify(FlowEvidence{Network: NetworkUDP, Destination: "203.0.113.50", Port: 443, ProcessName: `E:\SteamLibrary\steamapps\common\Mistfall Hunter\MistfallHunter\Binaries\Win64\MistfallHunter-Win64-Shipping.exe`, Fingerprints: []string{"quic"}})
	if !got.Direct || got.Matched || got.DirectRuleID != "game-direct" {
		t.Fatalf("classification = %#v, want explicit process direct", got)
	}
}

type fixedFlowIdentityResolver struct {
	name  string
	tuple FlowTuple
	calls int
}

func (resolver *fixedFlowIdentityResolver) ResolveProcessName(tuple FlowTuple) string {
	resolver.tuple = tuple
	resolver.calls++
	return resolver.name
}

func TestScopedZapretRuntimeTransformsOnlyOwnedSourcePorts(t *testing.T) {
	makePacket := func(sourcePort uint16) []byte {
		packet := testIPv4TCPPacket(t, "discord.com")
		binary.BigEndian.PutUint16(packet[20:22], sourcePort)
		calculateChecksums(packet)
		return packet
	}
	newScopedProcessor := func() *Processor {
		processor, err := NewProcessorWithScopedZapretRuntime(
			testPlan(), &fixedFlowIdentityResolver{name: "dropo-core.exe"}, nil, nil, nil,
			PortRange{First: 20000, Last: 21999},
		)
		if err != nil {
			t.Fatal(err)
		}
		return processor
	}

	decision := newScopedProcessor().Process(makePacket(20000))
	if !decision.Transformed || decision.ServiceID != "discord" {
		t.Fatalf("owned scoped Zapret flow decision = %+v", decision)
	}
	decision = newScopedProcessor().Process(makePacket(50000))
	if decision.Transformed || decision.Reason != "trusted Dropo runtime egress" {
		t.Fatalf("ordinary Dropo runtime egress decision = %+v", decision)
	}
}

func TestProcessorUsesObservedProcessForDirectPrecedence(t *testing.T) {
	plan := testPlan()
	plan.DirectRules = []DirectRule{{ID: "game-direct", ProcessNames: []string{"MistfallHunter-Win64-Shipping.exe"}}}
	resolver := &fixedFlowIdentityResolver{name: `E:\SteamLibrary\MistfallHunter-Win64-Shipping.exe`}
	processor, err := NewProcessorWithIdentityResolver(plan, resolver)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4UDPPacket("66.22.200.1", 443, []byte{0xc0, 0, 0, 0, 1})
	decision := processor.Process(packet)
	if decision.Transformed || decision.ServiceID != "" || decision.Reason != "reserved for direct rule game-direct" {
		t.Fatalf("decision = %+v, want observed game process to pass direct", decision)
	}
	if resolver.calls != 1 {
		t.Fatalf("identity resolver calls = %d, want 1", resolver.calls)
	}
	if resolver.tuple.Network != NetworkUDP || resolver.tuple.Source.String() != "192.0.2.1" || resolver.tuple.SourcePort != 40000 || resolver.tuple.Destination.String() != "66.22.200.1" || resolver.tuple.DestinationPort != 443 {
		t.Fatalf("observed tuple = %+v", resolver.tuple)
	}
	if string(decision.Packets[0]) != string(packet) {
		t.Fatal("direct process packet was changed")
	}
	flow, ok := processor.LookupFlowDecision(resolver.tuple)
	if !ok || flow.Disposition != FlowDirect || flow.RuleID != "game-direct" || flow.ProcessName != "mistfallhunter-win64-shipping.exe" {
		t.Fatalf("cached direct flow = %+v, found=%t", flow, ok)
	}
}

func TestProcessorSkipsIdentityLookupWhenPlanDoesNotUseProcesses(t *testing.T) {
	plan := testPlan()
	plan.Services[0].ProcessNames = nil
	resolver := &fixedFlowIdentityResolver{name: "Discord.exe"}
	processor, err := NewProcessorWithIdentityResolver(plan, resolver)
	if err != nil {
		t.Fatal(err)
	}
	processor.Process(testIPv4TCPPacket(t, "discord.com"))
	if resolver.calls != 0 {
		t.Fatalf("identity resolver calls = %d, want no unnecessary Windows lookup", resolver.calls)
	}
}

func TestUnclassifiedFlowIsRecordedDirectAndInvalidatedByPlanRevision(t *testing.T) {
	plan := testPlan()
	plan.Services[0].ProcessNames = nil
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacket(t, "unrelated.example")
	processor.Process(packet)
	parsed, err := parsePacket(packet)
	if err != nil {
		t.Fatal(err)
	}
	tuple := parsed.flowTuple()
	flow, ok := processor.LookupFlowDecision(tuple)
	if !ok || flow.Disposition != FlowDirect || flow.RuleID != "" || flow.Reason != "unclassified traffic defaults direct" {
		t.Fatalf("unknown flow = %+v, found=%t", flow, ok)
	}
	plan.Revision++
	if err := processor.ApplyPlan(plan); err != nil {
		t.Fatal(err)
	}
	if _, ok := processor.LookupFlowDecision(tuple); ok {
		t.Fatal("flow decision survived an immutable plan revision")
	}
}

func TestSelectionMustUseServiceCandidate(t *testing.T) {
	plan := testPlan()
	plan.Services[0].CandidateStrategyIDs = []string{"safe"}
	plan.Selections[0].StrategyID = "strong"
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("non-candidate service selection was accepted")
	}
}

func TestVPNRoutePassesPacketAndPersistsTypedFlowDecision(t *testing.T) {
	plan := testPlan()
	plan.Selections = nil
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacket(t, "gateway.discord.com")
	decision := processor.Process(packet)
	if decision.Transformed || decision.ServiceID != "discord" || decision.Route != ServiceRouteVPN || decision.Reason != "service requires selective VPN relay" {
		t.Fatalf("VPN decision = %+v", decision)
	}
	parsed, err := parsePacket(packet)
	if err != nil {
		t.Fatal(err)
	}
	flow, ok := processor.LookupFlowDecision(parsed.flowTuple())
	if !ok || flow.Disposition != FlowService || flow.ServiceID != "discord" || flow.Route != ServiceRouteVPN {
		t.Fatalf("VPN flow = %+v, found=%t", flow, ok)
	}
	if string(decision.Packets[0]) != string(packet) {
		t.Fatal("VPN-marked packet changed before relay activation")
	}
}

func TestProcessorReflectsVPNFlowAndRestoresRelayResponse(t *testing.T) {
	plan := testPlan()
	plan.Selections = nil
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithRuntime(plan, nil, redirector)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4TCPPacket(t, "gateway.discord.com")
	// A redirect may only be created from the initial SYN. Capturing a later
	// ClientHello without its handshake must never splice an established flow.
	original[33] = 0x02
	calculateChecksums(original)
	decision := processor.Process(original)
	if !decision.Transformed || decision.Dropped || decision.Direction != PacketDirectionInbound || decision.Route != ServiceRouteVPN || len(decision.Packets) != 1 {
		t.Fatalf("reflected decision = %+v", decision)
	}
	reflected, err := parsePacket(decision.Packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if reflected.source.String() != "1.1.1.1" || reflected.destination.String() != "10.0.0.1" || reflected.sourcePort != 50000 || reflected.destinationPort != 34010 {
		t.Fatalf("reflected tuple = %+v", reflected.flowTuple())
	}
	local := &net.TCPAddr{IP: net.ParseIP("10.0.0.1"), Port: 34010}
	remote := &net.TCPAddr{IP: net.ParseIP("1.1.1.1"), Port: 50000}
	if _, ok := registry.ConsumeAccepted(local, remote); !ok {
		t.Fatal("reflected flow was not accepted by registry")
	}

	response := append([]byte(nil), original...)
	binary.BigEndian.PutUint16(response[20:22], 34010)
	binary.BigEndian.PutUint16(response[22:24], 50000)
	calculateChecksums(response)
	restoredDecision := processor.Process(response)
	if !restoredDecision.Transformed || restoredDecision.Dropped || restoredDecision.Direction != PacketDirectionInbound || restoredDecision.Reason != "restored selective VPN relay response" {
		t.Fatalf("restored decision = %+v", restoredDecision)
	}
	restored, err := parsePacket(restoredDecision.Packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if restored.source.String() != "1.1.1.1" || restored.destination.String() != "10.0.0.1" || restored.sourcePort != 443 || restored.destinationPort != 50000 {
		t.Fatalf("restored tuple = %+v", restored.flowTuple())
	}
}

func TestProcessorRedirectsProcessIdentityFromInitialSYN(t *testing.T) {
	plan := testPlan()
	plan.Selections = nil
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}
	plan.Services[0].ProcessMatchPolicy = ProcessMatchIdentity
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	resolver := &fixedFlowIdentityResolver{name: `C:\Users\u\AppData\Local\Discord\Discord.exe`}
	processor, err := NewProcessorWithRuntime(plan, resolver, redirector)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4TCPPacket(t, "unrelated.example")
	original[33] = 0x02
	calculateChecksums(original)
	decision := processor.Process(original)
	if !decision.Transformed || decision.Dropped || decision.ServiceID != "discord" || decision.Route != ServiceRouteVPN {
		t.Fatalf("process-identity SYN decision = %+v", decision)
	}
	if resolver.calls != 1 {
		t.Fatalf("process identity resolver calls = %d, want 1", resolver.calls)
	}
}

func TestProcessorDoesNotSpliceMidstreamVPNFlow(t *testing.T) {
	plan := testPlan()
	plan.Selections = nil
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithRuntime(plan, nil, redirector)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacket(t, "gateway.discord.com")
	decision := processor.Process(packet)
	if decision.Dropped || decision.Transformed || !strings.Contains(decision.Reason, "failed safe") || len(decision.Packets) != 1 || string(decision.Packets[0]) != string(packet) {
		t.Fatalf("midstream VPN decision = %+v", decision)
	}
	second := processor.Process(packet)
	if second.Dropped || second.Transformed || second.Reason != "preserved established direct flow" || len(second.Packets) != 1 || string(second.Packets[0]) != string(packet) {
		t.Fatalf("preserved midstream decision = %+v", second)
	}
	counters := processor.Counters()["discord"]
	if counters.Errors != 1 || counters.Passed != 1 {
		t.Fatalf("midstream counters = %+v", counters)
	}
}

func TestOrphanRelayResponseIsDropped(t *testing.T) {
	plan := testPlan()
	registry := NewTCPRedirectRegistry()
	redirector, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithRuntime(plan, nil, redirector)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacket(t, "unrelated.example")
	binary.BigEndian.PutUint16(packet[20:22], 34010)
	binary.BigEndian.PutUint16(packet[22:24], 50000)
	calculateChecksums(packet)
	decision := processor.Process(packet)
	if !decision.Dropped || len(decision.Packets) != 0 || decision.Route != "" {
		t.Fatalf("orphan relay decision = %+v", decision)
	}
}

func TestPacketAddressDirectionUsesWinDivertOutboundBit(t *testing.T) {
	address := PacketAddress{Flags: winDivertAddressOutboundFlag | 0x1234}
	address.setDirection(PacketDirectionInbound)
	if address.Flags&winDivertAddressOutboundFlag != 0 {
		t.Fatal("inbound direction kept WinDivert outbound bit")
	}
	address.setDirection(PacketDirectionOutbound)
	if address.Flags&winDivertAddressOutboundFlag == 0 {
		t.Fatal("outbound direction did not set WinDivert outbound bit")
	}
}

func TestTrafficPlanRejectsConflictingOrUnknownServiceRoutes(t *testing.T) {
	plan := testPlan()
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("VPN route with a Zapret strategy selection was accepted")
	}
	plan = testPlan()
	plan.Routes = []ServiceRoute{{ServiceID: "missing", Kind: ServiceRouteVPN}}
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("route for an unknown service was accepted")
	}
	plan = testPlan()
	plan.Routes = []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteZapret}, {ServiceID: "discord", Kind: ServiceRouteZapret}}
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("duplicate service route was accepted")
	}
	plan = testPlan()
	plan.Services[0].ProcessNames = nil
	plan.Services[0].ProcessMatchPolicy = ProcessMatchIdentity
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("process identity policy without process names was accepted")
	}
}

func TestServiceCIDRRequiresExplicitSafeMatchPolicy(t *testing.T) {
	plan := testPlan()
	plan.Services[0].IPMatchPolicy = ""
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("service CIDR without an explicit match policy was accepted")
	}

	plan = testPlan()
	plan.Services[0].IPMatchPolicy = IPMatchPolicy("always")
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("unsupported service IP match policy was accepted")
	}

	plan = testPlan()
	plan.Services[0].IPMatchPolicy = IPMatchRequireContext
	plan.Services[0].ExactHosts = nil
	plan.Services[0].DomainSuffixes = nil
	plan.Services[0].ProcessNames = nil
	plan.Services[0].Fingerprints = nil
	if err := ValidatePlan(plan); err == nil {
		t.Fatal("context-required service CIDR without corroborating evidence was accepted")
	}
}

func TestValidateStrategyRejectsUnboundedActions(t *testing.T) {
	strategy := testStrategy("bad", 1)
	strategy.TCP[0].Repeats = 1000
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected unbounded repeats to be rejected")
	}
	strategy = testStrategy("bad-udp", 1)
	strategy.UDP = []PacketAction{{Kind: ActionSplit, Position: 2}}
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected UDP split to be rejected")
	}
	strategy = testStrategy("bad-anchor", 1)
	strategy.TCP[1] = PacketAction{Kind: ActionSplit, Positions: []PacketPosition{{Anchor: "unbounded-search"}}}
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected unknown dynamic anchor to be rejected")
	}
	strategy = testStrategy("bad-padding", 1)
	strategy.TCP[0].PadTo = maxSyntheticPayload + 1
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected oversized synthetic payload to be rejected")
	}
	strategy = testStrategy("bad-action-fields", 1)
	strategy.TCP[1].PadTo = 100
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected fields from another action kind to be rejected")
	}
	strategy = testStrategy("bad-sequence-delta", 1)
	strategy.TCP[0].SequenceDelta = maxSequenceDelta + 1
	if err := ValidateStrategy(strategy); err == nil {
		t.Fatal("expected unbounded sequence delta to be rejected")
	}
}

func TestBuiltinStrategiesAreValidAndUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, strategy := range BuiltinStrategies() {
		if seen[strategy.ID] {
			t.Fatalf("duplicate built-in strategy %q", strategy.ID)
		}
		seen[strategy.ID] = true
		if err := ValidateStrategy(strategy); err != nil {
			t.Fatalf("ValidateStrategy(%q) error = %v", strategy.ID, err)
		}
	}
}

func TestFlowseal1102YouTubeALTUsesExactTypedRecipe(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-flowseal-1102-youtube-alt" {
			strategy = candidate
			break
		}
	}
	if strategy.ID == "" {
		t.Fatal("exact YouTube General ALT strategy is missing")
	}
	if strategy.Revision != 5 || len(strategy.TCP) != 2 || len(strategy.UDP) != 1 {
		t.Fatalf("General ALT shape = %+v", strategy)
	}
	fake, split := strategy.TCP[0], strategy.TCP[1]
	if fake.Kind != ActionFake || fake.Payload != "tls_google" || fake.PadTo != 681 || fake.Repeats != 6 || fake.TCPFooling != TCPFoolingTimestampOrBadSum || fake.TimestampDelta != -600000 || fake.IPv4ID != IPv4IDZero {
		t.Fatalf("General ALT TLS fake = %+v", fake)
	}
	if split.Kind != ActionFakeDataSplit || split.Position != 1 || split.Repeats != 6 || split.FakePattern != FakePatternZero || split.TCPFooling != TCPFoolingTimestampOrBadSum || split.TimestampDelta != -600000 || split.IPv4ID != IPv4IDZero {
		t.Fatalf("General ALT fake data split = %+v", split)
	}
	if udp := strategy.UDP[0]; udp.Kind != ActionFake || udp.Payload != "quic_google" || udp.PadTo != 1200 || udp.Repeats != 6 {
		t.Fatalf("General ALT QUIC fake = %+v", udp)
	}
}

func TestFlowseal1102DiscordALTUsesExactTypedRecipe(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-discord-flowseal-1102-alt" {
			strategy = candidate
			break
		}
	}
	if strategy.ID == "" {
		t.Fatal("exact Discord General ALT strategy is missing")
	}
	if strategy.Revision != 5 || len(strategy.TCP) != 7 || len(strategy.UDP) != 2 {
		t.Fatalf("Discord General ALT shape = %+v", strategy)
	}
	if fake := strategy.TCP[0]; fake.Payload != "tls_google" || fake.PadTo != 681 || fake.Repeats != 6 || len(fake.Ports) != 5 || fake.TCPFooling != TCPFoolingTimestampOrBadSum {
		t.Fatalf("Discord media TLS fake = %+v", fake)
	}
	if split := strategy.TCP[1]; split.Kind != ActionFakeDataSplit || split.Position != 1 || split.FakePattern != FakePatternZero || split.Repeats != 6 {
		t.Fatalf("Discord media fake data split = %+v", split)
	}
	if fake := strategy.TCP[2]; fake.Payload != "stun_decoy" || fake.PadTo != 100 || fake.Repeats != 6 || len(fake.Ports) != 2 || fake.TCPFooling != TCPFoolingTimestampOrBadSum {
		t.Fatalf("Discord web STUN fake = %+v", fake)
	}
	if fake := strategy.TCP[3]; fake.Payload != "tls_google" || fake.PadTo != 681 || fake.Repeats != 6 || len(fake.Payloads) != 1 || fake.Payloads[0] != "tls-client-hello" {
		t.Fatalf("Discord web TLS fake = %+v", fake)
	}
	if split := strategy.TCP[4]; split.Kind != ActionFakeDataSplit || split.Position != 1 || split.FakePattern != FakePatternZero || split.Repeats != 6 || split.Payloads[0] != "tls-client-hello" {
		t.Fatalf("Discord web TLS fake data split = %+v", split)
	}
	if fake := strategy.TCP[5]; fake.Payload != "tls_max" || fake.PadTo != 664 || fake.Payloads[0] != "http-request" {
		t.Fatalf("Discord web HTTP fake = %+v", fake)
	}
	if udp := strategy.UDP[0]; udp.Payload != "quic_google" || udp.PadTo != 1200 || udp.Repeats != 6 || len(udp.Ports) != 1 || udp.Ports[0] != 443 {
		t.Fatalf("Discord QUIC fake = %+v", udp)
	}
	if udp := strategy.UDP[1]; udp.Payload != "discord_active" || udp.PadTo != 1200 || udp.Repeats != 6 || len(udp.PortRanges) != 2 || udp.PortRanges[0] != (PortRange{First: 19294, Last: 19344}) || udp.PortRanges[1] != (PortRange{First: 50000, Last: 50100}) {
		t.Fatalf("Discord media fake = %+v", udp)
	}
}

func TestFlowseal1102CatalogContainsEveryScopedProfile(t *testing.T) {
	counts := map[string]int{"native-flowseal-1102-youtube-": 0, "native-discord-flowseal-1102-": 0}
	for _, strategy := range BuiltinStrategies() {
		for prefix := range counts {
			if strings.HasPrefix(strategy.ID, prefix) {
				counts[prefix]++
				if strategy.Revision != 5 {
					t.Fatalf("%s revision = %d, want typed profile revision 5", strategy.ID, strategy.Revision)
				}
			}
		}
	}
	for prefix, count := range counts {
		if count != 22 {
			t.Fatalf("%s profile count = %d, want 22", prefix, count)
		}
	}
}

func TestFlowseal1102HostFakeSplitPreservesRealTLSStream(t *testing.T) {
	strategy := builtinStrategyByID(t, "native-flowseal-1102-youtube-alt12")
	original := testIPv4TCPPacket(t, "www.youtube.com")
	parsed, err := parsePacket(original)
	if err != nil {
		t.Fatal(err)
	}
	_, start, end := locateTLSServerName(parsed.payload(), true)
	packets, transformed, err := applyStrategy(parsed, strategy)
	if err != nil {
		t.Fatal(err)
	}
	if !transformed || (len(packets) != 4 && len(packets) != 5) {
		t.Fatalf("hostfakesplit produced %d packets, transformed=%v", len(packets), transformed)
	}
	payloads := make([][]byte, len(packets))
	for index, packet := range packets {
		part, parseErr := parsePacket(packet)
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		payloads[index] = append([]byte(nil), part.payload()...)
	}
	if !bytes.Equal(payloads[0], parsed.payload()[:start]) || !bytes.Equal(payloads[2], parsed.payload()[start:end]) {
		t.Fatal("real hostfakesplit segments do not reconstruct the original TLS stream")
	}
	if end < len(parsed.payload()) && (len(payloads) != 5 || !bytes.Equal(payloads[4], parsed.payload()[end:])) {
		t.Fatal("hostfakesplit trailing real segment does not match the original TLS stream")
	}
	if bytes.Equal(payloads[1], parsed.payload()[start:end]) || !bytes.Equal(payloads[1], payloads[3]) || len(payloads[1]) != end-start {
		t.Fatal("hostfakesplit fake host segments are not bounded distinct replacements")
	}
}

func TestFlowseal1102MultisplitUsesEmbeddedOverlapPattern(t *testing.T) {
	strategy := builtinStrategyByID(t, "native-flowseal-1102-youtube-general")
	original := testIPv4TCPPacket(t, "www.youtube.com")
	parsed, err := parsePacket(original)
	if err != nil {
		t.Fatal(err)
	}
	packets, transformed, err := applyStrategy(parsed, strategy)
	if err != nil {
		t.Fatal(err)
	}
	if !transformed || len(packets) != 2 {
		t.Fatalf("multisplit produced %d packets, transformed=%v", len(packets), transformed)
	}
	first, err := parsePacket(packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(first.payload()) != 682 || !bytes.Equal(first.payload()[:681], flowseal1102GoogleTLS) || first.payload()[681] != parsed.payload()[0] {
		t.Fatal("multisplit first segment does not contain the exact 681-byte Google overlap followed by real byte 1")
	}
	if first.tcpSequence != parsed.tcpSequence-681 {
		t.Fatalf("overlap sequence = %d, want %d", first.tcpSequence, parsed.tcpSequence-681)
	}
}

func builtinStrategyByID(t *testing.T, id string) TrafficStrategy {
	t.Helper()
	for _, strategy := range BuiltinStrategies() {
		if strategy.ID == id {
			return strategy
		}
	}
	t.Fatalf("built-in strategy %q is missing", id)
	return TrafficStrategy{}
}

func TestDiscordDiscoveryRangesParticipateInClassification(t *testing.T) {
	strategy := TrafficStrategy{
		ID: "discord-test", Revision: 1, Label: "Discord test",
		UDP:         []PacketAction{{Kind: ActionFake, Payload: "discord_active", Repeats: 1}},
		Constraints: StrategyConstraints{Networks: []Network{NetworkUDP}, Payloads: []string{"discord-media"}, IPv4: true, IPv6: true},
	}
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: "discord-ranges", Strategies: []TrafficStrategy{strategy},
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
			Fingerprints: []string{"discord-media"},
			UDPPorts:     []int{443}, ProcessDiscoveryUDPPortRanges: []PortRange{{First: 19294, Last: 19344}, {First: 50000, Last: 50100}},
			CandidateStrategyIDs: []string{strategy.ID}, AllowVPNFallback: true, AllowDirectFallback: true,
		}},
	}
	classifier, err := NewClassifier(plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, port := range []int{443, 19294, 19344, 50000, 50100} {
		got := classifier.Classify(FlowEvidence{Network: NetworkUDP, Destination: "203.0.113.10", Port: port, ProcessName: `C:\Users\u\AppData\Local\Discord\Discord.exe`})
		if !got.Matched || got.ServiceID != "discord" {
			t.Fatalf("Discord port %d classification = %+v", port, got)
		}
	}
	got := classifier.Classify(FlowEvidence{Network: NetworkUDP, Destination: "203.0.113.10", Port: 50050, ProcessName: "steam.exe"})
	if got.Matched {
		t.Fatalf("unrelated process in Discord discovery range matched: %+v", got)
	}
}

func TestDiscordALTUsesProtocolSpecificUDPDecoys(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-discord-flowseal-1102-alt" {
			strategy = candidate
			break
		}
	}
	quicPacket := testIPv4UDPPacket("162.159.135.232", 443, testQUICInitialPacket(t, quicVersion1, "discord.com"))
	quicParsed, err := parsePacket(quicPacket)
	if err != nil {
		t.Fatal(err)
	}
	quicPackets, transformed, err := applyStrategy(quicParsed, strategy)
	if err != nil || !transformed || len(quicPackets) != 7 {
		t.Fatalf("Discord QUIC strategy packets=%d transformed=%v err=%v", len(quicPackets), transformed, err)
	}
	firstQUIC, err := parsePacket(quicPackets[0])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(firstQUIC.payload(), flowseal1102GoogleQUIC) {
		t.Fatal("Discord UDP/443 did not use the Flowseal QUIC decoy")
	}

	discovery := make([]byte, 74)
	discovery[1], discovery[3] = 1, 70
	mediaPacket := testIPv4UDPPacket("66.22.200.1", 50000, discovery)
	mediaParsed, err := parsePacket(mediaPacket)
	if err != nil {
		t.Fatal(err)
	}
	mediaPackets, transformed, err := applyStrategy(mediaParsed, strategy)
	if err != nil || !transformed || len(mediaPackets) != 7 {
		t.Fatalf("Discord media strategy packets=%d transformed=%v err=%v", len(mediaPackets), transformed, err)
	}
	firstMedia, err := parsePacket(mediaPackets[0])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(firstMedia.payload(), flowseal1102DiscordUDP) {
		t.Fatal("Discord media range did not use the active Discord decoy")
	}
}

func TestActionPortRangesAreBounded(t *testing.T) {
	strategy := TrafficStrategy{
		ID: "range-test", Revision: 1, Label: "Range test",
		UDP: []PacketAction{{
			Kind: ActionFake, Payload: "discord_active", Repeats: 1,
			PortRanges: []PortRange{{First: 50000, Last: 60000}},
		}},
	}
	if err := ValidateStrategy(strategy); err == nil || !strings.Contains(err.Error(), "at most 512 ports") {
		t.Fatalf("oversized action port range validation error = %v", err)
	}
	strategy.UDP[0].PortRanges = []PortRange{{First: 50100, Last: 50000}}
	if err := ValidateStrategy(strategy); err == nil || !strings.Contains(err.Error(), "is invalid") {
		t.Fatalf("reversed action port range validation error = %v", err)
	}
}

func TestFlowseal1102ALTFallsBackToInvalidSyntheticChecksumsWithoutTimestamp(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-flowseal-1102-youtube-alt" {
			strategy = candidate
			break
		}
	}
	original := testIPv4TCPPacket(t, "www.youtube.com")
	parsed, err := parsePacket(original)
	if err != nil {
		t.Fatal(err)
	}
	packets, transformed, err := applyStrategy(parsed, strategy)
	if err != nil {
		t.Fatalf("applyStrategy() error = %v", err)
	}
	if !transformed || len(packets) != 32 {
		t.Fatalf("timestamp-free ALT emitted packets=%d transformed=%v, want 32/true", len(packets), transformed)
	}
	for _, index := range []int{0, 6, 13, 19, 26} {
		decoy := packets[index]
		valid := append([]byte(nil), decoy...)
		calculateChecksums(valid)
		if bytes.Equal(valid, decoy) {
			t.Fatalf("synthetic packet %d unexpectedly retained a valid checksum", index)
		}
	}
	for _, index := range []int{12, 25} {
		real := packets[index]
		valid := append([]byte(nil), real...)
		calculateChecksums(valid)
		if !bytes.Equal(valid, real) {
			t.Fatalf("real segment %d has an invalid checksum", index)
		}
	}
}

func TestFlowseal1102YouTubeALTPacketOrderAndFooling(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-flowseal-1102-youtube-alt" {
			strategy = candidate
			break
		}
	}
	original := testIPv4TCPPacketWithTimestampTo(t, "1.1.1.1", "www.youtube.com")
	originalParsed, err := parsePacket(original)
	if err != nil {
		t.Fatal(err)
	}
	packets, transformed, err := applyStrategy(originalParsed, strategy)
	if err != nil {
		t.Fatalf("applyStrategy() error = %v", err)
	}
	if !transformed || len(packets) != 32 {
		t.Fatalf("transformed=%v packets=%d, want true/32", transformed, len(packets))
	}
	first, err := parsePacket(packets[0])
	if err != nil {
		t.Fatal(err)
	}
	if first.ipVersion != 4 || binary.BigEndian.Uint16(packets[0][4:6]) != 0 {
		t.Fatalf("first fake IPv4 ID = %d", binary.BigEndian.Uint16(packets[0][4:6]))
	}
	if got := testTCPTimestampValue(t, packets[0]); got != 400000 {
		t.Fatalf("fooled timestamp = %d, want 400000", got)
	}
	if got := extractTLSServerName(first.payload()); got != "www.google.com" {
		t.Fatalf("fake TLS SNI = %q", got)
	}

	// Six initial TLS fakes are followed by fakedsplit altorder=0. The real
	// segments are positions 12 and 25 in the complete output sequence.
	realFirst, err := parsePacket(packets[12])
	if err != nil {
		t.Fatal(err)
	}
	realSecond, err := parsePacket(packets[25])
	if err != nil {
		t.Fatal(err)
	}
	reconstructed := append(append([]byte(nil), realFirst.payload()...), realSecond.payload()...)
	if !bytes.Equal(reconstructed, originalParsed.payload()) {
		t.Fatal("real fakedsplit segments do not reconstruct the original ClientHello")
	}
	if got := testTCPTimestampValue(t, packets[12]); got != 1000000 {
		t.Fatalf("real segment timestamp changed to %d", got)
	}
	fakeFirst, err := parsePacket(packets[6])
	if err != nil {
		t.Fatal(err)
	}
	if len(fakeFirst.payload()) != 1 || !bytes.Equal(fakeFirst.payload(), []byte{0}) {
		t.Fatalf("first fake split payload = %x", fakeFirst.payload())
	}
	if got := testTCPTimestampValue(t, packets[6]); got != 400000 {
		t.Fatalf("fake split timestamp = %d", got)
	}
}

func TestExactALTLeavesUnselectedTLSByteForByteDirect(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-flowseal-1102-youtube-alt" {
			strategy = candidate
			break
		}
	}
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: BuiltinCatalogRevision,
		Strategies: []TrafficStrategy{strategy},
		Services: []ServiceRule{{
			ID: "youtube", DisplayName: "YouTube", DomainSuffixes: []string{"youtube.com"},
			TCPPorts: []int{443}, UDPPorts: []int{443}, CandidateStrategyIDs: []string{strategy.ID},
			AllowVPNFallback: true, AllowDirectFallback: true,
		}},
		Selections: []ServiceSelection{{ServiceID: "youtube", StrategyID: strategy.ID}},
		Routes:     []ServiceRoute{{ServiceID: "youtube", Kind: ServiceRouteZapret}},
	}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4TCPPacketWithTimestampTo(t, "203.0.113.77", "store.steampowered.com")
	decision := processor.Process(original)
	if decision.Transformed || decision.ServiceID != "" || len(decision.Packets) != 1 || !bytes.Equal(decision.Packets[0], original) {
		t.Fatalf("unselected TLS was changed: %+v", decision)
	}
}

type fakeSelectorRuntime struct {
	active    string
	committed string
	results   map[string]map[string]bool
}

func (r *fakeSelectorRuntime) Probe(_ context.Context, target ProbeTarget) ProbeObservation {
	success := r.results[r.active][target.ID]
	if success {
		return ProbeObservation{Success: true, Latency: 5 * time.Millisecond}
	}
	return ProbeObservation{Failure: FailureTimeout}
}

func (r *fakeSelectorRuntime) BeginTrial(_ context.Context, _ string, strategy TrafficStrategy) (StrategyTrial, error) {
	previous := r.active
	r.active = strategy.ID
	return &fakeTrial{runtime: r, previous: previous, strategy: strategy.ID}, nil
}

type fakeTrial struct {
	runtime  *fakeSelectorRuntime
	previous string
	strategy string
}

func (t *fakeTrial) Commit() error {
	t.runtime.committed = t.strategy
	return nil
}

func (t *fakeTrial) Rollback() error {
	t.runtime.active = t.previous
	return nil
}

func selectorRequest() SelectionRequest {
	return SelectionRequest{
		ServiceID: "discord",
		Targets: []ProbeTarget{
			{ID: "web", Network: NetworkTCP, Kind: ProbeHTTP, URL: "https://discord.com/api/v10/gateway", Port: 443},
			{ID: "media", Network: NetworkUDP, Kind: ProbeDiscordMedia, Host: "66.22.200.1", Port: 50000},
		},
		Candidates:        []TrafficStrategy{testStrategy("partial", 1), testStrategy("common", 2)},
		Attempts:          3,
		RequiredSuccesses: 2,
	}
}

func TestSelectorRequiresOneStrategyForEveryTarget(t *testing.T) {
	runtime := &fakeSelectorRuntime{results: map[string]map[string]bool{
		"":        {"web": false, "media": false},
		"partial": {"web": true, "media": false},
		"common":  {"web": true, "media": true},
	}}
	selector, err := NewSelector(runtime, runtime)
	if err != nil {
		t.Fatal(err)
	}
	result, err := selector.Select(context.Background(), selectorRequest())
	if err != nil {
		t.Fatalf("Select() error = %v", err)
	}
	if result.Strategy.ID != "common" || runtime.committed != "common" {
		t.Fatalf("selected=%q committed=%q", result.Strategy.ID, runtime.committed)
	}
	if len(result.Candidates) != 2 || result.Candidates[0].Passed || !result.Candidates[1].Passed {
		t.Fatalf("candidate results = %+v", result.Candidates)
	}
}

func TestSelectorReturnsTypedErrorAndRestoresDirect(t *testing.T) {
	runtime := &fakeSelectorRuntime{results: map[string]map[string]bool{
		"":        {"web": true, "media": false},
		"partial": {"web": true, "media": false},
		"common":  {"web": false, "media": true},
	}}
	selector, _ := NewSelector(runtime, runtime)
	_, err := selector.Select(context.Background(), selectorRequest())
	if !errors.Is(err, ErrNoCommonStrategy) {
		t.Fatalf("Select() error = %v, want ErrNoCommonStrategy", err)
	}
	if runtime.active != "" || runtime.committed != "" {
		t.Fatalf("failed selection leaked trial state: active=%q committed=%q", runtime.active, runtime.committed)
	}
}

func TestSelectorRejectsRegressionOfBaselineWorkingOptionalTarget(t *testing.T) {
	request := selectorRequest()
	request.Targets = append(request.Targets, ProbeTarget{
		ID: "already-working", Network: NetworkTCP, Kind: ProbeTCPConnect,
		Host: "example.com", Port: 443, Optional: true,
	})
	request.Candidates = []TrafficStrategy{testStrategy("regresses", 1)}
	runtime := &fakeSelectorRuntime{results: map[string]map[string]bool{
		"":          {"web": false, "media": false, "already-working": true},
		"regresses": {"web": true, "media": true, "already-working": false},
	}}
	selector, _ := NewSelector(runtime, runtime)
	_, err := selector.Select(context.Background(), request)
	if !errors.Is(err, ErrNoCommonStrategy) {
		t.Fatalf("Select() error = %v, want ErrNoCommonStrategy", err)
	}
	if runtime.active != "" || runtime.committed != "" {
		t.Fatalf("regressing trial leaked state: active=%q committed=%q", runtime.active, runtime.committed)
	}
}

func TestPacketProcessorClassifiesAndSplitsTLS(t *testing.T) {
	plan := testPlan()
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4TCPPacket(t, "discord.com")
	decision := processor.Process(packet)
	if decision.ServiceID != "discord" || decision.StrategyID != "safe" || !decision.Transformed {
		t.Fatalf("decision = %+v", decision)
	}
	if len(decision.Packets) < 3 { // fake packets + two original segments
		t.Fatalf("packet count = %d, want at least 3", len(decision.Packets))
	}
	for index, output := range decision.Packets {
		if _, err := parsePacket(output); err != nil {
			t.Fatalf("output %d is malformed: %v", index, err)
		}
	}
	counters := processor.Counters()["discord"]
	if counters.Matched != 1 || counters.Transformed != 1 || counters.Errors != 0 {
		t.Fatalf("counters = %+v", counters)
	}
}

func TestPacketProcessorClassifiesTruncatedLargeClientHello(t *testing.T) {
	packet := testIPv4TCPPacket(t, "discord.com")
	payload := packet[40:]
	binary.BigEndian.PutUint16(payload[3:5], 2000)
	payload[6], payload[7], payload[8] = 0, 7, 204
	calculateChecksums(packet)

	processor, err := NewProcessor(testPlan())
	if err != nil {
		t.Fatal(err)
	}
	decision := processor.Process(packet)
	if decision.ServiceID != "discord" || !decision.Transformed {
		t.Fatalf("truncated large ClientHello decision = %+v", decision)
	}
}

func TestZapret2MultidisorderUsesSNIAnchors(t *testing.T) {
	var strategy TrafficStrategy
	for _, candidate := range BuiltinStrategies() {
		if candidate.ID == "native-zapret2-fake-multidisorder" {
			strategy = candidate
			break
		}
	}
	if strategy.ID == "" {
		t.Fatal("zapret2 multidisorder strategy is missing")
	}
	plan := testPlan()
	plan.Strategies = []TrafficStrategy{strategy}
	plan.Services[0].CandidateStrategyIDs = []string{strategy.ID}
	plan.Selections[0].StrategyID = strategy.ID
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	original := testIPv4TCPPacket(t, "discord.com")
	decision := processor.Process(original)
	if !decision.Transformed || len(decision.Packets) != 14 {
		t.Fatalf("multidisorder decision has %d packets: %+v", len(decision.Packets), decision)
	}
	joined := make([]byte, 0, len(original)-40)
	for index := len(decision.Packets) - 1; index >= len(decision.Packets)-3; index-- {
		parsed, parseErr := parsePacket(decision.Packets[index])
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		joined = append(joined, parsed.payload()...)
	}
	if string(joined) != string(original[40:]) {
		t.Fatal("SNI-anchored disorder segments do not reconstruct the original ClientHello")
	}
}

func TestPaddedTLSAndQUICDecoysAreDistinctAndBounded(t *testing.T) {
	sessionID := []byte{1, 3, 3, 7, 9}
	originalTLS := fakeTLSClientHelloForServerNameAndSession("discord.com", sessionID, 4)
	fakeTLS := fakeTLSClientHelloLike(originalTLS)
	if got := tlsClientHelloSessionID(fakeTLS); string(got) != string(sessionID) {
		t.Fatalf("fake TLS session ID = %v, want duplicated %v", got, sessionID)
	}
	padded := padTLSClientHello(fakeTLS, 681)
	if len(padded) != 681 || extractTLSServerName(padded) != "www.google.com" {
		t.Fatalf("padded ClientHello length=%d SNI=%q", len(padded), extractTLSServerName(padded))
	}
	original := make([]byte, 1200)
	original[0] = 0xc3
	binary.BigEndian.PutUint32(original[1:5], 1)
	decoy := fakeQUICInitial(original)
	if len(decoy) != 1200 || string(decoy) == string(original) {
		t.Fatalf("QUIC decoy length=%d distinct=%v", len(decoy), string(decoy) != string(original))
	}
}

func TestPacketProcessorFailsSafeForMalformedAndUnclassified(t *testing.T) {
	processor, err := NewProcessor(testPlan())
	if err != nil {
		t.Fatal(err)
	}
	malformed := []byte{0x45, 0, 0}
	decision := processor.Process(malformed)
	if decision.Transformed || len(decision.Packets) != 1 {
		t.Fatalf("malformed decision = %+v", decision)
	}
	packet := testIPv4TCPPacket(t, "example.com")
	decision = processor.Process(packet)
	if decision.Transformed || decision.ServiceID != "" {
		t.Fatalf("unclassified decision = %+v", decision)
	}
}

func TestInvalidChecksumDecoyRemainsInvalidAfterProcessing(t *testing.T) {
	strategies := BuiltinStrategies()
	var selected TrafficStrategy
	for _, strategy := range strategies {
		if strategy.ID == "native-decoy-split" {
			selected = strategy
			break
		}
	}
	if selected.ID == "" {
		t.Fatal("native decoy strategy is missing")
	}
	plan := testPlan()
	plan.Strategies = []TrafficStrategy{selected}
	plan.Services[0].CandidateStrategyIDs = []string{selected.ID}
	plan.Selections[0].StrategyID = selected.ID
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	decision := processor.Process(testIPv4TCPPacket(t, "discord.com"))
	if !decision.Transformed || len(decision.Packets) < 6 {
		t.Fatalf("unexpected decision: %+v", decision)
	}
	for index := 0; index < 4; index++ {
		decoy := decision.Packets[index]
		valid := append([]byte(nil), decoy...)
		calculateChecksums(valid)
		if string(valid) == string(decoy) {
			t.Fatalf("decoy %d checksum was accidentally repaired", index)
		}
	}
	for index := len(decision.Packets) - 2; index < len(decision.Packets); index++ {
		segment := decision.Packets[index]
		valid := append([]byte(nil), segment...)
		calculateChecksums(valid)
		if string(valid) != string(segment) {
			t.Fatalf("real segment %d has an invalid checksum", index)
		}
	}
}

func TestProcessorDoesNotTransformUnrecognizedEncryptedMedia(t *testing.T) {
	strategies := BuiltinStrategies()
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: BuiltinCatalogRevision,
		Strategies: strategies,
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", IPCIDRs: []string{"66.22.192.0/18"},
			IPMatchPolicy: IPMatchRequireContext,
			UDPPorts:      []int{50000}, Fingerprints: []string{"discord-media"}, CandidateStrategyIDs: []string{strategies[0].ID},
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: strategies[0].ID}},
	}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	packet := testIPv4UDPPacket("66.22.200.1", 50000, []byte("opaque encrypted media"))
	decision := processor.Process(packet)
	if decision.Transformed || len(decision.Packets) != 1 {
		t.Fatalf("opaque media must pass unchanged: %+v", decision)
	}
}

func TestDiscordActiveStrategySendsBoundedDiscoveryDecoysBeforeOriginal(t *testing.T) {
	var active TrafficStrategy
	for _, strategy := range BuiltinStrategies() {
		if strategy.ID == "native-discord-active" {
			active = strategy
			break
		}
	}
	if active.ID == "" {
		t.Fatal("Discord active strategy is missing")
	}
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: BuiltinCatalogRevision,
		Strategies: []TrafficStrategy{active},
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", IPCIDRs: []string{"66.22.192.0/18"},
			IPMatchPolicy: IPMatchRequireContext,
			UDPPorts:      []int{50000}, Fingerprints: []string{"discord-media"}, CandidateStrategyIDs: []string{active.ID},
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: active.ID}},
	}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	discovery := make([]byte, 74)
	discovery[1], discovery[3] = 1, 70
	discovery[4], discovery[5], discovery[6], discovery[7] = 1, 2, 3, 4
	packet := testIPv4UDPPacket("66.22.200.1", 50000, discovery)
	decision := processor.Process(packet)
	if !decision.Transformed || len(decision.Packets) != 4 {
		t.Fatalf("decision = %#v, want exactly three decoys plus the original", decision)
	}
	for index := 0; index < 3; index++ {
		parsed, parseErr := parsePacket(decision.Packets[index])
		if parseErr != nil {
			t.Fatalf("decoy %d is malformed: %v", index, parseErr)
		}
		if string(parsed.payload()) == string(discovery) || !isDiscordDiscovery(parsed.payload()) {
			t.Fatalf("decoy %d is not a distinct valid discovery request", index)
		}
		checksummed := append([]byte(nil), decision.Packets[index]...)
		calculateChecksums(checksummed)
		if string(checksummed) != string(decision.Packets[index]) {
			t.Fatalf("decoy %d unexpectedly has an invalid checksum", index)
		}
	}
	if string(decision.Packets[3]) != string(packet) {
		t.Fatal("the original Discord discovery packet was not preserved last")
	}
}

func TestDiscordActiveV2SendsDistinctQUICShapedDecoys(t *testing.T) {
	var active TrafficStrategy
	for _, strategy := range BuiltinStrategies() {
		if strategy.ID == "native-discord-active-v2" {
			active = strategy
			break
		}
	}
	if active.ID == "" {
		t.Fatal("Discord active v2 strategy is missing")
	}
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: BuiltinCatalogRevision, Strategies: []TrafficStrategy{active},
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", IPCIDRs: []string{"66.22.192.0/18"},
			IPMatchPolicy: IPMatchRequireContext,
			UDPPorts:      []int{50000}, Fingerprints: []string{"discord-media"}, CandidateStrategyIDs: []string{active.ID},
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: active.ID}},
	}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	discovery := make([]byte, 74)
	discovery[1], discovery[3] = 1, 70
	decision := processor.Process(testIPv4UDPPacket("66.22.200.1", 50000, discovery))
	if !decision.Transformed || len(decision.Packets) != 7 {
		t.Fatalf("decision = %#v, want six decoys plus original", decision)
	}
	for index := 0; index < 3; index++ {
		parsed, parseErr := parsePacket(decision.Packets[index])
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		if len(parsed.payload()) != 1200 || parsed.payload()[0]&0xc0 != 0xc0 || string(parsed.payload()) == string(discovery) {
			t.Fatalf("decoy %d is not a distinct 1200-byte QUIC-shaped payload", index)
		}
	}
	for index := 3; index < 6; index++ {
		parsed, parseErr := parsePacket(decision.Packets[index])
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		if !isDiscordDiscovery(parsed.payload()) || string(parsed.payload()) == string(discovery) {
			t.Fatalf("decoy %d is not a distinct generated Discord discovery payload", index)
		}
	}
}

func TestDiscordNewOfficialMediaRangeUsesSignatureClassification(t *testing.T) {
	var active TrafficStrategy
	for _, strategy := range BuiltinStrategies() {
		if strategy.ID == "native-discord-active" {
			active = strategy
			break
		}
	}
	if active.ID == "" {
		t.Fatal("Discord active strategy is missing")
	}
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: "discord-19294-regression", Strategies: []TrafficStrategy{active},
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", ProcessNames: []string{"Discord.exe"},
			Fingerprints: []string{"discord-media", "stun"}, CandidateStrategyIDs: []string{active.ID},
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: active.ID}},
	}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	discovery := make([]byte, 74)
	binary.BigEndian.PutUint16(discovery[0:2], 1)
	binary.BigEndian.PutUint16(discovery[2:4], 70)
	packet := testIPv4UDPPacket("66.22.200.1", 19294, discovery)
	decision := processor.Process(packet)
	if !decision.Transformed || decision.ServiceID != "discord" || len(decision.Packets) != 4 {
		t.Fatalf("new official Discord range decision = %+v", decision)
	}
}

func TestProcessorRejectsNonMonotonicPlanRevision(t *testing.T) {
	processor, err := NewProcessor(testPlan())
	if err != nil {
		t.Fatal(err)
	}
	if err := processor.ApplyPlan(testPlan()); err == nil {
		t.Fatal("expected equal plan revision to be rejected")
	}
	next := testPlan()
	next.Revision = 2
	if err := processor.ApplyPlan(next); err != nil {
		t.Fatalf("ApplyPlan(next) error = %v", err)
	}
	if processor.Revision() != 2 {
		t.Fatalf("revision = %d", processor.Revision())
	}
}

func TestUDPProtocolFingerprints(t *testing.T) {
	stun := make([]byte, 20)
	stun[4], stun[5], stun[6], stun[7] = 0x21, 0x12, 0xa4, 0x42
	if !isSTUN(stun) {
		t.Fatal("valid STUN header was not recognized")
	}
	discord := make([]byte, 74)
	discord[1], discord[3] = 1, 70
	if !isDiscordDiscovery(discord) {
		t.Fatal("valid Discord discovery request was not recognized")
	}
	wireguard := make([]byte, 148)
	wireguard[0] = 1
	if got := wireGuardFingerprint(wireguard); got != "wireguard-initiation" {
		t.Fatalf("wireguard fingerprint = %q", got)
	}
}

type backendPacket struct {
	data    []byte
	address PacketAddress
}

type fakePacketBackend struct {
	mu       sync.Mutex
	input    []backendPacket
	output   [][]byte
	batches  int
	closed   bool
	received chan struct{}
}

func (b *fakePacketBackend) Receive(buffer []byte) (int, PacketAddress, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return 0, PacketAddress{}, ErrBackendClosed
	}
	if len(b.input) == 0 {
		return 0, PacketAddress{}, io.EOF
	}
	packet := b.input[0]
	b.input = b.input[1:]
	copy(buffer, packet.data)
	if b.received != nil {
		close(b.received)
		b.received = nil
	}
	return len(packet.data), packet.address, nil
}

func (b *fakePacketBackend) Send(packet []byte, _ *PacketAddress) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.output = append(b.output, append([]byte(nil), packet...))
	return nil
}

func (b *fakePacketBackend) SendBatch(packets [][]byte, addresses []PacketAddress) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(packets) != len(addresses) {
		return errors.New("mismatched test batch")
	}
	b.batches++
	for _, packet := range packets {
		b.output = append(b.output, append([]byte(nil), packet...))
	}
	return nil
}

func (b *fakePacketBackend) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	return nil
}

func TestEngineOwnsOneBackendLoopAndReinjectsDecision(t *testing.T) {
	processor, err := NewProcessor(testPlan())
	if err != nil {
		t.Fatal(err)
	}
	backend := &fakePacketBackend{
		input:    []backendPacket{{data: testIPv4TCPPacket(t, "discord.com")}},
		received: make(chan struct{}),
	}
	received := backend.received
	engine, err := NewEngine(backend, processor, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := engine.Start(); err != nil {
		t.Fatal(err)
	}
	<-received
	err = engine.Wait()
	if !errors.Is(err, io.EOF) {
		t.Fatalf("Wait() error = %v", err)
	}
	backend.mu.Lock()
	outputs := len(backend.output)
	batches := backend.batches
	backend.mu.Unlock()
	if outputs < 3 {
		t.Fatalf("backend outputs = %d", outputs)
	}
	if batches != 1 {
		t.Fatalf("backend batch calls = %d, want 1", batches)
	}
	stats := engine.Stats()
	if stats.CapturedPackets != 1 || stats.BatchCalls != 1 || stats.ReinjectedPackets != uint64(outputs) || stats.MaxDecisionOutputs != uint64(outputs) {
		t.Fatalf("engine stats = %+v, outputs=%d", stats, outputs)
	}
}

func TestProcessorThrottlesOnlyAStormingStrategy(t *testing.T) {
	strategy := testStrategy("burst", 1)
	strategy.TCP = []PacketAction{{Kind: ActionFake, Payload: "tls_client_hello", Repeats: 48}}
	strategy.Cost.SyntheticPackets = 48
	plan := testPlan()
	plan.Strategies = []TrafficStrategy{strategy}
	plan.Services[0].CandidateStrategyIDs = []string{strategy.ID}
	plan.Selections = []ServiceSelection{{ServiceID: "discord", StrategyID: strategy.ID}}
	processor, err := NewProcessor(plan)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(100, 0)
	processor.now = func() time.Time { return now }
	packet := testIPv4TCPPacket(t, "discord.com")
	throttled := false
	for attempt := 0; attempt < 32; attempt++ {
		decision := processor.Process(packet)
		if strings.Contains(decision.Reason, "output budget exceeded") {
			throttled = true
			if decision.Transformed || len(decision.Packets) != 1 || !bytes.Equal(decision.Packets[0], packet) {
				t.Fatalf("throttled decision = %+v", decision)
			}
			break
		}
	}
	if !throttled {
		t.Fatal("strategy packet storm was not throttled")
	}
	counters := processor.Counters()["discord"]
	if counters.Throttled != 1 || counters.Passed == 0 {
		t.Fatalf("throttled counters = %+v", counters)
	}
	now = now.Add(strategyOutputCooldown + time.Second)
	decision := processor.Process(packet)
	if !decision.Transformed || strings.Contains(decision.Reason, "output budget exceeded") {
		t.Fatalf("strategy did not recover after cooldown: %+v", decision)
	}
}

func testIPv4TCPPacket(t *testing.T, host string) []byte {
	return testIPv4TCPPacketTo(t, "1.1.1.1", host)
}

func testIPv4TCPPacketTo(t *testing.T, destination, host string) []byte {
	t.Helper()
	payload := fakeTLSClientHelloForServerName(host)
	packet := make([]byte, 20+20+len(payload))
	packet[0] = 0x45
	packet[8] = 64
	packet[9] = 6
	packet[12], packet[13], packet[14], packet[15] = 10, 0, 0, 1
	destinationBytes := netip.MustParseAddr(destination).As4()
	copy(packet[16:20], destinationBytes[:])
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	binary.BigEndian.PutUint16(packet[20:22], 50000)
	binary.BigEndian.PutUint16(packet[22:24], 443)
	binary.BigEndian.PutUint32(packet[24:28], 1000)
	packet[32] = 5 << 4
	packet[33] = 0x18
	copy(packet[40:], payload)
	calculateChecksums(packet)
	return packet
}

func testIPv4TCPPacketWithTimestampTo(t *testing.T, destination, host string) []byte {
	t.Helper()
	payload := fakeTLSClientHelloForServerName(host)
	const tcpHeaderLength = 32
	packet := make([]byte, 20+tcpHeaderLength+len(payload))
	packet[0] = 0x45
	packet[8] = 64
	packet[9] = 6
	packet[12], packet[13], packet[14], packet[15] = 10, 0, 0, 1
	destinationBytes := netip.MustParseAddr(destination).As4()
	copy(packet[16:20], destinationBytes[:])
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	binary.BigEndian.PutUint16(packet[4:6], 0x1234)
	binary.BigEndian.PutUint16(packet[20:22], 50000)
	binary.BigEndian.PutUint16(packet[22:24], 443)
	binary.BigEndian.PutUint32(packet[24:28], 1000)
	packet[32] = (tcpHeaderLength / 4) << 4
	packet[33] = 0x18
	// NOP, NOP, Timestamp(kind=8,len=10), TSval, TSecr.
	copy(packet[40:52], []byte{1, 1, 8, 10, 0, 0x0f, 0x42, 0x40, 0, 0, 0, 0})
	copy(packet[52:], payload)
	calculateChecksums(packet)
	return packet
}

func testTCPTimestampValue(t *testing.T, packet []byte) uint32 {
	t.Helper()
	parsed, err := parsePacket(packet)
	if err != nil {
		t.Fatal(err)
	}
	options := packet[parsed.transportOffset+20 : parsed.payloadOffset]
	for offset := 0; offset < len(options); {
		switch options[offset] {
		case 0:
			t.Fatal("TCP timestamp option is absent")
		case 1:
			offset++
			continue
		}
		if offset+2 > len(options) {
			t.Fatal("malformed TCP options")
		}
		length := int(options[offset+1])
		if length < 2 || offset+length > len(options) {
			t.Fatal("malformed TCP option length")
		}
		if options[offset] == 8 && length == 10 {
			return binary.BigEndian.Uint32(options[offset+2 : offset+6])
		}
		offset += length
	}
	t.Fatal("TCP timestamp option is absent")
	return 0
}

func testIPv4UDPPacket(destination string, port int, payload []byte) []byte {
	packet := make([]byte, 20+8+len(payload))
	packet[0] = 0x45
	packet[8] = 64
	packet[9] = 17
	packet[12], packet[13], packet[14], packet[15] = 192, 0, 2, 1
	destinationBytes := netip.MustParseAddr(destination).As4()
	copy(packet[16:20], destinationBytes[:])
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	binary.BigEndian.PutUint16(packet[20:22], 40000)
	binary.BigEndian.PutUint16(packet[22:24], uint16(port))
	binary.BigEndian.PutUint16(packet[24:26], uint16(8+len(payload)))
	copy(packet[28:], payload)
	calculateChecksums(packet)
	return packet
}
