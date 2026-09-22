// Package wfpguard defines the fail-closed contract for a future installed
// Windows full-tunnel WFP guard. Validation does not install or activate filters.
package wfpguard

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

const (
	RoutingModeAllTraffic = "all_traffic"
	MaxEndpoints          = 32
)

// Process is an allowlisted VPN transport identity, not an executable path.
type Process string

const (
	ProcessSingBox   Process = "sing-box"
	ProcessXray      Process = "xray"
	ProcessWireGuard Process = "wireguard"
)

type Protocol string

const (
	ProtocolTCP Protocol = "tcp"
	ProtocolUDP Protocol = "udp"
)

// Endpoint is one exact public transport destination on a physical interface.
// It cannot express a CIDR, hostname, process path, port range, or wildcard.
type Endpoint struct {
	Process       Process    `json:"process"`
	Protocol      Protocol   `json:"protocol"`
	IP            netip.Addr `json:"ip"`
	Port          uint16     `json:"port"`
	InterfaceLUID uint64     `json:"interfaceLuid"`
}

// Policy describes the narrow exception set for a full-tunnel WFP guard.
// Validation alone never implies that a guard has been installed or activated.
type Policy struct {
	Revision    uint64     `json:"revision"`
	RoutingMode string     `json:"routingMode"`
	UserSID     string     `json:"userSid"`
	TunnelLUID  uint64     `json:"tunnelLuid"`
	Endpoints   []Endpoint `json:"endpoints"`
}

// Validate is a convenience function for callers holding a Policy value.
func Validate(policy Policy) error { return policy.Validate() }

// Validate rejects ambiguous, broad, non-public, or unbounded policies before
// any future native WFP layer may attempt to stage them.
func (p Policy) Validate() error {
	if p.Revision == 0 {
		return fmt.Errorf("revision must be nonzero")
	}
	if p.RoutingMode != RoutingModeAllTraffic {
		return fmt.Errorf("routing mode must be %q", RoutingModeAllTraffic)
	}
	if err := validateCanonicalSID(p.UserSID); err != nil {
		return fmt.Errorf("user SID: %w", err)
	}
	if p.TunnelLUID == 0 {
		return fmt.Errorf("tunnel LUID must be nonzero")
	}
	if len(p.Endpoints) == 0 || len(p.Endpoints) > MaxEndpoints {
		return fmt.Errorf("endpoint count must be between 1 and %d", MaxEndpoints)
	}

	seen := make(map[Endpoint]struct{}, len(p.Endpoints))
	for i, endpoint := range p.Endpoints {
		if err := endpoint.validate(p.TunnelLUID); err != nil {
			return fmt.Errorf("endpoint %d: %w", i, err)
		}
		if _, duplicate := seen[endpoint]; duplicate {
			return fmt.Errorf("endpoint %d: duplicate endpoint", i)
		}
		seen[endpoint] = struct{}{}
	}
	return nil
}

func (e Endpoint) validate(tunnelLUID uint64) error {
	switch e.Process {
	case ProcessSingBox, ProcessXray, ProcessWireGuard:
	default:
		return fmt.Errorf("process is not allowlisted")
	}
	switch e.Protocol {
	case ProtocolTCP, ProtocolUDP:
	default:
		return fmt.Errorf("protocol is not allowlisted")
	}
	if !isPublicUnicast(e.IP) {
		return fmt.Errorf("IP must be an exact public unicast address")
	}
	if e.Port == 0 {
		return fmt.Errorf("port must be nonzero")
	}
	if e.InterfaceLUID == 0 {
		return fmt.Errorf("interface LUID must be nonzero")
	}
	if e.InterfaceLUID == tunnelLUID {
		return fmt.Errorf("interface LUID must differ from tunnel LUID")
	}
	return nil
}

// Windows SID revision 1 has a 48-bit identifier authority and 1..15 32-bit
// subauthorities. Canonical decimal components have no sign or leading zero.
// This checks syntax only; a Windows security lookup must later prove identity.
func validateCanonicalSID(sid string) error {
	// An authority can have 15 digits and each of 15 subauthorities 10.
	// Reject oversized input before splitting an untrusted IPC string.
	if len(sid) > 184 {
		return fmt.Errorf("must be a canonical revision-1 SID")
	}
	parts := strings.Split(sid, "-")
	if len(parts) < 4 || len(parts) > 18 || parts[0] != "S" || parts[1] != "1" {
		return fmt.Errorf("must be a canonical revision-1 SID")
	}
	for i := 2; i < len(parts); i++ {
		bits := 32
		if i == 2 {
			bits = 48
		}
		value, err := strconv.ParseUint(parts[i], 10, bits)
		if err != nil || strconv.FormatUint(value, 10) != parts[i] {
			return fmt.Errorf("component %d is not canonical decimal", i-1)
		}
	}
	return nil
}

var nonPublicIPv4 = [...]netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

var publicIPv6Space = netip.MustParsePrefix("2000::/3")

var nonPublicIPv6 = [...]netip.Prefix{
	netip.MustParsePrefix("2001::/23"),     // IETF special-purpose protocols
	netip.MustParsePrefix("2001:db8::/32"), // documentation
	netip.MustParsePrefix("2002::/16"),     // 6to4 transition space
	netip.MustParsePrefix("3fff::/20"),     // documentation
}

func isPublicUnicast(ip netip.Addr) bool {
	if !ip.IsValid() || ip.Zone() != "" || ip.Is4In6() || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	if ip.Is4() {
		for _, prefix := range nonPublicIPv4 {
			if prefix.Contains(ip) {
				return false
			}
		}
		return true
	}
	if !publicIPv6Space.Contains(ip) {
		return false
	}
	for _, prefix := range nonPublicIPv6 {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}
