package trafficorchestrator

import (
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"sort"
	"strings"
)

const (
	maxSyntheticPackets  = 48
	maxBufferedFlowBytes = 256 * 1024
	maxPacketPosition    = 64 * 1024
	maxSequenceDelta     = 16 * 1024 * 1024
	maxPacketPositions   = 6
	maxSyntheticPayload  = 4096
)

// ValidatePlan rejects ambiguous or unsafe plans before they reach WinDivert.
func ValidatePlan(plan TrafficPlan) error {
	if plan.Revision == 0 {
		return errors.New("traffic plan revision must be positive")
	}
	if strings.TrimSpace(plan.CatalogRevision) == "" {
		return errors.New("traffic plan catalog revision is required")
	}

	strategies := make(map[string]TrafficStrategy, len(plan.Strategies))
	for _, strategy := range plan.Strategies {
		if err := ValidateStrategy(strategy); err != nil {
			return fmt.Errorf("strategy %q: %w", strategy.ID, err)
		}
		if _, exists := strategies[strategy.ID]; exists {
			return fmt.Errorf("duplicate strategy id %q", strategy.ID)
		}
		strategies[strategy.ID] = strategy
	}

	services := make(map[string]map[string]struct{}, len(plan.Services))
	for _, service := range plan.Services {
		if err := validateServiceRule(service, strategies); err != nil {
			return fmt.Errorf("service %q: %w", service.ID, err)
		}
		if _, exists := services[service.ID]; exists {
			return fmt.Errorf("duplicate service id %q", service.ID)
		}
		candidates := make(map[string]struct{}, len(service.CandidateStrategyIDs))
		for _, candidate := range service.CandidateStrategyIDs {
			candidates[candidate] = struct{}{}
		}
		services[service.ID] = candidates
	}
	workNetworks := make(map[string]struct{}, len(plan.WorkNetworks))
	for _, network := range plan.WorkNetworks {
		if err := validateWorkNetwork(network); err != nil {
			return fmt.Errorf("work network %q: %w", network.ID, err)
		}
		if _, duplicate := workNetworks[network.ID]; duplicate {
			return fmt.Errorf("duplicate work network id %q", network.ID)
		}
		workNetworks[network.ID] = struct{}{}
	}
	directRules := make(map[string]struct{}, len(plan.DirectRules))
	for _, rule := range plan.DirectRules {
		if err := validateDirectRule(rule); err != nil {
			return fmt.Errorf("direct rule %q: %w", rule.ID, err)
		}
		if _, duplicate := directRules[rule.ID]; duplicate {
			return fmt.Errorf("duplicate direct rule id %q", rule.ID)
		}
		directRules[rule.ID] = struct{}{}
	}
	selections := make(map[string]struct{}, len(plan.Selections))
	for _, selection := range plan.Selections {
		candidates, exists := services[selection.ServiceID]
		if !exists {
			return fmt.Errorf("selection references unknown service %q", selection.ServiceID)
		}
		if _, exists := strategies[selection.StrategyID]; !exists {
			return fmt.Errorf("selection for %q references unknown strategy %q", selection.ServiceID, selection.StrategyID)
		}
		if _, allowed := candidates[selection.StrategyID]; !allowed {
			return fmt.Errorf("selection for %q uses non-candidate strategy %q", selection.ServiceID, selection.StrategyID)
		}
		if _, duplicate := selections[selection.ServiceID]; duplicate {
			return fmt.Errorf("duplicate selection for service %q", selection.ServiceID)
		}
		selections[selection.ServiceID] = struct{}{}
	}
	routes := make(map[string]ServiceRouteKind, len(plan.Routes))
	for _, route := range plan.Routes {
		if _, exists := services[route.ServiceID]; !exists {
			return fmt.Errorf("route references unknown service %q", route.ServiceID)
		}
		switch route.Kind {
		case ServiceRouteDirect, ServiceRouteVPN, ServiceRouteZapret:
		default:
			return fmt.Errorf("route for %q uses unsupported kind %q", route.ServiceID, route.Kind)
		}
		if _, duplicate := routes[route.ServiceID]; duplicate {
			return fmt.Errorf("duplicate route for service %q", route.ServiceID)
		}
		routes[route.ServiceID] = route.Kind
	}
	for serviceID := range selections {
		if kind, exists := routes[serviceID]; exists && kind != ServiceRouteZapret {
			return fmt.Errorf("strategy selection for %q requires zapret route, got %q", serviceID, kind)
		}
	}
	return nil
}

func validateDirectRule(rule DirectRule) error {
	if !validIdentifier(rule.ID) {
		return errors.New("invalid direct rule id")
	}
	if len(rule.DomainSuffixes)+len(rule.IPCIDRs)+len(rule.ProcessNames) == 0 {
		return errors.New("at least one domain suffix, CIDR or process name is required")
	}
	for _, suffix := range rule.DomainSuffixes {
		if normalizeHost(suffix) == "" {
			return fmt.Errorf("invalid domain suffix %q", suffix)
		}
	}
	for _, cidr := range rule.IPCIDRs {
		if _, err := netip.ParsePrefix(strings.TrimSpace(cidr)); err != nil {
			return fmt.Errorf("invalid CIDR %q: %w", cidr, err)
		}
	}
	for _, processName := range rule.ProcessNames {
		if normalizeProcessName(processName) == "" {
			return fmt.Errorf("invalid process name %q", processName)
		}
	}
	return nil
}

func validateWorkNetwork(network WorkNetworkRule) error {
	if !validIdentifier(network.ID) {
		return errors.New("invalid work network id")
	}
	if len(network.DomainSuffixes)+len(network.IPCIDRs) == 0 {
		return errors.New("at least one domain suffix or CIDR is required")
	}
	for _, suffix := range network.DomainSuffixes {
		if normalizeHost(suffix) == "" {
			return fmt.Errorf("invalid domain suffix %q", suffix)
		}
	}
	for _, cidr := range network.IPCIDRs {
		if _, err := netip.ParsePrefix(strings.TrimSpace(cidr)); err != nil {
			return fmt.Errorf("invalid CIDR %q: %w", cidr, err)
		}
	}
	return nil
}

// ValidateStrategy enforces bounded transformations and supported fields.
func ValidateStrategy(strategy TrafficStrategy) error {
	if !validIdentifier(strategy.ID) {
		return errors.New("invalid strategy id")
	}
	if strategy.Revision <= 0 {
		return errors.New("revision must be positive")
	}
	if strings.TrimSpace(strategy.Label) == "" {
		return errors.New("label is required")
	}
	if len(strategy.TCP) == 0 && len(strategy.UDP) == 0 {
		return errors.New("at least one TCP or UDP action is required")
	}
	if strategy.Cost.SyntheticPackets < 0 || strategy.Cost.SyntheticPackets > maxSyntheticPackets {
		return fmt.Errorf("synthetic packet cost must be within 0..%d", maxSyntheticPackets)
	}
	if strategy.Cost.BufferedBytes < 0 || strategy.Cost.BufferedBytes > maxBufferedFlowBytes {
		return fmt.Errorf("buffered byte cost must be within 0..%d", maxBufferedFlowBytes)
	}
	if strategy.Cost.Risk < 0 || strategy.Cost.Risk > 100 {
		return errors.New("risk cost must be within 0..100")
	}
	if strategy.Constraints.MaxFlowData < 0 || strategy.Constraints.MaxFlowData > maxBufferedFlowBytes {
		return fmt.Errorf("maxFlowData must be within 0..%d", maxBufferedFlowBytes)
	}
	if err := validateNetworkList(strategy.Constraints.Networks); err != nil {
		return err
	}
	for i, action := range strategy.TCP {
		if err := validateAction(NetworkTCP, action); err != nil {
			return fmt.Errorf("TCP action %d: %w", i, err)
		}
	}
	for i, action := range strategy.UDP {
		if err := validateAction(NetworkUDP, action); err != nil {
			return fmt.Errorf("UDP action %d: %w", i, err)
		}
	}
	return nil
}

func validateAction(network Network, action PacketAction) error {
	if err := validateActionPorts(action.Ports); err != nil {
		return err
	}
	if err := validateActionPortRanges(action.PortRanges); err != nil {
		return err
	}
	if err := validateActionPayloads(action.Payloads); err != nil {
		return err
	}
	switch action.Kind {
	case ActionPass:
		if action.Position != 0 || len(action.Positions) != 0 || action.SequenceDelta != 0 || action.Overlap != 0 || action.TTL != 0 || action.Repeats != 0 || action.Payload != "" || len(action.Payloads) != 0 || action.PadTo != 0 || action.InvalidSum || action.HostTemplate != "" || action.AlternateOrder || actionHasGenerationMetadata(action) {
			return errors.New("pass action cannot contain transformation fields")
		}
	case ActionFake:
		if action.Position != 0 || len(action.Positions) != 0 || action.Overlap != 0 || action.TTL != 0 || action.FakePattern != "" || action.HostTemplate != "" || action.AlternateOrder {
			return errors.New("fake action contains fields for another action kind")
		}
		if action.Repeats < 1 || action.Repeats > maxSyntheticPackets {
			return fmt.Errorf("fake repeats must be within 1..%d", maxSyntheticPackets)
		}
		if strings.TrimSpace(action.Payload) == "" {
			return errors.New("fake payload is required")
		}
		switch action.Payload {
		case "original", "tls_client_hello", "tls_auto_google", "tls_auto_ya", "tls_default", "tls_google", "tls_4pda", "tls_max", "tls_sochi", "stun_decoy", "stun2_decoy", "quic_initial", "quic_decoy", "quic_google", "discord_active", "protocol_decoy", "zero":
		default:
			return fmt.Errorf("unsupported fake payload %q", action.Payload)
		}
		if action.PadTo < 0 || action.PadTo > maxSyntheticPayload {
			return fmt.Errorf("fake padTo must be within 0..%d", maxSyntheticPayload)
		}
		if action.Payload == "zero" && action.PadTo == 0 {
			return errors.New("zero fake payload requires padTo")
		}
		if action.SequenceDelta < -maxSequenceDelta || action.SequenceDelta > maxSequenceDelta {
			return fmt.Errorf("sequenceDelta must be within %d..%d", -maxSequenceDelta, maxSequenceDelta)
		}
		if network != NetworkTCP && action.SequenceDelta != 0 {
			return errors.New("sequenceDelta is TCP-only")
		}
		if err := validateGenerationMetadata(network, action, false); err != nil {
			return err
		}
	case ActionFakeDataSplit:
		if network != NetworkTCP {
			return errors.New("fake data split is TCP-only")
		}
		if action.Position != 0 && len(action.Positions) != 0 {
			return errors.New("use either position or positions, not both")
		}
		if action.Position == 0 && len(action.Positions) == 0 {
			return errors.New("fake data split requires one position")
		}
		if len(action.Positions) > 1 {
			return errors.New("fake data split accepts exactly one position")
		}
		if action.Position < 0 || action.Position > maxPacketPosition {
			return fmt.Errorf("position must be within 1..%d", maxPacketPosition)
		}
		for _, position := range action.Positions {
			if err := validatePacketPosition(position); err != nil {
				return fmt.Errorf("position: %w", err)
			}
		}
		if action.Repeats < 1 || action.Repeats > maxSyntheticPackets/4 {
			return fmt.Errorf("fake data split repeats must be within 1..%d", maxSyntheticPackets/4)
		}
		if action.FakePattern != FakePatternZero {
			return fmt.Errorf("unsupported fake data split pattern %q", action.FakePattern)
		}
		if action.SequenceDelta < -maxSequenceDelta || action.SequenceDelta > maxSequenceDelta {
			return fmt.Errorf("sequenceDelta must be within %d..%d", -maxSequenceDelta, maxSequenceDelta)
		}
		if action.Overlap != 0 || action.TTL != 0 || action.Payload != "" || action.PadTo != 0 || action.HostTemplate != "" || action.AlternateOrder {
			return errors.New("fake data split contains fields for another action kind")
		}
		if err := validateGenerationMetadata(network, action, true); err != nil {
			return err
		}
	case ActionHostFakeSplit:
		if network != NetworkTCP {
			return errors.New("host fake split is TCP-only")
		}
		if action.Position != 0 || len(action.Positions) != 0 || action.Overlap != 0 || action.TTL != 0 || action.Payload != "" || action.PadTo != 0 || action.FakePattern != "" {
			return errors.New("host fake split contains fields for another action kind")
		}
		if action.Repeats < 1 || action.Repeats > maxSyntheticPackets/4 {
			return fmt.Errorf("host fake split repeats must be within 1..%d", maxSyntheticPackets/4)
		}
		if host := normalizeHost(action.HostTemplate); host == "" || host != strings.ToLower(strings.TrimSpace(action.HostTemplate)) {
			return errors.New("host fake split requires a normalized host template")
		}
		if action.SequenceDelta < -maxSequenceDelta || action.SequenceDelta > maxSequenceDelta {
			return fmt.Errorf("sequenceDelta must be within %d..%d", -maxSequenceDelta, maxSequenceDelta)
		}
		if err := validateGenerationMetadata(network, action, false); err != nil {
			return err
		}
	case ActionSplit, ActionDisorder:
		if network != NetworkTCP {
			return fmt.Errorf("%s is TCP-only", action.Kind)
		}
		if action.Position != 0 && len(action.Positions) != 0 {
			return errors.New("use either position or positions, not both")
		}
		if action.Position == 0 && len(action.Positions) == 0 {
			return errors.New("at least one position is required")
		}
		if action.Position < 0 || action.Position > maxPacketPosition {
			return fmt.Errorf("position must be within 1..%d", maxPacketPosition)
		}
		if len(action.Positions) > maxPacketPositions {
			return fmt.Errorf("at most %d positions are allowed", maxPacketPositions)
		}
		for index, position := range action.Positions {
			if err := validatePacketPosition(position); err != nil {
				return fmt.Errorf("position %d: %w", index, err)
			}
		}
		if action.Overlap < 0 || action.Overlap > maxPacketPosition {
			return fmt.Errorf("overlap must be within 0..%d", maxPacketPosition)
		}
		if (action.Overlap == 0) != (strings.TrimSpace(action.Payload) == "") {
			return errors.New("split overlap and overlap payload must be set together")
		}
		if action.Payload != "" && !supportedPatternPayload(action.Payload) {
			return fmt.Errorf("unsupported split overlap payload %q", action.Payload)
		}
		if action.SequenceDelta != 0 || action.TTL != 0 || action.Repeats != 0 || action.PadTo != 0 || action.InvalidSum || action.TCPFooling != "" || action.TimestampDelta != 0 || action.FakePattern != "" || action.HostTemplate != "" || action.AlternateOrder {
			return fmt.Errorf("%s action contains fields for another action kind", action.Kind)
		}
		if action.IPv4ID != "" && action.IPv4ID != IPv4IDZero {
			return fmt.Errorf("unsupported IPv4 ID mode %q", action.IPv4ID)
		}
	case ActionTTL:
		if action.TTL < 1 || action.TTL > 255 {
			return errors.New("ttl must be within 1..255")
		}
		if action.Position != 0 || len(action.Positions) != 0 || action.SequenceDelta != 0 || action.Overlap != 0 || action.Repeats != 0 || action.Payload != "" || len(action.Payloads) != 0 || action.PadTo != 0 || action.InvalidSum || action.HostTemplate != "" || action.AlternateOrder || actionHasGenerationMetadata(action) {
			return errors.New("ttl action contains fields for another action kind")
		}
	case ActionSequenceOverlap:
		if network != NetworkTCP {
			return errors.New("sequence overlap is TCP-only")
		}
		if action.Overlap < 1 || action.Overlap > maxPacketPosition {
			return fmt.Errorf("overlap must be within 1..%d", maxPacketPosition)
		}
		if action.Position != 0 || len(action.Positions) != 0 || action.SequenceDelta != 0 || action.TTL != 0 || action.Repeats != 0 || action.Payload != "" || len(action.Payloads) != 0 || action.PadTo != 0 || action.InvalidSum || action.HostTemplate != "" || action.AlternateOrder || actionHasGenerationMetadata(action) {
			return errors.New("sequence overlap contains fields for another action kind")
		}
	case ActionRepeat:
		if action.Repeats < 1 || action.Repeats > maxSyntheticPackets {
			return fmt.Errorf("repeats must be within 1..%d", maxSyntheticPackets)
		}
		if action.Position != 0 || len(action.Positions) != 0 || action.SequenceDelta != 0 || action.Overlap != 0 || action.TTL != 0 || action.Payload != "" || len(action.Payloads) != 0 || action.PadTo != 0 || action.InvalidSum || action.HostTemplate != "" || action.AlternateOrder || actionHasGenerationMetadata(action) {
			return errors.New("repeat action contains fields for another action kind")
		}
	default:
		return fmt.Errorf("unsupported action kind %q", action.Kind)
	}
	return nil
}

func validateActionPayloads(payloads []string) error {
	if len(payloads) > 8 {
		return errors.New("an action may target at most 8 payload fingerprints")
	}
	seen := make(map[string]struct{}, len(payloads))
	for _, payload := range payloads {
		switch payload {
		case "http-request", "tls-client-hello", "quic-initial", "stun", "discord-media", "wireguard-initiation", "wireguard-cookie":
		default:
			return fmt.Errorf("unsupported action payload fingerprint %q", payload)
		}
		if _, duplicate := seen[payload]; duplicate {
			return fmt.Errorf("duplicate action payload fingerprint %q", payload)
		}
		seen[payload] = struct{}{}
	}
	return nil
}

func supportedPatternPayload(payload string) bool {
	switch payload {
	case "zero", "tls_google", "tls_4pda", "tls_max", "tls_sochi", "stun_decoy", "stun2_decoy":
		return true
	default:
		return false
	}
}

func validateActionPorts(ports []int) error {
	if len(ports) > 16 {
		return errors.New("an action may target at most 16 ports")
	}
	seen := make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port < 1 || port > 65535 {
			return fmt.Errorf("action port %d is outside 1..65535", port)
		}
		if _, duplicate := seen[port]; duplicate {
			return fmt.Errorf("duplicate action port %d", port)
		}
		seen[port] = struct{}{}
	}
	return nil
}

func validateActionPortRanges(ranges []PortRange) error {
	if len(ranges) > 8 {
		return errors.New("an action may target at most 8 port ranges")
	}
	totalPorts := 0
	for _, portRange := range ranges {
		if portRange.First < 1 || portRange.Last > 65535 || portRange.First > portRange.Last {
			return fmt.Errorf("action port range %d..%d is invalid", portRange.First, portRange.Last)
		}
		totalPorts += portRange.Last - portRange.First + 1
	}
	if totalPorts > 512 {
		return errors.New("action port ranges may cover at most 512 ports")
	}
	return nil
}

func actionHasGenerationMetadata(action PacketAction) bool {
	return action.TCPFooling != "" || action.TimestampDelta != 0 || action.IPv4ID != "" || action.FakePattern != ""
}

func validateGenerationMetadata(network Network, action PacketAction, allowPattern bool) error {
	if action.TCPFooling != "" || action.TimestampDelta != 0 {
		if network != NetworkTCP {
			return errors.New("TCP fooling is TCP-only")
		}
		if action.TCPFooling != TCPFoolingTimestamp && action.TCPFooling != TCPFoolingTimestampOrBadSum {
			return fmt.Errorf("unsupported TCP fooling %q", action.TCPFooling)
		}
		if action.TimestampDelta == 0 {
			return errors.New("timestamp fooling requires a non-zero delta")
		}
		if int64(action.TimestampDelta) < -2147483648 || int64(action.TimestampDelta) > 2147483647 {
			return errors.New("timestamp delta is outside signed 32-bit range")
		}
	}
	if action.IPv4ID != "" && action.IPv4ID != IPv4IDZero {
		return fmt.Errorf("unsupported IPv4 ID mode %q", action.IPv4ID)
	}
	if !allowPattern && action.FakePattern != "" {
		return errors.New("fake pattern is not allowed for this action")
	}
	return nil
}

func validatePacketPosition(position PacketPosition) error {
	if position.Absolute != 0 && strings.TrimSpace(position.Anchor) != "" {
		return errors.New("absolute and anchor are mutually exclusive")
	}
	if position.Absolute != 0 {
		if position.Absolute < 1 || position.Absolute > maxPacketPosition {
			return fmt.Errorf("absolute position must be within 1..%d", maxPacketPosition)
		}
		if position.Offset != 0 {
			return errors.New("absolute position cannot have an offset")
		}
		return nil
	}
	switch position.Anchor {
	case "tls-sni-start", "tls-sni-middle", "tls-sni-middle-sld", "tls-sni-end", "tls-sni-extension-start":
	default:
		return fmt.Errorf("unsupported anchor %q", position.Anchor)
	}
	if position.Offset < -maxPacketPosition || position.Offset > maxPacketPosition {
		return fmt.Errorf("anchor offset must be within %d..%d", -maxPacketPosition, maxPacketPosition)
	}
	return nil
}

func validateServiceRule(service ServiceRule, strategies map[string]TrafficStrategy) error {
	if !validIdentifier(service.ID) {
		return errors.New("invalid service id")
	}
	if strings.TrimSpace(service.DisplayName) == "" {
		return errors.New("display name is required")
	}
	if len(service.ExactHosts)+len(service.DomainSuffixes)+len(service.IPCIDRs)+len(service.Fingerprints) == 0 {
		return errors.New("at least one host, CIDR or protocol fingerprint is required")
	}
	for _, host := range append(append([]string(nil), service.ExactHosts...), service.DomainSuffixes...) {
		if normalizeHost(host) == "" {
			return fmt.Errorf("invalid host %q", host)
		}
	}
	if len(service.ProcessNames) == 0 {
		if service.ProcessMatchPolicy != "" {
			return errors.New("processMatchPolicy requires at least one process name")
		}
	} else {
		switch service.ProcessMatchPolicy {
		case "", ProcessMatchCorroborate, ProcessMatchIdentity:
		default:
			return fmt.Errorf("unsupported processMatchPolicy %q", service.ProcessMatchPolicy)
		}
		for _, processName := range service.ProcessNames {
			if normalizeProcessName(processName) == "" {
				return fmt.Errorf("invalid process name %q", processName)
			}
		}
	}
	for _, cidr := range service.IPCIDRs {
		if _, err := netip.ParsePrefix(strings.TrimSpace(cidr)); err != nil {
			return fmt.Errorf("invalid CIDR %q: %w", cidr, err)
		}
	}
	if len(service.IPCIDRs) == 0 {
		if service.IPMatchPolicy != "" {
			return errors.New("ipMatchPolicy requires at least one CIDR")
		}
	} else {
		switch service.IPMatchPolicy {
		case IPMatchRequireContext:
			if len(service.ExactHosts)+len(service.DomainSuffixes)+len(service.ProcessNames)+len(service.Fingerprints) == 0 {
				return errors.New("require_context IP policy requires host, process or fingerprint evidence")
			}
		case IPMatchHostless:
		default:
			return fmt.Errorf("unsupported ipMatchPolicy %q", service.IPMatchPolicy)
		}
	}
	if err := validatePorts(NetworkTCP, service.TCPPorts); err != nil {
		return err
	}
	if err := validatePorts(NetworkUDP, service.UDPPorts); err != nil {
		return err
	}
	if err := validateProcessDiscoveryTCPPorts(service); err != nil {
		return err
	}
	if err := validateProcessDiscoveryUDPPortRanges(service); err != nil {
		return err
	}
	seenStrategies := make(map[string]struct{}, len(service.CandidateStrategyIDs))
	for _, id := range service.CandidateStrategyIDs {
		strategy, exists := strategies[id]
		if !exists {
			return fmt.Errorf("unknown candidate strategy %q", id)
		}
		if _, duplicate := seenStrategies[id]; duplicate {
			return fmt.Errorf("duplicate candidate strategy %q", id)
		}
		seenStrategies[id] = struct{}{}
		if !strategySupportsService(strategy, service) {
			return fmt.Errorf("candidate strategy %q does not support service transports", id)
		}
	}
	seenTargets := make(map[string]struct{}, len(service.ProbeTargets))
	for _, target := range service.ProbeTargets {
		if err := ValidateProbeTarget(target); err != nil {
			return fmt.Errorf("probe %q: %w", target.ID, err)
		}
		if _, duplicate := seenTargets[target.ID]; duplicate {
			return fmt.Errorf("duplicate probe id %q", target.ID)
		}
		seenTargets[target.ID] = struct{}{}
	}
	return nil
}

func validateProcessDiscoveryTCPPorts(service ServiceRule) error {
	if len(service.ProcessDiscoveryTCPPorts) == 0 {
		return nil
	}
	if service.ProcessMatchPolicy != ProcessMatchIdentity || len(service.ProcessNames) == 0 {
		return errors.New("process TCP discovery ports require process identity")
	}
	if len(service.ProcessDiscoveryTCPPorts) > 16 {
		return errors.New("too many process TCP discovery ports")
	}
	if err := validatePorts(NetworkTCP, service.ProcessDiscoveryTCPPorts); err != nil {
		return fmt.Errorf("process TCP discovery: %w", err)
	}
	allowed := intSet(service.TCPPorts)
	for _, port := range service.ProcessDiscoveryTCPPorts {
		if port == 80 || port == 443 {
			return fmt.Errorf("process TCP discovery cannot capture shared web port %d", port)
		}
		if _, ok := allowed[port]; !ok {
			return fmt.Errorf("process TCP discovery port %d is absent from service TCP ports", port)
		}
	}
	return nil
}

func validateProcessDiscoveryUDPPortRanges(service ServiceRule) error {
	if len(service.ProcessDiscoveryUDPPortRanges) == 0 {
		return nil
	}
	if service.ProcessMatchPolicy != ProcessMatchIdentity || len(service.ProcessNames) == 0 {
		return errors.New("process UDP discovery ranges require process identity")
	}
	if len(service.ProcessDiscoveryUDPPortRanges) > 8 {
		return errors.New("too many process UDP discovery ranges")
	}
	totalPorts := 0
	for _, portRange := range service.ProcessDiscoveryUDPPortRanges {
		if portRange.First < 1 || portRange.Last > 65535 || portRange.First > portRange.Last {
			return fmt.Errorf("invalid process UDP discovery range %d..%d", portRange.First, portRange.Last)
		}
		totalPorts += portRange.Last - portRange.First + 1
	}
	if totalPorts > 512 {
		return errors.New("process UDP discovery ranges exceed 512 ports")
	}
	return nil
}

// ValidateProbeTarget validates externally supplied selector input.
func ValidateProbeTarget(target ProbeTarget) error {
	if !validIdentifier(target.ID) {
		return errors.New("invalid probe id")
	}
	if target.Network != NetworkTCP && target.Network != NetworkUDP {
		return fmt.Errorf("unsupported network %q", target.Network)
	}
	if target.Port < 1 || target.Port > 65535 {
		return errors.New("port must be within 1..65535")
	}
	switch target.Kind {
	case ProbeHTTP:
		u, err := url.Parse(strings.TrimSpace(target.URL))
		if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") {
			return errors.New("HTTP probe requires an http/https URL with a host")
		}
	case ProbeTCPConnect:
		if target.Network != NetworkTCP || normalizeHost(target.Host) == "" {
			return errors.New("TCP connect probe requires TCP and a host")
		}
	case ProbeUDPExchange, ProbeSTUN, ProbeDiscordMedia:
		if target.Network != NetworkUDP || normalizeHost(target.Host) == "" {
			return errors.New("UDP probe requires UDP and a host")
		}
	default:
		return fmt.Errorf("unsupported probe kind %q", target.Kind)
	}
	if target.Timeout < 0 || target.TimeoutMS < 0 {
		return errors.New("timeout cannot be negative")
	}
	return nil
}

func validateNetworkList(networks []Network) error {
	seen := map[Network]bool{}
	for _, network := range networks {
		if network != NetworkTCP && network != NetworkUDP {
			return fmt.Errorf("unsupported network %q", network)
		}
		if seen[network] {
			return fmt.Errorf("duplicate network %q", network)
		}
		seen[network] = true
	}
	return nil
}

func validatePorts(network Network, ports []int) error {
	copyPorts := append([]int(nil), ports...)
	sort.Ints(copyPorts)
	for i, port := range copyPorts {
		if port < 1 || port > 65535 {
			return fmt.Errorf("%s port %d is outside 1..65535", network, port)
		}
		if i > 0 && port == copyPorts[i-1] {
			return fmt.Errorf("duplicate %s port %d", network, port)
		}
	}
	return nil
}

func strategySupportsService(strategy TrafficStrategy, service ServiceRule) bool {
	if len(service.TCPPorts) > 0 && len(strategy.TCP) == 0 {
		return false
	}
	if len(service.UDPPorts) > 0 && len(strategy.UDP) == 0 {
		return false
	}
	return true
}

func validIdentifier(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 96 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			continue
		}
		return false
	}
	return true
}
