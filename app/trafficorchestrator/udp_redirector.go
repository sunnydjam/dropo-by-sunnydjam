package trafficorchestrator

import (
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"
)

const (
	maxUDPRedirects = 4096
	udpRedirectTTL  = 2 * time.Minute
)

type UDPRedirectTarget struct {
	Flow      FlowTuple
	Host      string
	ServiceID string
	Route     ServiceRouteKind
}

type udpRedirectKey struct {
	remoteIP   netip.Addr
	clientPort uint16
}

type udpRedirectEntry struct {
	target  UDPRedirectTarget
	expires time.Time
}

type UDPRedirectRegistry struct {
	mu      sync.Mutex
	now     func() time.Time
	entries map[udpRedirectKey]udpRedirectEntry
}

func NewUDPRedirectRegistry() *UDPRedirectRegistry {
	return &UDPRedirectRegistry{now: time.Now, entries: make(map[udpRedirectKey]udpRedirectEntry)}
}

func (registry *UDPRedirectRegistry) Register(target UDPRedirectTarget) error {
	if registry == nil || !target.Flow.valid() || target.Flow.Network != NetworkUDP {
		return errors.New("valid UDP redirect flow is required")
	}
	if target.Route != ServiceRouteVPN || target.ServiceID == "" {
		return errors.New("UDP redirect target must be a named VPN service")
	}
	target.Host = normalizeHost(target.Host)
	key := udpRedirectKey{remoteIP: target.Flow.Destination.Unmap(), clientPort: target.Flow.SourcePort}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	if existing, ok := registry.entries[key]; ok && !sameUDPRedirectIdentity(existing.target, target) {
		return errors.New("UDP redirect tuple is ambiguous")
	}
	if len(registry.entries) >= maxUDPRedirects {
		return errors.New("UDP redirect registry is full")
	}
	registry.entries[key] = udpRedirectEntry{target: target, expires: now.Add(udpRedirectTTL)}
	return nil
}

func sameUDPRedirectIdentity(left, right UDPRedirectTarget) bool {
	return left.Flow == right.Flow && left.ServiceID == right.ServiceID && left.Route == right.Route
}

func (registry *UDPRedirectRegistry) Lookup(remoteIP netip.Addr, clientPort uint16) (UDPRedirectTarget, bool) {
	if registry == nil || !remoteIP.IsValid() || clientPort == 0 {
		return UDPRedirectTarget{}, false
	}
	key := udpRedirectKey{remoteIP: remoteIP.Unmap(), clientPort: clientPort}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	entry, ok := registry.entries[key]
	if !ok {
		return UDPRedirectTarget{}, false
	}
	entry.expires = now.Add(udpRedirectTTL)
	registry.entries[key] = entry
	return entry.target, true
}

func (registry *UDPRedirectRegistry) ResolvePeer(peer *net.UDPAddr) (UDPRedirectTarget, bool) {
	if peer == nil || peer.Port < 1 || peer.Port > 65535 {
		return UDPRedirectTarget{}, false
	}
	address, ok := netip.AddrFromSlice(peer.IP)
	if !ok {
		return UDPRedirectTarget{}, false
	}
	return registry.Lookup(address, uint16(peer.Port))
}

func (registry *UDPRedirectRegistry) pruneLocked(now time.Time) {
	for key, entry := range registry.entries {
		if !now.Before(entry.expires) {
			delete(registry.entries, key)
		}
	}
}

type UDPPacketRedirector struct {
	registry  *UDPRedirectRegistry
	relayPort uint16
}

func NewUDPPacketRedirector(registry *UDPRedirectRegistry, relayPort int) (*UDPPacketRedirector, error) {
	if registry == nil || relayPort < 1 || relayPort > 65535 {
		return nil, errors.New("UDP redirect registry and relay port are required")
	}
	return &UDPPacketRedirector{registry: registry, relayPort: uint16(relayPort)}, nil
}

func (redirector *UDPPacketRedirector) ReflectClientPacket(parsed parsedPacket, target UDPRedirectTarget) ([]byte, error) {
	if redirector == nil || parsed.network != NetworkUDP || parsed.flowTuple() != target.Flow {
		return nil, errors.New("UDP packet does not match redirect target")
	}
	if err := redirector.registry.Register(target); err != nil {
		return nil, err
	}
	packet := append([]byte(nil), parsed.bytes...)
	swapPacketAddresses(packet, parsed)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset+2:parsed.transportOffset+4], redirector.relayPort)
	calculateChecksums(packet)
	return packet, nil
}

func (redirector *UDPPacketRedirector) RestoreRelayPacket(parsed parsedPacket) ([]byte, UDPRedirectTarget, bool, error) {
	if redirector == nil || parsed.network != NetworkUDP || parsed.sourcePort != int(redirector.relayPort) {
		return nil, UDPRedirectTarget{}, false, nil
	}
	target, ok := redirector.registry.Lookup(parsed.destination, uint16(parsed.destinationPort))
	if !ok {
		return nil, UDPRedirectTarget{}, true, errors.New("UDP relay response has no active redirect flow")
	}
	packet := append([]byte(nil), parsed.bytes...)
	swapPacketAddresses(packet, parsed)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset:parsed.transportOffset+2], target.Flow.DestinationPort)
	calculateChecksums(packet)
	return packet, target, true, nil
}
