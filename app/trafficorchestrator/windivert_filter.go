package trafficorchestrator

import (
	"errors"
	"fmt"
	"net/netip"
	"sort"
	"strconv"
	"strings"
)

const maxWinDivertFilterLength = 16 * 1024

// winDivertCaptureFilter mirrors the protocol evidence understood by
// parsedPacket.flowEvidence. The default filter remains handshake/fingerprint
// scoped. Selective sessions may add bounded process-discovery port ranges;
// the immutable classifier still passes every non-matching process unchanged.
const winDivertCaptureFilter = `outbound and !loopback and !impostor and (
    (tcp and tcp.PayloadLength >= 4 and (
        (tcp.Payload[0] == 0x16 and tcp.Payload[1] == 0x03) or
        tcp.Payload32[0] == 0x47455420 or
        tcp.Payload32[0] == 0x504f5354 or
        tcp.Payload32[0] == 0x48454144 or
        tcp.Payload32[0] == 0x4f505449
    )) or
    (udp and (
        (udp.DstPort == 443 and udp.PayloadLength >= 5 and
            udp.Payload[0] >= 0x80 and udp.Payload32[1] != 0) or
        (udp.PayloadLength >= 20 and udp.Payload[0] < 0x40 and
            udp.Payload32[1] == 0x2112a442) or
        (udp.PayloadLength == 74 and udp.Payload32[0] == 0x00010046 and
            udp.Payload32[2] == 0 and udp.Payload32[3] == 0 and
            udp.Payload32[4] == 0 and udp.Payload32[5] == 0 and
            udp.Payload32[6] == 0 and udp.Payload32[7] == 0 and
            udp.Payload32[8] == 0 and udp.Payload32[9] == 0 and
            udp.Payload32[10] == 0 and udp.Payload32[11] == 0 and
            udp.Payload32[12] == 0 and udp.Payload32[13] == 0 and
            udp.Payload32[14] == 0 and udp.Payload32[15] == 0 and
            udp.Payload32[16] == 0 and udp.Payload32[17] == 0) or
        (udp.PayloadLength == 148 and udp.Payload32[0] == 0x01000000) or
        (udp.PayloadLength == 92 and udp.Payload32[0] == 0x02000000) or
        (udp.PayloadLength == 64 and udp.Payload32[0] == 0x03000000)
    ))
)`

// BuildSelectiveWinDivertFilter extends the protocol-evidence filter with the
// complete TCP streams that the selective VPN relay can identify before the
// first packet leaves the machine. A CIDR is not sufficient identity: the
// matching service must also have a curated executable identity. This keeps
// shared CDNs and unknown game traffic out of the user-mode packet path.
//
// The resulting filter is intentionally stable for the lifetime of one
// WinDivert handle. Callers may pass a safe catalog superset; the active
// immutable TrafficPlan still decides whether a captured flow is Direct or VPN.
func BuildSelectiveWinDivertFilter(services []ServiceRule, relayPort int) (string, error) {
	return BuildSelectiveWinDivertFilterForMode(services, relayPort, true)
}

// BuildSelectiveWinDivertFilterForMode omits global protocol-payload inspection
// when free-access packet strategies are disabled for the session. Native-app
// bootstrap hosts are mapped into the fake-IP range before connect, so there is
// no reason to capture every application's initial HTTPS SYN. VPN-only selective
// routing captures DNS, fake-IP destinations, relay responses and the bounded
// process+CIDR catalog. Unrelated TLS/QUIC traffic (Steam, games and other direct
// applications) never enters user mode.
func BuildSelectiveWinDivertFilterForMode(services []ServiceRule, relayPort int, captureProtocolEvidence bool) (string, error) {
	if relayPort < 1 || relayPort > 65535 {
		return "", errors.New("TCP relay port is outside 1..65535")
	}
	type captureRule struct {
		network Network
		cidr    string
		ports   string
	}
	rules := make(map[captureRule]struct{})
	processUDPDiscovery := make(map[PortRange]struct{})
	for _, service := range services {
		if err := validateProcessDiscoveryUDPPortRanges(service); err != nil {
			return "", fmt.Errorf("service %q: %w", service.ID, err)
		}
		if service.ProcessMatchPolicy != ProcessMatchIdentity || len(service.ProcessNames) == 0 {
			continue
		}
		for _, portRange := range service.ProcessDiscoveryUDPPortRanges {
			processUDPDiscovery[portRange] = struct{}{}
		}
		if len(service.IPCIDRs) == 0 {
			continue
		}
		if service.IPMatchPolicy != IPMatchRequireContext {
			return "", fmt.Errorf("service %q cannot enter the selective capture catalog with IP policy %q", service.ID, service.IPMatchPolicy)
		}
		tcpPorts, err := winDivertPortClause(NetworkTCP, service.TCPPorts)
		if err != nil {
			return "", fmt.Errorf("service %q: %w", service.ID, err)
		}
		udpPorts, err := winDivertPortClause(NetworkUDP, service.UDPPorts)
		if err != nil {
			return "", fmt.Errorf("service %q: %w", service.ID, err)
		}
		for _, rawCIDR := range service.IPCIDRs {
			prefix, err := netip.ParsePrefix(strings.TrimSpace(rawCIDR))
			if err != nil {
				return "", fmt.Errorf("service %q has invalid capture CIDR %q: %w", service.ID, rawCIDR, err)
			}
			prefix = prefix.Masked()
			if !publicUnicastPrefix(prefix) {
				return "", fmt.Errorf("service %q capture CIDR %q is not public unicast", service.ID, rawCIDR)
			}
			clause, err := winDivertCIDRClause(prefix)
			if err != nil {
				return "", fmt.Errorf("service %q capture CIDR %q: %w", service.ID, rawCIDR, err)
			}
			rules[captureRule{network: NetworkTCP, cidr: clause, ports: tcpPorts}] = struct{}{}
			rules[captureRule{network: NetworkUDP, cidr: clause, ports: udpPorts}] = struct{}{}
		}
	}

	ordered := make([]captureRule, 0, len(rules))
	for rule := range rules {
		ordered = append(ordered, rule)
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].network != ordered[j].network {
			return ordered[i].network < ordered[j].network
		}
		if ordered[i].cidr == ordered[j].cidr {
			return ordered[i].ports < ordered[j].ports
		}
		return ordered[i].cidr < ordered[j].cidr
	})
	fakeClause, err := winDivertCIDRClause(selectiveVPNFakeIPv4Prefix)
	if err != nil {
		return "", err
	}
	tcpClauses := []string{fakeClause}
	udpClauses := []string{fakeClause}
	discoveryRanges := make([]PortRange, 0, len(processUDPDiscovery))
	for portRange := range processUDPDiscovery {
		discoveryRanges = append(discoveryRanges, portRange)
	}
	sort.Slice(discoveryRanges, func(i, j int) bool {
		if discoveryRanges[i].First == discoveryRanges[j].First {
			return discoveryRanges[i].Last < discoveryRanges[j].Last
		}
		return discoveryRanges[i].First < discoveryRanges[j].First
	})
	for _, portRange := range discoveryRanges {
		udpClauses = append(udpClauses, winDivertPortRangeClause(NetworkUDP, portRange))
	}
	for _, rule := range ordered {
		clause := rule.cidr
		if rule.ports != "" {
			clause = "(" + clause + " and " + rule.ports + ")"
		}
		if rule.network == NetworkTCP {
			tcpClauses = append(tcpClauses, clause)
		} else {
			udpClauses = append(udpClauses, clause)
		}
	}

	parts := make([]string, 0, 6)
	if captureProtocolEvidence {
		parts = append(parts, "("+winDivertCaptureFilter+")")
	}
	parts = append(parts,
		fmt.Sprintf("(outbound and !impostor and tcp and tcp.SrcPort == %d)", relayPort),
		fmt.Sprintf("(outbound and !impostor and udp and udp.SrcPort == %d)", relayPort),
		"(outbound and !loopback and !impostor and udp and udp.DstPort == 53)",
	)
	parts = append(parts,
		"(outbound and !loopback and !impostor and tcp and ("+strings.Join(tcpClauses, " or ")+"))",
		"(outbound and !loopback and !impostor and udp and ("+strings.Join(udpClauses, " or ")+"))",
	)
	filter := strings.Join(parts, " or ")
	if len(filter) > maxWinDivertFilterLength {
		return "", fmt.Errorf("selective WinDivert filter is too large: %d bytes", len(filter))
	}
	return filter, nil
}

func winDivertPortRangeClause(network Network, portRange PortRange) string {
	field := "udp.DstPort"
	if network == NetworkTCP {
		field = "tcp.DstPort"
	}
	if portRange.First == portRange.Last {
		return fmt.Sprintf("(%s == %d)", field, portRange.First)
	}
	return fmt.Sprintf("(%s >= %d and %s <= %d)", field, portRange.First, field, portRange.Last)
}

func winDivertPortClause(network Network, ports []int) (string, error) {
	field := ""
	switch network {
	case NetworkTCP:
		field = "tcp.DstPort"
	case NetworkUDP:
		field = "udp.DstPort"
	default:
		return "", fmt.Errorf("unsupported port-clause network %q", network)
	}
	if len(ports) == 0 {
		return "", nil
	}
	unique := make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port < 1 || port > 65535 {
			return "", fmt.Errorf("%s port %d is outside 1..65535", network, port)
		}
		unique[port] = struct{}{}
	}
	ordered := make([]int, 0, len(unique))
	for port := range unique {
		ordered = append(ordered, port)
	}
	sort.Ints(ordered)
	clauses := make([]string, 0, len(ordered))
	for _, port := range ordered {
		clauses = append(clauses, field+" == "+strconv.Itoa(port))
	}
	return "(" + strings.Join(clauses, " or ") + ")", nil
}

func winDivertCIDRClause(prefix netip.Prefix) (string, error) {
	first := prefix.Masked().Addr()
	last, err := prefixLastAddress(prefix)
	if err != nil {
		return "", err
	}
	family := "ip"
	field := "ip.DstAddr"
	if first.Is6() {
		family = "ipv6"
		field = "ipv6.DstAddr"
	}
	if first == last {
		return fmt.Sprintf("(%s and %s == %s)", family, field, first), nil
	}
	return fmt.Sprintf("(%s and %s >= %s and %s <= %s)", family, field, first, field, last), nil
}

func prefixLastAddress(prefix netip.Prefix) (netip.Addr, error) {
	if !prefix.IsValid() {
		return netip.Addr{}, errors.New("invalid prefix")
	}
	prefix = prefix.Masked()
	address := prefix.Addr()
	bytes := append([]byte(nil), address.AsSlice()...)
	hostBits := address.BitLen() - prefix.Bits()
	for bit := 0; bit < hostBits; bit++ {
		byteIndex := len(bytes) - 1 - bit/8
		bytes[byteIndex] |= 1 << uint(bit%8)
	}
	last, ok := netip.AddrFromSlice(bytes)
	if !ok {
		return netip.Addr{}, errors.New("failed to form prefix end address")
	}
	return last.Unmap(), nil
}

func publicUnicastPrefix(prefix netip.Prefix) bool {
	if !prefix.IsValid() {
		return false
	}
	first := prefix.Masked().Addr()
	last, err := prefixLastAddress(prefix)
	if err != nil {
		return false
	}
	for _, address := range []netip.Addr{first, last} {
		if !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() || address.IsUnspecified() || address.IsMulticast() {
			return false
		}
	}
	return true
}
