package wfpguard

import (
	"net/netip"
	"strings"
	"testing"

	traffic "dropo/trafficorchestrator"
)

func selectiveReviewFixture() traffic.TrafficPlan {
	return traffic.TrafficPlan{
		Revision: 9, CatalogRevision: "test-catalog",
		Services: []traffic.ServiceRule{
			{ID: "video", DisplayName: "Video", DomainSuffixes: []string{"video.example"},
				IPCIDRs: []string{"104.16.0.0/12"}, IPMatchPolicy: traffic.IPMatchRequireContext,
				TCPPorts: []int{443}},
			{ID: "generic", DisplayName: "Generic blocked IP", IPCIDRs: []string{"8.8.8.0/24"},
				IPMatchPolicy: traffic.IPMatchHostless, TCPPorts: []int{443}},
			{ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.example"},
				IPCIDRs: []string{"66.22.200.0/24"}, IPMatchPolicy: traffic.IPMatchRequireContext,
				ProcessNames: []string{"discord.exe"}, ProcessMatchPolicy: traffic.ProcessMatchIdentity,
				Fingerprints: []string{"discord-media", "stun"}, UDPPorts: []int{50000}},
		},
		Routes: []traffic.ServiceRoute{
			{ServiceID: "video", Kind: traffic.ServiceRouteVPN},
			{ServiceID: "generic", Kind: traffic.ServiceRouteVPN},
			{ServiceID: "discord", Kind: traffic.ServiceRouteVPN},
		},
		WorkNetworks: []traffic.WorkNetworkRule{{ID: "corp", IPCIDRs: []string{"66.22.200.128/25"}}},
		DirectRules:  []traffic.DirectRule{{ID: "steam", ProcessNames: []string{"steamwebhelper.exe"}}},
	}
}

func selectiveReviewFlow(destination, host, process string, port uint16, network traffic.Network) (traffic.FlowTuple, traffic.FlowEvidence) {
	address := netip.MustParseAddr(destination)
	source := netip.MustParseAddr("192.168.1.5")
	if address.Is6() {
		source = netip.MustParseAddr("fd00::5")
	}
	tuple := traffic.FlowTuple{
		Network: network, Source: source, SourcePort: 51000,
		Destination: address, DestinationPort: port,
	}
	return tuple, traffic.FlowEvidence{Network: network, Destination: destination, Port: int(port), Host: host, ProcessName: process}
}

func selectiveRoutedFlow(serviceID string) traffic.FlowDecision {
	return traffic.FlowDecision{PlanRevision: 9, Disposition: traffic.FlowService, Route: traffic.ServiceRouteVPN, ServiceID: serviceID}
}

func TestSelectiveReviewRequiresExactPositiveServiceEvidence(t *testing.T) {
	t.Parallel()
	policy, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, selectiveReviewFixture())
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name, destination, host, process string
		want                             SelectiveReviewDisposition
	}{
		{"selected SNI on shared address", "104.16.1.2", "watch.video.example", "browser.exe", SelectiveGuardObservedFlow},
		{"unrelated SNI on same shared address", "104.16.1.2", "store.unrelated.example", "browser.exe", SelectivePreserveDirect},
		{"unclassified IP", "1.1.1.1", "", "browser.exe", SelectivePreserveDirect},
		{"known unrelated host overrides generic blocked IP", "8.8.8.8", "safe.example", "browser.exe", SelectivePreserveDirect},
		{"hostless generic IP cannot establish WFP service identity", "8.8.8.8", "", "browser.exe", SelectiveUnsupportedFlow},
		{"explicit direct process overrides selected host", "104.16.1.2", "watch.video.example", "steamwebhelper.exe", SelectivePreserveDirect},
		{"work CIDR overrides Discord host", "66.22.200.200", "media.discord.example", "discord.exe", SelectivePreserveDirect},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			tuple, evidence := selectiveReviewFlow(test.destination, test.host, test.process, 443, traffic.NetworkTCP)
			serviceID := "video"
			if test.destination == "8.8.8.8" {
				serviceID = "generic"
			}
			decision, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow(serviceID))
			if err != nil || decision.Disposition != test.want {
				t.Fatalf("decision = %+v, %v; want %s", decision, err, test.want)
			}
		})
	}
}

func TestSelectiveReviewPreservesPrivateAndNonVPNRoutes(t *testing.T) {
	t.Parallel()
	plan := selectiveReviewFixture()
	plan.Routes[0].Kind = traffic.ServiceRouteZapret
	policy, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, plan)
	if err != nil {
		t.Fatal(err)
	}
	tuple, evidence := selectiveReviewFlow("104.16.1.2", "watch.video.example", "browser.exe", 443, traffic.NetworkTCP)
	decision, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("video"))
	if err != nil || decision.Disposition != SelectivePreserveDirect {
		t.Fatalf("Zapret route must not become VPN guard: %+v, %v", decision, err)
	}
	tuple, evidence = selectiveReviewFlow("10.10.1.2", "watch.video.example", "browser.exe", 443, traffic.NetworkTCP)
	decision, err = policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("video"))
	if err != nil || decision.Disposition != SelectivePreserveDirect {
		t.Fatalf("private destination must remain outside public VPN guard: %+v, %v", decision, err)
	}
}

func TestSelectiveReviewRejectsBroadProcessAndGenericFingerprint(t *testing.T) {
	t.Parallel()
	policy, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, selectiveReviewFixture())
	if err != nil {
		t.Fatal(err)
	}
	tuple, evidence := selectiveReviewFlow("66.22.200.1", "unrelated.example", "discord.exe", 50000, traffic.NetworkUDP)
	decision, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("discord"))
	if err != nil || decision.Disposition != SelectiveUnsupportedFlow {
		t.Fatalf("process plus shared address must remain unsupported: %+v, %v", decision, err)
	}
	evidence.Host = ""
	evidence.Fingerprints = []string{"stun"}
	decision, err = policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("discord"))
	if err != nil || decision.Disposition != SelectiveUnsupportedFlow {
		t.Fatalf("generic STUN fingerprint must remain unsupported: %+v, %v", decision, err)
	}
	evidence.Fingerprints = []string{"discord-media"}
	decision, err = policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("discord"))
	if err != nil || decision.Disposition != SelectiveGuardObservedFlow {
		t.Fatalf("scoped Discord media discovery should be reviewable: %+v, %v", decision, err)
	}
}

func TestSelectiveReviewNeedsCurrentMatchingPacketEngineDecision(t *testing.T) {
	t.Parallel()
	policy, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, selectiveReviewFixture())
	if err != nil {
		t.Fatal(err)
	}
	tuple, evidence := selectiveReviewFlow("104.16.1.2", "watch.video.example", "browser.exe", 443, traffic.NetworkTCP)
	for _, test := range []struct {
		name   string
		routed traffic.FlowDecision
		want   SelectiveReviewDisposition
	}{
		{"missing decision", traffic.FlowDecision{}, SelectiveUnsupportedFlow},
		{"stale decision", traffic.FlowDecision{PlanRevision: 8, Disposition: traffic.FlowService, Route: traffic.ServiceRouteVPN, ServiceID: "video"}, SelectiveUnsupportedFlow},
		{"other service", selectiveRoutedFlow("discord"), SelectiveUnsupportedFlow},
		{"established direct flow", traffic.FlowDecision{PlanRevision: 9, Disposition: traffic.FlowDirect}, SelectivePreserveDirect},
		{"work-network flow", traffic.FlowDecision{PlanRevision: 9, Disposition: traffic.FlowWorkNetwork}, SelectivePreserveDirect},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			decision, err := policy.ReviewObservedFlow(9, tuple, evidence, test.routed)
			if err != nil || decision.Disposition != test.want {
				t.Fatalf("decision = %+v, %v; want %s", decision, err, test.want)
			}
		})
	}
}

func TestSelectiveReviewRejectsInvalidModePlanRevisionAndTuple(t *testing.T) {
	t.Parallel()
	plan := selectiveReviewFixture()
	if _, err := BuildSelectiveReviewPolicy(RoutingModeAllTraffic, plan); err == nil {
		t.Fatal("all-traffic plan entered selected-services reviewer")
	}
	plan.Revision = 0
	if _, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, plan); err == nil {
		t.Fatal("invalid traffic plan accepted")
	}
	plan = selectiveReviewFixture()
	plan.Services = make([]traffic.ServiceRule, maxSelectiveReviewServices+1)
	if _, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, plan); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("unbounded service policy error = %v", err)
	}
	policy, err := BuildSelectiveReviewPolicy(RoutingModeSelectedServices, selectiveReviewFixture())
	if err != nil {
		t.Fatal(err)
	}
	tuple, evidence := selectiveReviewFlow("104.16.1.2", "watch.video.example", "browser.exe", 443, traffic.NetworkTCP)
	if _, err := policy.ReviewObservedFlow(8, tuple, evidence, selectiveRoutedFlow("video")); err == nil || !strings.Contains(err.Error(), "revision") {
		t.Fatalf("stale revision error = %v", err)
	}
	evidence.Destination = "104.16.1.3"
	if _, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("video")); err == nil || !strings.Contains(err.Error(), "tuple") {
		t.Fatalf("mismatched evidence error = %v", err)
	}
	evidence.Destination = "104.16.1.2"
	tuple.DestinationPort = 0
	if _, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("video")); err == nil || !strings.Contains(err.Error(), "tuple") {
		t.Fatalf("wildcard port error = %v", err)
	}
	tuple.DestinationPort = 443
	evidence.Host = strings.Repeat("a", 254)
	if _, err := policy.ReviewObservedFlow(9, tuple, evidence, selectiveRoutedFlow("video")); err == nil || !strings.Contains(err.Error(), "bounds") {
		t.Fatalf("oversized host error = %v", err)
	}
}
