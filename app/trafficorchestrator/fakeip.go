package trafficorchestrator

import (
	"errors"
	"hash/fnv"
	"net/netip"
	"sync"
	"sync/atomic"
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
	byHost    map[string]FakeIPTarget
	byAddress map[netip.Addr]FakeIPTarget
}

type fakeIPRouting struct {
	classifier       *Classifier
	routes           map[string]ServiceRouteKind
	zapretExactHosts map[string]string
}

func NewFakeIPDirectory(plan TrafficPlan) (*FakeIPDirectory, error) {
	routing, err := compileFakeIPRouting(plan)
	if err != nil {
		return nil, err
	}
	directory := &FakeIPDirectory{byHost: make(map[string]FakeIPTarget), byAddress: make(map[netip.Addr]FakeIPTarget)}
	directory.routing.Store(routing)
	return directory, nil
}

func compileFakeIPRouting(plan TrafficPlan) (*fakeIPRouting, error) {
	classifier, err := NewClassifier(plan)
	if err != nil {
		return nil, err
	}
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
	return &fakeIPRouting{classifier: classifier, routes: routes, zapretExactHosts: zapretExactHosts}, nil
}

// ApplyPlan swaps domain classification and terminal routes together while
// retaining stable fake addresses for the lifetime of the VPN session.
func (directory *FakeIPDirectory) ApplyPlan(plan TrafficPlan) error {
	if directory == nil {
		return errors.New("fake-IP directory is nil")
	}
	routing, err := compileFakeIPRouting(plan)
	if err != nil {
		return err
	}
	directory.routing.Store(routing)
	return nil
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
	routing := directory.routing.Load()
	if routing == nil {
		return FakeIPTarget{}, false
	}
	classification := routing.classifier.Classify(FlowEvidence{
		Network: NetworkTCP, Destination: "198.18.0.1", Port: 443, Host: host,
	})
	route := routing.routes[classification.ServiceID]
	if !classification.Matched || (route != ServiceRouteVPN && route != ServiceRouteZapret) {
		return FakeIPTarget{}, false
	}
	if route == ServiceRouteZapret && routing.zapretExactHosts[host] != classification.ServiceID {
		return FakeIPTarget{}, false
	}

	directory.mu.Lock()
	defer directory.mu.Unlock()
	if target, ok := directory.byHost[host]; ok {
		target.ServiceID = classification.ServiceID
		target.Route = route
		directory.byHost[host] = target
		directory.byAddress[target.Address] = target
		return target, true
	}
	if len(directory.byHost) >= maxFakeIPMappings {
		return FakeIPTarget{}, false
	}
	address, ok := directory.allocateLocked(host)
	if !ok {
		return FakeIPTarget{}, false
	}
	target := FakeIPTarget{Address: address, Host: host, ServiceID: classification.ServiceID, Route: route}
	directory.byHost[host] = target
	directory.byAddress[address] = target
	return target, true
}

func (directory *FakeIPDirectory) LookupAddress(address netip.Addr) (FakeIPTarget, bool) {
	if directory == nil || !address.IsValid() {
		return FakeIPTarget{}, false
	}
	directory.mu.Lock()
	defer directory.mu.Unlock()
	target, ok := directory.byAddress[address.Unmap()]
	if ok {
		routing := directory.routing.Load()
		if routing == nil {
			ok = false
		} else {
			route := routing.routes[target.ServiceID]
			ok = route == ServiceRouteVPN || (route == ServiceRouteZapret && routing.zapretExactHosts[target.Host] == target.ServiceID)
			if ok {
				target.Route = route
				directory.byHost[target.Host] = target
				directory.byAddress[target.Address] = target
			}
		}
	}
	return target, ok
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
		if _, used := directory.byAddress[candidate]; !used {
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
	if target.Route != ServiceRouteVPN && target.Route != ServiceRouteZapret {
		return errors.New("fake-IP target route must be VPN or Zapret")
	}
	return nil
}
