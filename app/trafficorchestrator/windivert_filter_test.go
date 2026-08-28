package trafficorchestrator

import (
	"strings"
	"testing"
)

func TestSelectiveWinDivertFilterIsNarrowAndDeterministic(t *testing.T) {
	services := []ServiceRule{
		{
			ID: "discord", ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
			IPCIDRs: []string{"66.22.192.0/18"}, IPMatchPolicy: IPMatchRequireContext, TCPPorts: []int{443, 80, 443},
		},
		{
			// A browser-only service cannot be identified before connect and must
			// not widen the NETWORK-layer capture filter.
			ID: "youtube", DomainSuffixes: []string{"youtube.com"},
		},
	}
	filter, err := BuildSelectiveWinDivertFilter(services, 32123)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		"tcp.SrcPort == 32123",
		"udp.SrcPort == 32123",
		"udp.DstPort == 53",
		"ip.DstAddr >= 198.18.0.0",
		"ip.DstAddr <= 198.19.255.255",
		"ip.DstAddr >= 66.22.192.0",
		"ip.DstAddr <= 66.22.255.255",
		"tcp.DstPort == 80",
		"tcp.DstPort == 443",
	} {
		if !strings.Contains(filter, required) {
			t.Fatalf("filter is missing %q: %s", required, filter)
		}
	}
	for _, forbidden := range []string{"youtube.com", "tcp.DstPort > 0", "udp.PayloadLength > 0", "udp.DstPort == 853", "tcp.Syn", "!tcp.Ack"} {
		if strings.Contains(filter, forbidden) {
			t.Fatalf("filter contains unsafe broad/browser match %q", forbidden)
		}
	}

	second, err := BuildSelectiveWinDivertFilter(services, 32123)
	if err != nil || second != filter {
		t.Fatalf("filter is not deterministic: err=%v", err)
	}
}

func TestVPNOnlyFilterDoesNotCaptureGlobalProcessSYN(t *testing.T) {
	services := []ServiceRule{
		{
			ID: "discord", ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
			DomainSuffixes: []string{"discord.com"}, TCPPorts: []int{443, 8443},
		},
		{ID: "browser-only", DomainSuffixes: []string{"example.com"}, TCPPorts: []int{80, 443}},
	}
	filter, err := BuildSelectiveWinDivertFilterForMode(services, 32123, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"udp.DstPort == 53", "198.18.0.0", "tcp.SrcPort == 32123"} {
		if !strings.Contains(filter, required) {
			t.Fatalf("VPN-only filter is missing %q: %s", required, filter)
		}
	}
	for _, forbidden := range []string{"tcp.DstPort == 80", "tcp.DstPort == 443", "tcp.DstPort == 8443", "tcp.Syn", "!tcp.Ack", "tcp.Payload", "udp.PayloadLength"} {
		if strings.Contains(filter, forbidden) {
			t.Fatalf("VPN-only filter contains unrelated capture %q: %s", forbidden, filter)
		}
	}
}

func TestSelectiveWinDivertFilterAddsOnlyBoundedProcessUDPDiscovery(t *testing.T) {
	services := []ServiceRule{{
		ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.media"},
		ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		ProcessDiscoveryUDPPortRanges: []PortRange{{First: 50000, Last: 50099}},
	}}
	filter, err := BuildSelectiveWinDivertFilterForMode(services, 32123, false)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(filter, "udp.DstPort >= 50000") || !strings.Contains(filter, "udp.DstPort <= 50099") {
		t.Fatalf("bounded process UDP discovery missing: %s", filter)
	}
	if strings.Contains(filter, "udp.PayloadLength") || strings.Contains(filter, "udp.DstPort > 0") {
		t.Fatalf("process UDP discovery widened capture: %s", filter)
	}
}

func TestSelectiveWinDivertFilterRejectsUnboundedProcessUDPDiscovery(t *testing.T) {
	services := []ServiceRule{{
		ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.media"},
		ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		ProcessDiscoveryUDPPortRanges: []PortRange{{First: 1, Last: 1000}},
	}}
	if _, err := BuildSelectiveWinDivertFilterForMode(services, 32123, false); err == nil {
		t.Fatal("unbounded process UDP discovery filter accepted")
	}
}

func TestSelectiveWinDivertFilterRejectsUnsafeCatalogRules(t *testing.T) {
	unsafe := []ServiceRule{{
		ID: "unsafe", ProcessNames: []string{"unsafe.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		IPCIDRs: []string{"10.0.0.0/8"}, IPMatchPolicy: IPMatchRequireContext,
	}}
	if _, err := BuildSelectiveWinDivertFilter(unsafe, 32000); err == nil {
		t.Fatal("private capture CIDR accepted")
	}
	wrongPolicy := []ServiceRule{{
		ID: "unsafe", ProcessNames: []string{"unsafe.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		IPCIDRs: []string{"203.0.113.0/24"}, IPMatchPolicy: IPMatchHostless,
	}}
	if _, err := BuildSelectiveWinDivertFilter(wrongPolicy, 32000); err == nil {
		t.Fatal("hostless service capture policy accepted")
	}
}

func TestPrefixLastAddress(t *testing.T) {
	filter, err := BuildSelectiveWinDivertFilter([]ServiceRule{{
		ID: "dual", ProcessNames: []string{"dual.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		IPCIDRs: []string{"203.0.113.5/32", "2001:4860:4860::/48"}, IPMatchPolicy: IPMatchRequireContext,
	}}, 32001)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		"ip.DstAddr == 203.0.113.5",
		"ipv6.DstAddr >= 2001:4860:4860::",
		"ipv6.DstAddr <= 2001:4860:4860:ffff:ffff:ffff:ffff:ffff",
	} {
		if !strings.Contains(filter, expected) {
			t.Fatalf("filter is missing %q: %s", expected, filter)
		}
	}
}
