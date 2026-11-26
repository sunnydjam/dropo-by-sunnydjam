package trafficorchestrator

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"maps"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const maxFakeIPMappings = 8192

var selectiveVPNFakeIPv4Prefix = netip.MustParsePrefix("198.18.0.0/15")

type FakeIPTarget struct {
	Address   netip.Addr
	Host      string
	ServiceID string
	Route     ServiceRouteKind
}

// FakeIPDirectory gives selected domain-only VPN services and exact Zapret
// bootstrap hosts a destination that can be matched before TCP connect without
// capturing global HTTPS traffic. It owns no DNS listener and performs no
// system mutation.
type FakeIPDirectory struct {
	mu        sync.Mutex
	routing   atomic.Pointer[fakeIPRouting]
	lastUse   map[string]time.Time
	used      [1 << 11]uint64 // one bit per address in the /15, never recycle within a session
	nextSweep time.Time
	byHost    map[string]FakeIPTarget
	byAddress map[netip.Addr]FakeIPTarget
}

type fakeIPRouting struct {
	classifier       *Classifier
	routes           map[string]ServiceRouteKind
	zapretExactHosts map[string]string
}

func NewFakeIPDirectory(plan TrafficPlan) (*FakeIPDirectory, error) {
	classifier, err := NewClassifier(plan)
	if err != nil {
		return nil, err
	}
	directory := &FakeIPDirectory{lastUse: make(map[string]time.Time), byHost: make(map[string]FakeIPTarget), byAddress: make(map[netip.Addr]FakeIPTarget)}
	directory.used[0] |= 1 << 1 // 198.18.0.1 belongs to the reflection peer
	directory.routing.Store(compileFakeIPRouting(plan, classifier))
	return directory, nil
}

func compileFakeIPRouting(plan TrafficPlan, classifier *Classifier) *fakeIPRouting {
	routes := make(map[string]ServiceRouteKind, len(plan.Routes))
	for _, route := range plan.Routes {
		routes[route.ServiceID] = route.Kind
	}
	zapretExactHosts := make(map[string]string)
	for _, service := range plan.Services {
		if routes[service.ID] != ServiceRouteZapret {
			continue
		}
		for _, host := range service.ExactHosts {
			if normalized := normalizeHost(host); normalized != "" {
				zapretExactHosts[normalized] = service.ID
			}
		}
	}
	return &fakeIPRouting{classifier: classifier, routes: routes, zapretExactHosts: zapretExactHosts}
}

// ApplyPlan swaps domain classification and terminal routes together while
// retaining stable fake addresses for the lifetime of the VPN session.
func (directory *FakeIPDirectory) ApplyPlan(plan TrafficPlan) error {
	if directory == nil {
		return errors.New("fake-IP directory is nil")
	}
	classifier, err := NewClassifier(plan)
	if err != nil {
		return err
	}
	directory.applyRouting(plan, classifier)
	return nil
}

func (directory *FakeIPDirectory) applyRouting(plan TrafficPlan, classifier *Classifier) {
	routing := compileFakeIPRouting(plan, classifier)
	directory.mu.Lock()
	defer directory.mu.Unlock()
	if prev := directory.routing.Load(); prev != nil && prev.classifier == classifier && maps.Equal(prev.routes, routing.routes) {
		return
	}
	for host, target := range directory.byHost {
		next, selected := routing.forHost(host)
		if selected {
			target.ServiceID, target.Route = next.ServiceID, next.Route
		} else {
			target.Route = ServiceRouteDirect
		}
		directory.byHost[host], directory.byAddress[target.Address] = target, target
	}
	directory.routing.Store(routing)
}

// ResolveHost returns a stable session-local fake IPv4 address only when the
// immutable classifier positively identifies a selected VPN domain or an exact
// Zapret bootstrap host. Restricting Zapret to exact hosts prevents a suffix
// rule from taking over unrelated shared-provider/native traffic. Direct/work
// rules retain their normal higher priority.
func (directory *FakeIPDirectory) ResolveHost(host string) (FakeIPTarget, bool) {
	if directory == nil {
		return FakeIPTarget{}, false
	}
	host = normalizeHost(host)
	if host == "" {
		return FakeIPTarget{}, false
	}
	directory.mu.Lock()
	defer directory.mu.Unlock()
	routing := directory.routing.Load()
	if routing == nil {
		return FakeIPTarget{}, false
	}
	selection, selected := routing.forHost(host)
	if !selected {
		return FakeIPTarget{}, false
	}
	now := time.Now()
	if target, ok := directory.byHost[host]; ok {
		selection.Address = target.Address
		directory.lastUse[host] = now
		directory.byHost[host], directory.byAddress[target.Address] = selection, selection
		return selection, true
	}
	if len(directory.byHost) >= maxFakeIPMappings && !now.Before(directory.nextSweep) {
		directory.nextSweep = now.Add(time.Minute)
		for name, touched := range directory.lastUse {
			if now.Sub(touched) < 10*time.Minute {
				continue
			}
			delete(directory.byAddress, directory.byHost[name].Address)
			delete(directory.byHost, name)
			delete(directory.lastUse, name)
		}
	}
	if len(directory.byHost) >= maxFakeIPMappings {
		return selection, false
	}
	address, ok := directory.allocateLocked(host)
	if !ok {
		return selection, false
	}
	selection.Address = address
	directory.byHost[host], directory.byAddress[address] = selection, selection
	directory.lastUse[host] = now
	return selection, true
}

func (routing *fakeIPRouting) forHost(host string) (FakeIPTarget, bool) {
	classification := routing.classifier.Classify(FlowEvidence{
		Network: NetworkTCP, Port: 443, Host: host,
	})
	route := routing.routes[classification.ServiceID]
	if !classification.Matched || (route != ServiceRouteVPN && route != ServiceRouteZapret && route != ServiceRouteUnavailable) {
		return FakeIPTarget{}, false
	}
	if route == ServiceRouteZapret && routing.zapretExactHosts[host] != classification.ServiceID {
		return FakeIPTarget{}, false
	}

	return FakeIPTarget{Host: host, ServiceID: classification.ServiceID, Route: route}, true
}

func (directory *FakeIPDirectory) LookupAddress(address netip.Addr) (FakeIPTarget, bool) {
	if directory == nil || !selectiveVPNFakeIPv4Prefix.Contains(address) {
		return FakeIPTarget{}, false
	}
	directory.mu.Lock()
	defer directory.mu.Unlock()
	target, ok := directory.byAddress[address]
	if ok {
		directory.lastUse[target.Host] = time.Now()
	}
	return target, ok
}

// wasIssued distinguishes an evicted alias from a real corporate address
// inside the benchmarking prefix. An evicted alias must never leave the host.
func (directory *FakeIPDirectory) wasIssued(address netip.Addr) bool {
	if address == relayPeer4 || !selectiveVPNFakeIPv4Prefix.Contains(address) {
		return false
	}
	ip := address.As4()
	offset := int(ip[1]&1)<<16 | int(ip[2])<<8 | int(ip[3])
	directory.mu.Lock()
	defer directory.mu.Unlock()
	return directory.used[offset/64]&(1<<uint(offset%64)) != 0
}

func (directory *FakeIPDirectory) allocateLocked(host string) (netip.Addr, bool) {
	base := selectiveVPNFakeIPv4Prefix.Masked().Addr().As4()
	capacity := 1 << uint(32-selectiveVPNFakeIPv4Prefix.Bits())
	if capacity <= 2 {
		return netip.Addr{}, false
	}
	hasher := fnv.New32a()
	_, _ = hasher.Write([]byte(host))
	start := 1 + int(hasher.Sum32()%uint32(capacity-2))
	for attempt := 0; attempt < capacity-2; attempt++ {
		offset := 1 + (start-1+attempt)%(capacity-2)
		candidate := addIPv4Offset(base, offset)
		if directory.used[offset/64]&(1<<uint(offset%64)) == 0 {
			directory.used[offset/64] |= 1 << uint(offset%64)
			return candidate, true
		}
	}
	return netip.Addr{}, false
}

func addIPv4Offset(base [4]byte, offset int) netip.Addr {
	value := uint32(base[0])<<24 | uint32(base[1])<<16 | uint32(base[2])<<8 | uint32(base[3])
	value += uint32(offset)
	return netip.AddrFrom4([4]byte{byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)})
}

func validateFakeIPTarget(target FakeIPTarget) error {
	if !target.Address.IsValid() || !selectiveVPNFakeIPv4Prefix.Contains(target.Address) {
		return errors.New("address is outside the selective VPN fake-IP range")
	}
	if normalizeHost(target.Host) == "" || target.ServiceID == "" {
		return errors.New("fake-IP target host and service are required")
	}
	if target.Route != ServiceRouteVPN && target.Route != ServiceRouteZapret && target.Route != ServiceRouteUnavailable {
		return errors.New("fake-IP target route must be VPN or Zapret")
	}
	return nil
}

// DialRetiredFakeHost terminates a cached synthetic destination on the network's
// current system route after its service policy changes to Direct.
func DialRetiredFakeHost(ctx context.Context, network, host string, port uint16) (net.Conn, error) {
	host = normalizeHost(host)
	if host == "" || port == 0 {
		return nil, errors.New("invalid retired DNS mapping")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	var dialer net.Dialer
	for _, ip := range addresses {
		ip = ip.Unmap()
		if !ip.IsValid() || selectiveVPNFakeIPv4Prefix.Contains(ip) || ip.IsMulticast() || ip.IsUnspecified() {
			continue
		}
		conn, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), strconv.Itoa(int(port))))
		if dialErr == nil {
			return conn, nil
		}
		err = dialErr
	}
	if err != nil {
		return nil, fmt.Errorf("dial retired mapping %q: %w", host, err)
	}
	return nil, fmt.Errorf("system DNS returned no usable address for retired mapping %q", host)
}
