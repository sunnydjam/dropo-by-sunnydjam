package trafficorchestrator

import (
	"bytes"
	"encoding/binary"
	"testing"
	"time"
)

func TestGameDirectProcessUsesTerminalForIssuedDNSAddress(t *testing.T) {
	plan := fakeIPTestPlan()
	plan.DirectRules = []DirectRule{{ID: "launcher", ProcessNames: []string{"steamwebhelper.exe"}}}
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	target, ok := directory.ResolveHost("www.youtube.com")
	if !ok {
		t.Fatal("missing fake answer")
	}
	registry := NewTCPRedirectRegistry()
	redirect, err := NewTCPPacketRedirector(registry, 34010)
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewProcessorWithSelectiveRuntime(plan, &fixedFlowIdentityResolver{name: "steamwebhelper.exe"}, redirect, directory)
	if err != nil {
		t.Fatal(err)
	}
	for i, want := range []ServiceRouteKind{ServiceRouteVPN, ServiceRouteDirect} {
		if i == 1 {
			plan.Revision++
			plan.Routes[0].Kind = ServiceRouteDirect
			if err := p.ApplyPlan(plan); err != nil {
				t.Fatal(err)
			}
		}
		syn := testIPv4TCPPacketTo(t, target.Address.String(), "fixture.invalid")[:40]
		binary.BigEndian.PutUint16(syn[2:4], 40)
		binary.BigEndian.PutUint16(syn[20:22], uint16(50000+i))
		syn[33] = 2
		calculateChecksums(syn)
		d := p.Process(syn)
		if d.Route != want || !d.Transformed || d.Dropped || d.Direction != PacketDirectionInbound {
			t.Fatalf("route %s, got %+v", want, d)
		}
	}
}

func TestGameSTUNRequiresServiceContext(t *testing.T) {
	plan := TrafficPlan{Revision: 1, CatalogRevision: "game", Services: []ServiceRule{{
		ID: "discord", DisplayName: "Discord", ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
		Fingerprints: []string{"stun"}, ProcessDiscoveryUDPPortRanges: []PortRange{{First: 50000, Last: 50100}},
	}}, Routes: []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteVPN}}}
	stun := make([]byte, 20)
	stun[1] = 1
	binary.BigEndian.PutUint32(stun[4:], 0x2112a442)
	for _, owner := range []string{"steamwebhelper.exe", "EADesktop.exe", "EpicGamesLauncher.exe", "Battle.net.exe", "RiotClientServices.exe", "", "Discord.exe"} {
		t.Run("owner_"+owner, func(t *testing.T) {
			udp, err := NewUDPPacketRedirector(NewUDPRedirectRegistry(), 34010)
			if err != nil {
				t.Fatal(err)
			}
			resolver := &fixedFlowIdentityResolver{name: owner}
			p, err := NewProcessorWithFullSelectiveRuntime(plan, resolver, nil, udp, nil)
			if err != nil {
				t.Fatal(err)
			}
			for i, data := range [][]byte{stun, []byte("opaque voice payload"), stun} {
				if i == 1 {
					resolver.name = ""
				}
				raw := testIPv4UDPPacket("1.2.3.4", 50005, data)
				d := p.Process(raw)
				if owner == "Discord.exe" {
					if d.Dropped || !d.Transformed || d.Route != ServiceRouteVPN {
						t.Fatalf("lost voice on packet %d: %+v", i, d)
					}
				} else if d.Dropped || d.Transformed || !bytes.Equal(raw, d.Packets[0]) {
					t.Fatalf("changed game packet %d", i)
				}
			}
		})
	}
}

func TestSharedTransportsRequireServiceContext(t *testing.T) {
	for _, fp := range []string{"tls-client-hello", "http-request", "quic-initial", "stun"} {
		t.Run(fp, func(t *testing.T) {
			c, err := NewClassifier(TrafficPlan{Revision: 1, CatalogRevision: "launcher-test", Services: []ServiceRule{{
				ID: "selected", DisplayName: "Selected", DomainSuffixes: []string{"selected.test"},
				ProcessNames: []string{"selected.exe"}, Fingerprints: []string{fp},
			}}})
			if err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				host, process string
				matched       bool
			}{
				{"accounts.ea.com", "EADesktop.exe", false}, {"accounts.ea.com", "selected.exe", false},
				{"", "EADesktop.exe", false}, {"", "", false}, {"", "selected.exe", true},
				{"edge.selected.test", "EADesktop.exe", true},
			} {
				n := NetworkTCP
				if fp == "stun" || fp == "quic-initial" {
					n = NetworkUDP
				}
				got := c.Classify(FlowEvidence{Host: tc.host, ProcessName: tc.process, Fingerprints: []string{fp}, Network: n, Port: 443})
				if got.Matched != tc.matched {
					t.Fatalf("host=%q process=%q matched=%v", tc.host, tc.process, got.Matched)
				}
			}
		})
	}
}

func TestFakeDNSCapacityAndRecovery(t *testing.T) {
	d, err := NewFakeIPDirectory(fakeIPTestPlan())
	if err != nil {
		t.Fatal(err)
	}
	first, ok := d.ResolveHost("old.youtube.com")
	if !ok {
		t.Fatal("missing initial mapping")
	}
	for i := 1; i < maxFakeIPMappings; i++ {
		d.byHost[string(rune(i))] = FakeIPTarget{}
	}
	query, _ := parsePacket(testDNSQueryPacket(t, "new.youtube.com", dnsTypeA))
	answer, _, handled, err := NewDNSFakeResponder(d).Respond(query)
	if err != nil || !handled {
		t.Fatal("selected DNS escaped at capacity")
	}
	parsed, err := parsePacket(answer)
	if err != nil || parsed.payload()[3]&15 != 2 {
		t.Fatal("want DNS SERVFAIL at capacity")
	}
	d.lastUse[first.Host] = time.Now().Add(-time.Hour)
	d.nextSweep = time.Time{}
	next, ok := d.ResolveHost("new.youtube.com")
	if !ok || next.Address == first.Address || !d.wasIssued(first.Address) {
		t.Fatal("failed to recover without reassigning a stale address")
	}
}

func TestTCPReflectionSeparatesRemoteEndpointsSharingOneClientPort(t *testing.T) {
	r := NewTCPRedirectRegistry()
	first := TCPRedirectTarget{Flow: FlowTuple{Network: NetworkTCP, Source: testMustAddr("192.0.2.11"), SourcePort: 52000, Destination: testMustAddr("192.0.2.41"), DestinationPort: 443}, ServiceID: "fixture", Route: ServiceRouteVPN}
	second := first
	second.Flow.DestinationPort = 8443
	left, err := r.registerPacket(first, true)
	if err != nil {
		t.Fatal(err)
	}
	right, err := r.registerPacket(second, true)
	if err != nil || left == right {
		t.Fatalf("colliding socket reflection: %v %v %v", left, right, err)
	}
	for _, pair := range []struct {
		key  tcpRedirectKey
		want TCPRedirectTarget
	}{{left, first}, {right, second}} {
		got, ok := r.lookupReflected(pair.key.localIP, pair.key.peerIP, pair.key.clientPort)
		if !ok || got != pair.want {
			t.Fatalf("restored wrong socket: %+v", got)
		}
	}
}
