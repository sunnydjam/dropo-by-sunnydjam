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
	mu        sync.Mutex
	nextPrune time.Time
	now       func() time.Time
	entries   map[udpRedirectKey]udpRedirectEntry
	forward   map[FlowTuple]udpRedirectKey
	nextPort  uint16
}

func NewUDPRedirectRegistry() *UDPRedirectRegistry {
	return &UDPRedirectRegistry{now: time.Now, entries: make(map[udpRedirectKey]udpRedirectEntry), forward: make(map[FlowTuple]udpRedirectKey), nextPort: 49152}
}

func (registry *UDPRedirectRegistry) Register(target UDPRedirectTarget) error {
	_, err := registry.register(target)
	return err
}

func (registry *UDPRedirectRegistry) register(target UDPRedirectTarget) (uint16, error) {
	if registry == nil || !target.Flow.valid() || target.Flow.Network != NetworkUDP {
		return 0, errors.New("valid UDP redirect flow is required")
	}
	if (target.Route != ServiceRouteVPN && !(target.Route == ServiceRouteDirect && selectiveVPNFakeIPv4Prefix.Contains(target.Flow.Destination) && target.Host != "")) || target.ServiceID == "" {
		return 0, errors.New("UDP redirect target must be a named VPN service")
	}
	target.Host = normalizeHost(target.Host)
	key := udpRedirectKey{remoteIP: relayPeer(target.Flow.Destination.Unmap()), clientPort: target.Flow.SourcePort}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	if assigned, exists := registry.forward[target.Flow]; exists {
		entry := registry.entries[assigned]
		if now.Before(entry.expires) {
			if !sameUDPRedirectIdentity(entry.target, target) {
				return 0, errors.New("UDP route changed for active flow")
			}
			entry.expires = now.Add(udpRedirectTTL)
			registry.entries[assigned] = entry
			return assigned.clientPort, nil
		}
		delete(registry.entries, assigned)
		delete(registry.forward, target.Flow)
	}
	if len(registry.entries) >= maxUDPRedirects {
		return 0, errors.New("UDP redirect registry is full")
	}
	// Two destinations behind the same relay IP may share a client socket.
	// Give each reflected flow a unique peer port and restore it on replies.
	for i := 0; i <= maxUDPRedirects; i++ {
		if _, used := registry.entries[key]; !used {
			registry.entries[key] = udpRedirectEntry{target: target, expires: now.Add(udpRedirectTTL)}
			registry.forward[target.Flow] = key
			return key.clientPort, nil
		}
		key.clientPort = registry.nextPort
		registry.nextPort++
		if registry.nextPort < 49152 {
			registry.nextPort = 49152
		}
	}
	return 0, errors.New("no UDP reflection port available")
}

func (registry *UDPRedirectRegistry) targetForFlow(flow FlowTuple) (UDPRedirectTarget, bool) {
	registry.mu.Lock()
	defer registry.mu.Unlock()
	key, ok := registry.forward[flow]
	entry := registry.entries[key]
	return entry.target, ok && registry.now().Before(entry.expires)
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
	if !ok || !now.Before(entry.expires) {
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
	if now.Before(registry.nextPrune) {
		return
	}
	registry.nextPrune = now.Add(time.Second)
	for key, entry := range registry.entries {
		if !now.Before(entry.expires) {
			delete(registry.entries, key)
			delete(registry.forward, entry.target.Flow)
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
	port, err := redirector.registry.register(target)
	if err != nil {
		return nil, err
	}
	packet := append([]byte(nil), parsed.bytes...)
	setPacketEndpoints(packet, parsed, relayPeer(target.Flow.Destination), target.Flow.Source)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset:parsed.transportOffset+2], port)
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
	setPacketEndpoints(packet, parsed, target.Flow.Destination, target.Flow.Source)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset:parsed.transportOffset+2], target.Flow.DestinationPort)
	binary.BigEndian.PutUint16(packet[parsed.transportOffset+2:parsed.transportOffset+4], target.Flow.SourcePort)
	calculateChecksums(packet)
	return packet, target, true, nil
}
