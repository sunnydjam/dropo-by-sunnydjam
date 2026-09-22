package wfpguard

import (
	"encoding/json"
	"net/netip"
	"reflect"
	"strings"
	"testing"
)

func validPolicy() Policy {
	return Policy{
		Revision:    1,
		RoutingMode: RoutingModeAllTraffic,
		UserSID:     "S-1-5-21-111-222-333-1001",
		TunnelLUID:  77,
		Endpoints: []Endpoint{{
			Process:       ProcessSingBox,
			Protocol:      ProtocolTCP,
			IP:            netip.MustParseAddr("1.1.1.1"),
			Port:          443,
			InterfaceLUID: 42,
		}},
	}
}

func TestPolicyValidateAcceptsBoundedExactEndpoints(t *testing.T) {
	t.Parallel()
	p := validPolicy()
	p.Endpoints = []Endpoint{
		{ProcessSingBox, ProtocolTCP, netip.MustParseAddr("1.1.1.1"), 443, 42},
		{ProcessXray, ProtocolUDP, netip.MustParseAddr("8.8.8.8"), 443, 42},
		{ProcessWireGuard, ProtocolUDP, netip.MustParseAddr("2606:4700:4700::1111"), 51820, 43},
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("valid policy rejected: %v", err)
	}
	if err := Validate(p); err != nil {
		t.Fatalf("Validate function rejected valid policy: %v", err)
	}

	p.Endpoints = make([]Endpoint, MaxEndpoints)
	for i := range p.Endpoints {
		p.Endpoints[i] = Endpoint{ProcessSingBox, ProtocolTCP, netip.AddrFrom4([4]byte{8, 8, 4, byte(i + 1)}), 443, 42}
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("maximum endpoint count rejected: %v", err)
	}
}

func TestPolicyValidateRejectsInvalidFields(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		change func(*Policy)
		want   string
	}{
		{"zero revision", func(p *Policy) { p.Revision = 0 }, "revision"},
		{"empty routing mode", func(p *Policy) { p.RoutingMode = "" }, "routing mode"},
		{"other routing mode", func(p *Policy) { p.RoutingMode = "selected_services" }, "routing mode"},
		{"noncanonical user SID", func(p *Policy) { p.UserSID = "s-1-5-21-1" }, "user SID"},
		{"zero tunnel LUID", func(p *Policy) { p.TunnelLUID = 0 }, "tunnel LUID"},
		{"zero endpoints", func(p *Policy) { p.Endpoints = nil }, "endpoint count"},
		{"too many endpoints", func(p *Policy) {
			p.Endpoints = make([]Endpoint, MaxEndpoints+1)
		}, "endpoint count"},
		{"unknown process", func(p *Policy) { p.Endpoints[0].Process = "powershell" }, "process"},
		{"unknown protocol", func(p *Policy) { p.Endpoints[0].Protocol = "any" }, "protocol"},
		{"invalid IP", func(p *Policy) { p.Endpoints[0].IP = netip.Addr{} }, "IP"},
		{"zero port", func(p *Policy) { p.Endpoints[0].Port = 0 }, "port"},
		{"zero physical LUID", func(p *Policy) { p.Endpoints[0].InterfaceLUID = 0 }, "interface LUID"},
		{"tunnel used as physical LUID", func(p *Policy) { p.Endpoints[0].InterfaceLUID = p.TunnelLUID }, "differ"},
		{"exact duplicate", func(p *Policy) { p.Endpoints = append(p.Endpoints, p.Endpoints[0]) }, "duplicate"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			p := validPolicy()
			tc.change(&p)
			if err := p.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate() = %v, want error containing %q", err, tc.want)
			}
		})
	}
}

func TestPolicyValidateDeduplicatesOnlyExactEndpoint(t *testing.T) {
	t.Parallel()
	p := validPolicy()
	byProcess := p.Endpoints[0]
	byProcess.Process = ProcessXray
	byProtocol := p.Endpoints[0]
	byProtocol.Protocol = ProtocolUDP
	byPort := p.Endpoints[0]
	byPort.Port = 8443
	byInterface := p.Endpoints[0]
	byInterface.InterfaceLUID = 43
	p.Endpoints = append(p.Endpoints, byProcess, byProtocol, byPort, byInterface)
	if err := p.Validate(); err != nil {
		t.Fatalf("distinct exact endpoints rejected: %v", err)
	}
}

func TestPolicyWireNamesAndRoundTrip(t *testing.T) {
	t.Parallel()
	p := validPolicy()
	data, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		`"revision"`, `"routingMode"`, `"userSid"`, `"tunnelLuid"`, `"endpoints"`,
		`"process"`, `"protocol"`, `"ip"`, `"port"`, `"interfaceLuid"`,
	} {
		if !strings.Contains(string(data), key+":") {
			t.Errorf("JSON wire field %s missing: %s", key, data)
		}
	}
	var decoded Policy
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, p) {
		t.Fatalf("round-trip changed policy: got %#v, want %#v", decoded, p)
	}
}

func TestValidateCanonicalSID(t *testing.T) {
	t.Parallel()
	valid := []string{
		"S-1-0-0",
		"S-1-5-18",
		"S-1-5-21-111-222-333-1001",
		"S-1-281474976710655-4294967295",
	}
	for _, sid := range valid {
		if err := validateCanonicalSID(sid); err != nil {
			t.Errorf("valid SID %q rejected: %v", sid, err)
		}
	}
	invalid := []string{
		"", "s-1-5-21-1", "S-2-5-21-1", "S-01-5-21-1", "S-1-5", "S-1--5-1",
		"S-1-05-21-1", "S-1-5-021-1", "S-1-+5-21-1", "S-1-5--21-1",
		"S-1-281474976710656-1", "S-1-5-4294967296", " S-1-5-21-1",
		"S-1-5-1-2-3-4-5-6-7-8-9-10-11-12-13-14-15-16",
	}
	for _, sid := range invalid {
		if err := validateCanonicalSID(sid); err == nil {
			t.Errorf("invalid SID %q accepted", sid)
		}
	}
}

func TestPolicyValidateRejectsNonPublicAddresses(t *testing.T) {
	t.Parallel()
	addresses := []string{
		"0.0.0.0", "0.1.2.3", "10.1.2.3", "100.64.0.1", "127.0.0.1",
		"169.254.1.1", "172.16.0.1", "192.0.0.8", "192.0.2.1",
		"192.88.99.1", "192.168.1.1", "198.18.0.1", "198.51.100.1",
		"203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255",
		"::", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1",
		"ff02::1", "64:ff9b::808:808", "2001::1", "2001:db8::1",
		"2002::1", "3fff::1", "2001:4860:4860::8888%eth0",
	}
	for _, text := range addresses {
		t.Run(text, func(t *testing.T) {
			t.Parallel()
			p := validPolicy()
			p.Endpoints[0].IP = netip.MustParseAddr(text)
			if err := p.Validate(); err == nil {
				t.Fatalf("non-public IP %q accepted", text)
			}
		})
	}
}
