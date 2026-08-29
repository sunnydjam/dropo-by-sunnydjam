package trafficorchestrator

import (
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestTCPRedirectRegistryConsumesReflectedTupleOnce(t *testing.T) {
	registry := NewTCPRedirectRegistry()
	target := TCPRedirectTarget{
		Flow: FlowTuple{
			Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.10"), SourcePort: 51000,
			Destination: netip.MustParseAddr("66.22.200.1"), DestinationPort: 443,
		},
		Host: "gateway.discord.com", ServiceID: "discord", Route: ServiceRouteVPN,
	}
	if err := registry.Register(target); err != nil {
		t.Fatal(err)
	}
	local := &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 34010}
	remote := &net.TCPAddr{IP: net.ParseIP("66.22.200.1"), Port: 51000}
	got, ok := registry.ConsumeAccepted(local, remote)
	if !ok || got.ServiceID != "discord" || got.Host != "gateway.discord.com" || got.Flow.DestinationPort != 443 {
		t.Fatalf("redirect target = %+v, found=%t", got, ok)
	}
	if _, ok := registry.ConsumeAccepted(local, remote); ok {
		t.Fatal("redirect target was consumed twice")
	}
}

func TestTCPRedirectRegistryExpiresAndRejectsDirect(t *testing.T) {
	registry := NewTCPRedirectRegistry()
	now := time.Unix(100, 0)
	registry.now = func() time.Time { return now }
	target := TCPRedirectTarget{
		Flow:      FlowTuple{Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.10"), SourcePort: 51000, Destination: netip.MustParseAddr("66.22.200.1"), DestinationPort: 443},
		ServiceID: "discord", Route: ServiceRouteDirect,
	}
	if err := registry.Register(target); err == nil {
		t.Fatal("non-VPN redirect target was accepted")
	}
	target.Route = ServiceRouteVPN
	if err := registry.Register(target); err != nil {
		t.Fatal(err)
	}
	now = now.Add(tcpRedirectPendingTTL)
	local := &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 34010}
	remote := &net.TCPAddr{IP: net.ParseIP("66.22.200.1"), Port: 51000}
	if _, ok := registry.ConsumeAccepted(local, remote); ok {
		t.Fatal("expired redirect target was consumed")
	}
}

func TestTCPRedirectRegistryAcceptsTypedZapretTarget(t *testing.T) {
	registry := NewTCPRedirectRegistry()
	target := TCPRedirectTarget{
		Flow: FlowTuple{
			Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.10"), SourcePort: 51000,
			Destination: netip.MustParseAddr("198.18.1.20"), DestinationPort: 443,
		},
		Host: "updates.discord.com", ServiceID: "discord", Route: ServiceRouteZapret,
	}
	if err := registry.Register(target); err != nil {
		t.Fatalf("typed Zapret redirect was rejected: %v", err)
	}
}

func TestTCPRedirectRegistryAllowsPendingRelayHandshake(t *testing.T) {
	registry := NewTCPRedirectRegistry()
	target := TCPRedirectTarget{
		Flow: FlowTuple{
			Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.10"), SourcePort: 51000,
			Destination: netip.MustParseAddr("66.22.200.1"), DestinationPort: 443,
		},
		ServiceID: "discord", Route: ServiceRouteVPN,
	}
	if err := registry.Register(target); err != nil {
		t.Fatal(err)
	}
	resolved, ok := registry.lookupReflected(target.Flow.Source, target.Flow.Destination, target.Flow.SourcePort)
	if !ok || !sameTCPRedirectIdentity(resolved, target) {
		t.Fatalf("pending reflected handshake was not resolved: %#v %v", resolved, ok)
	}

	withHost := target
	withHost.Host = "discord.com"
	if err := registry.Register(withHost); err != nil {
		t.Fatalf("late host evidence changed redirect ownership: %v", err)
	}
}
