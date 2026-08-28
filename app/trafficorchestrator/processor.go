package trafficorchestrator

import (
	"encoding/binary"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
)

type processorSnapshot struct {
	plan                TrafficPlan
	classifier          *Classifier
	strategies          map[string]TrafficStrategy
	selected            map[string]string
	routes              map[string]ServiceRouteKind
	usesProcessIdentity bool
}

// PacketDecision is the complete result for one captured packet. Packets are
// already checksummed and ready for reinjection in listed order.
type PacketDecision struct {
	PlanRevision uint64
	ServiceID    string
	StrategyID   string
	Route        ServiceRouteKind
	Direction    PacketDirection
	Dropped      bool
	Transformed  bool
	Packets      [][]byte
	Reason       string
}

type ServiceCounters struct {
	Matched     uint64
	Transformed uint64
	Passed      uint64
	Errors      uint64
}

// Processor owns the immutable plan snapshot but no driver handle. It is used
// by both the real Windows engine and deterministic packet replay tests.
type Processor struct {
	snapshot      atomic.Pointer[processorSnapshot]
	identity      FlowIdentityResolver
	redirector    *TCPPacketRedirector
	udpRedirector *UDPPacketRedirector
	fakeIPs       *FakeIPDirectory
	dnsFake       *DNSFakeResponder
	flows         *flowDecisionTable
	statsMu       sync.Mutex
	stats         map[string]ServiceCounters
}

func NewProcessor(plan TrafficPlan) (*Processor, error) {
	return NewProcessorWithIdentityResolver(plan, nil)
}

// NewProcessorWithIdentityResolver enables production process attribution
// without coupling deterministic packet processing to Windows APIs.
func NewProcessorWithIdentityResolver(plan TrafficPlan, identity FlowIdentityResolver) (*Processor, error) {
	return NewProcessorWithRuntime(plan, identity, nil)
}

func NewProcessorWithRuntime(plan TrafficPlan, identity FlowIdentityResolver, redirector *TCPPacketRedirector) (*Processor, error) {
	return NewProcessorWithSelectiveRuntime(plan, identity, redirector, nil)
}

func NewProcessorWithSelectiveRuntime(plan TrafficPlan, identity FlowIdentityResolver, redirector *TCPPacketRedirector, fakeIPs *FakeIPDirectory) (*Processor, error) {
	return NewProcessorWithFullSelectiveRuntime(plan, identity, redirector, nil, fakeIPs)
}

func NewProcessorWithFullSelectiveRuntime(plan TrafficPlan, identity FlowIdentityResolver, redirector *TCPPacketRedirector, udpRedirector *UDPPacketRedirector, fakeIPs *FakeIPDirectory) (*Processor, error) {
	processor := &Processor{identity: identity, redirector: redirector, udpRedirector: udpRedirector, fakeIPs: fakeIPs, flows: newFlowDecisionTable(), stats: make(map[string]ServiceCounters)}
	if fakeIPs != nil {
		processor.dnsFake = NewDNSFakeResponder(fakeIPs)
	}
	if err := processor.ApplyPlan(plan); err != nil {
		return nil, err
	}
	return processor, nil
}

// ApplyPlan compiles the complete snapshot before one atomic pointer swap.
func (p *Processor) ApplyPlan(plan TrafficPlan) error {
	if p == nil {
		return errors.New("processor is nil")
	}
	current := p.snapshot.Load()
	if current != nil && plan.Revision <= current.plan.Revision {
		return fmt.Errorf("plan revision %d is not newer than active revision %d", plan.Revision, current.plan.Revision)
	}
	var classifier *Classifier
	if current != nil && sameClassificationPlan(current.plan, plan) {
		if err := validateSelectionRevision(plan, current); err != nil {
			return err
		}
		classifier = current.classifier
	} else {
		var err error
		classifier, err = NewClassifier(plan)
		if err != nil {
			return err
		}
	}
	snapshot := &processorSnapshot{
		plan:       plan,
		classifier: classifier,
		strategies: make(map[string]TrafficStrategy, len(plan.Strategies)),
		selected:   make(map[string]string, len(plan.Selections)),
		routes:     make(map[string]ServiceRouteKind, len(plan.Routes)),
	}
	for _, service := range plan.Services {
		if len(service.ProcessNames) > 0 {
			snapshot.usesProcessIdentity = true
			break
		}
	}
	if !snapshot.usesProcessIdentity {
		for _, rule := range plan.DirectRules {
			if len(rule.ProcessNames) > 0 {
				snapshot.usesProcessIdentity = true
				break
			}
		}
	}
	for _, strategy := range plan.Strategies {
		snapshot.strategies[strategy.ID] = strategy
	}
	for _, selection := range plan.Selections {
		snapshot.selected[selection.ServiceID] = selection.StrategyID
	}
	for _, route := range plan.Routes {
		snapshot.routes[route.ServiceID] = route.Kind
	}
	if p.fakeIPs != nil {
		if err := p.fakeIPs.ApplyPlan(plan); err != nil {
			return fmt.Errorf("apply fake-IP routing revision: %w", err)
		}
	}
	p.snapshot.Store(snapshot)
	p.flows.clear()
	return nil
}

func sameClassificationPlan(previous, next TrafficPlan) bool {
	return previous.CatalogRevision == next.CatalogRevision &&
		reflect.DeepEqual(previous.Strategies, next.Strategies) &&
		reflect.DeepEqual(previous.Services, next.Services) &&
		reflect.DeepEqual(previous.WorkNetworks, next.WorkNetworks) &&
		reflect.DeepEqual(previous.DirectRules, next.DirectRules)
}

func validateSelectionRevision(plan TrafficPlan, current *processorSnapshot) error {
	if err := ValidatePlan(plan); err != nil {
		return err
	}
	seen := make(map[string]struct{}, len(plan.Selections))
	for _, selection := range plan.Selections {
		if _, exists := current.strategies[selection.StrategyID]; !exists {
			return fmt.Errorf("selection for %q references unknown strategy %q", selection.ServiceID, selection.StrategyID)
		}
		serviceExists := false
		strategyAllowed := false
		for _, service := range plan.Services {
			if service.ID == selection.ServiceID {
				serviceExists = true
				for _, candidate := range service.CandidateStrategyIDs {
					if candidate == selection.StrategyID {
						strategyAllowed = true
						break
					}
				}
				break
			}
		}
		if !serviceExists {
			return fmt.Errorf("selection references unknown service %q", selection.ServiceID)
		}
		if !strategyAllowed {
			return fmt.Errorf("selection for %q uses non-candidate strategy %q", selection.ServiceID, selection.StrategyID)
		}
		if _, duplicate := seen[selection.ServiceID]; duplicate {
			return fmt.Errorf("duplicate selection for service %q", selection.ServiceID)
		}
		seen[selection.ServiceID] = struct{}{}
	}
	return nil
}

func (p *Processor) Revision() uint64 {
	if p == nil || p.snapshot.Load() == nil {
		return 0
	}
	return p.snapshot.Load().plan.Revision
}

func (p *Processor) Process(packet []byte) PacketDecision {
	snapshot := p.snapshot.Load()
	if snapshot == nil {
		return passDecision(0, packet, "no active plan")
	}
	parsed, err := parsePacket(packet)
	if err != nil {
		return passDecision(snapshot.plan.Revision, packet, "unsupported or malformed packet")
	}
	tuple := parsed.flowTuple()
	evidence := parsed.flowEvidence()
	if p.identity != nil && tuple.valid() && (snapshot.usesProcessIdentity || p.fakeIPs != nil) {
		evidence.ProcessName = p.identity.ResolveProcessName(tuple)
	}
	trustedRuntime := isTrustedSelectiveRuntimeProcess(evidence.ProcessName)
	if p.dnsFake != nil && !trustedRuntime {
		response, target, handled, responseErr := p.dnsFake.Respond(parsed)
		if handled {
			if responseErr != nil {
				return passDecision(snapshot.plan.Revision, packet, "fake DNS response failed safe: "+responseErr.Error())
			}
			reason := "selected VPN domain mapped to fake IP"
			route := ServiceRouteVPN
			if target.ServiceID == "" {
				reason = "encrypted DNS endpoint denied in selective mode"
				route = ""
			} else {
				p.bump(target.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Transformed++ })
			}
			return PacketDecision{
				PlanRevision: snapshot.plan.Revision, ServiceID: target.ServiceID, Route: route,
				Direction: PacketDirectionInbound, Transformed: true, Packets: [][]byte{response}, Reason: reason,
			}
		}
	}
	if p.redirector != nil {
		restored, target, recognized, restoreErr := p.redirector.RestoreRelayPacket(parsed)
		if recognized {
			if restoreErr != nil {
				return PacketDecision{PlanRevision: snapshot.plan.Revision, Route: ServiceRouteVPN, Dropped: true, Reason: restoreErr.Error()}
			}
			return PacketDecision{
				PlanRevision: snapshot.plan.Revision, ServiceID: target.ServiceID, Route: ServiceRouteVPN,
				Direction: PacketDirectionInbound, Transformed: true, Packets: [][]byte{restored}, Reason: "restored selective VPN relay response",
			}
		}
	}
	if p.udpRedirector != nil {
		restored, target, recognized, restoreErr := p.udpRedirector.RestoreRelayPacket(parsed)
		if recognized {
			if restoreErr != nil {
				return PacketDecision{PlanRevision: snapshot.plan.Revision, Route: ServiceRouteVPN, Dropped: true, Reason: restoreErr.Error()}
			}
			return PacketDecision{
				PlanRevision: snapshot.plan.Revision, ServiceID: target.ServiceID, Route: ServiceRouteVPN,
				Direction: PacketDirectionInbound, Transformed: true, Packets: [][]byte{restored}, Reason: "restored selective VPN UDP relay response",
			}
		}
	}
	// The relay hands selected destinations to sing-box over loopback. Any
	// subsequent sing-box/Xray/WireGuard egress is already on its terminal path
	// and must never be classified back into the selective redirector.
	if trustedRuntime {
		return passDecision(snapshot.plan.Revision, packet, "trusted Dropo runtime egress")
	}
	if p.fakeIPs != nil {
		if target, matched := p.fakeIPs.LookupAddress(parsed.destination); matched {
			evidence.Host = target.Host
		}
	}
	// Preserve a prior direct disposition for the complete captured flow. This
	// is especially important when a TCP SYN passed before process/SNI evidence
	// became available: redirecting its later ClientHello would tear down an
	// already-established Steam/Electron/native application connection.
	if previous, ok := p.flows.lookup(tuple, snapshot.plan.Revision); ok && previous.Disposition == FlowDirect {
		return passDecision(snapshot.plan.Revision, packet, "preserved established direct flow")
	}
	classification := snapshot.classifier.Classify(evidence)
	route := snapshot.routes[classification.ServiceID]
	if route == "" && classification.Matched {
		if _, selected := snapshot.selected[classification.ServiceID]; selected {
			route = ServiceRouteZapret
		} else {
			route = ServiceRouteDirect
		}
	}
	p.recordFlowDecision(tuple, snapshot.plan.Revision, evidence.ProcessName, route, classification)
	if classification.WorkNetwork {
		return passDecision(snapshot.plan.Revision, packet, "reserved for work network "+classification.WorkNetworkID)
	}
	if classification.Direct {
		return passDecision(snapshot.plan.Revision, packet, "reserved for direct rule "+classification.DirectRuleID)
	}
	if !classification.Matched {
		return passDecision(snapshot.plan.Revision, packet, "service not classified")
	}
	if route == ServiceRouteDirect {
		p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Passed++ })
		decision := passDecision(snapshot.plan.Revision, packet, "service explicitly routed direct")
		decision.ServiceID = classification.ServiceID
		decision.Route = route
		return decision
	}
	if route == ServiceRouteVPN {
		if parsed.network == NetworkUDP {
			if p.udpRedirector == nil {
				p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Errors++ })
				return PacketDecision{
					PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route,
					Dropped: true, Reason: "selective VPN UDP relay is not active",
				}
			}
			reflected, redirectErr := p.udpRedirector.ReflectClientPacket(parsed, UDPRedirectTarget{
				Flow: tuple, Host: evidence.Host, ServiceID: classification.ServiceID, Route: route,
			})
			if redirectErr != nil {
				p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Errors++ })
				return PacketDecision{PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route, Dropped: true, Reason: "selective VPN UDP redirect failed: " + redirectErr.Error()}
			}
			p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Transformed++ })
			return PacketDecision{
				PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route,
				Direction: PacketDirectionInbound, Transformed: true, Packets: [][]byte{reflected}, Reason: "reflected to selective VPN UDP relay",
			}
		}
		if parsed.network != NetworkTCP {
			return PacketDecision{PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route, Dropped: true, Reason: "unsupported selective VPN transport"}
		}
		if p.redirector == nil {
			p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Passed++ })
			decision := passDecision(snapshot.plan.Revision, packet, "service requires selective VPN relay")
			decision.ServiceID = classification.ServiceID
			decision.Route = route
			return decision
		}
		reflected, redirectErr := p.redirector.ReflectClientPacket(parsed, TCPRedirectTarget{
			Flow: tuple, Host: evidence.Host, ServiceID: classification.ServiceID, Route: route,
		})
		if redirectErr != nil {
			if !parsed.isInitialTCPSYN() {
				p.flows.store(tuple, FlowDecision{
					PlanRevision: snapshot.plan.Revision, Disposition: FlowDirect,
					ProcessName: normalizeProcessName(evidence.ProcessName),
					Reason:      "selective VPN redirect declined for established TCP flow",
				})
				p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Errors++; value.Passed++ })
				decision := passDecision(snapshot.plan.Revision, packet, "selective VPN redirect failed safe: "+redirectErr.Error())
				decision.ServiceID = classification.ServiceID
				decision.Route = route
				return decision
			}
			p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Errors++ })
			return PacketDecision{PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route, Dropped: true, Reason: "selective VPN redirect failed: " + redirectErr.Error()}
		}
		p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Transformed++ })
		return PacketDecision{
			PlanRevision: snapshot.plan.Revision, ServiceID: classification.ServiceID, Route: route,
			Direction: PacketDirectionInbound, Transformed: true, Packets: [][]byte{reflected}, Reason: "reflected to selective VPN relay",
		}
	}
	strategyID := snapshot.selected[classification.ServiceID]
	strategy, ok := snapshot.strategies[strategyID]
	if !ok {
		p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Passed++ })
		decision := passDecision(snapshot.plan.Revision, packet, "no selected strategy")
		decision.ServiceID = classification.ServiceID
		decision.Route = route
		return decision
	}
	packets, transformed, err := applyStrategy(parsed, strategy)
	if err != nil {
		p.bump(classification.ServiceID, func(value *ServiceCounters) { value.Matched++; value.Errors++; value.Passed++ })
		decision := passDecision(snapshot.plan.Revision, packet, "strategy failed safe: "+err.Error())
		decision.ServiceID = classification.ServiceID
		decision.StrategyID = strategy.ID
		decision.Route = route
		return decision
	}
	p.bump(classification.ServiceID, func(value *ServiceCounters) {
		value.Matched++
		if transformed {
			value.Transformed++
		} else {
			value.Passed++
		}
	})
	return PacketDecision{
		PlanRevision: snapshot.plan.Revision,
		ServiceID:    classification.ServiceID,
		StrategyID:   strategy.ID,
		Route:        route,
		Transformed:  transformed,
		Packets:      packets,
	}
}

func isTrustedSelectiveRuntimeProcess(value string) bool {
	switch normalizeProcessName(value) {
	case "dropo.exe", "dropo-ui.exe", "dropo-core.exe", "sing-box.exe", "xray.exe", "tg-ws-proxy.exe", "wireguard.exe", "wg.exe":
		return true
	default:
		return false
	}
}

// LookupFlowDecision returns only a non-expired decision made under the active
// immutable plan. The current packet engine does not route from this table yet.
func (p *Processor) LookupFlowDecision(tuple FlowTuple) (FlowDecision, bool) {
	if p == nil {
		return FlowDecision{}, false
	}
	snapshot := p.snapshot.Load()
	if snapshot == nil {
		return FlowDecision{}, false
	}
	return p.flows.lookup(tuple, snapshot.plan.Revision)
}

func (p *Processor) recordFlowDecision(tuple FlowTuple, revision uint64, processName string, route ServiceRouteKind, classification Classification) {
	decision := FlowDecision{PlanRevision: revision, ProcessName: normalizeProcessName(processName), Route: route}
	switch {
	case classification.WorkNetwork:
		decision.Disposition = FlowWorkNetwork
		decision.RuleID = classification.WorkNetworkID
		decision.Reason = "work-network evidence"
	case classification.Direct:
		decision.Disposition = FlowDirect
		decision.RuleID = classification.DirectRuleID
		decision.Reason = "explicit direct evidence"
	case classification.Matched:
		decision.Disposition = FlowService
		decision.ServiceID = classification.ServiceID
		decision.Reason = "selected-service evidence"
	default:
		decision.Disposition = FlowDirect
		decision.Reason = "unclassified traffic defaults direct"
	}
	p.flows.store(tuple, decision)
}

func (p *Processor) Counters() map[string]ServiceCounters {
	if p == nil {
		return nil
	}
	p.statsMu.Lock()
	defer p.statsMu.Unlock()
	result := make(map[string]ServiceCounters, len(p.stats))
	for service, counters := range p.stats {
		result[service] = counters
	}
	return result
}

func (p *Processor) bump(service string, update func(*ServiceCounters)) {
	p.statsMu.Lock()
	defer p.statsMu.Unlock()
	value := p.stats[service]
	update(&value)
	p.stats[service] = value
}

func passDecision(revision uint64, packet []byte, reason string) PacketDecision {
	copyPacket := append([]byte(nil), packet...)
	return PacketDecision{PlanRevision: revision, Packets: [][]byte{copyPacket}, Reason: reason}
}

func applyStrategy(parsed parsedPacket, strategy TrafficStrategy) ([][]byte, bool, error) {
	if !strategyApplies(parsed, strategy.Constraints) {
		return [][]byte{append([]byte(nil), parsed.bytes...)}, false, nil
	}
	actions := strategy.TCP
	if parsed.network == NetworkUDP {
		actions = strategy.UDP
	}
	if len(actions) == 0 || len(parsed.payload()) == 0 {
		return [][]byte{append([]byte(nil), parsed.bytes...)}, false, nil
	}
	outputs := make([][]byte, 0, 8)
	originals := [][]byte{append([]byte(nil), parsed.bytes...)}
	transformed := false
	ttl := 0
	for _, action := range actions {
		switch action.Kind {
		case ActionPass:
			continue
		case ActionTTL:
			ttl = action.TTL
		case ActionFake:
			fake, err := makeFakePacket(parsed, action, ttl)
			if err != nil {
				return nil, false, err
			}
			for repeat := 0; repeat < action.Repeats; repeat++ {
				outputs = append(outputs, append([]byte(nil), fake...))
			}
			transformed = true
		case ActionSplit, ActionDisorder:
			if parsed.network != NetworkTCP {
				return nil, false, fmt.Errorf("%s applied to non-TCP packet", action.Kind)
			}
			positions, err := resolvePacketPositions(parsed.payload(), action)
			if err != nil {
				return nil, false, err
			}
			segments, err := splitTCPPacketAtPositions(parsed, positions)
			if err != nil {
				return nil, false, err
			}
			if action.Kind == ActionDisorder {
				for left, right := 0, len(segments)-1; left < right; left, right = left+1, right-1 {
					segments[left], segments[right] = segments[right], segments[left]
				}
			}
			originals = segments
			transformed = true
		case ActionSequenceOverlap:
			if parsed.network != NetworkTCP {
				return nil, false, errors.New("sequence overlap applied to non-TCP packet")
			}
			overlap, err := makeOverlapPacket(parsed, action.Overlap)
			if err != nil {
				return nil, false, err
			}
			outputs = append(outputs, overlap)
			transformed = true
		case ActionRepeat:
			if len(outputs) == 0 {
				return nil, false, errors.New("repeat has no preceding synthetic packet")
			}
			last := outputs[len(outputs)-1]
			for repeat := 1; repeat < action.Repeats; repeat++ {
				outputs = append(outputs, append([]byte(nil), last...))
			}
			transformed = true
		default:
			return nil, false, fmt.Errorf("unsupported action %q", action.Kind)
		}
	}
	outputs = append(outputs, originals...)
	return outputs, transformed, nil
}

func strategyApplies(parsed parsedPacket, constraints StrategyConstraints) bool {
	if len(constraints.Networks) > 0 {
		matched := false
		for _, network := range constraints.Networks {
			if network == parsed.network {
				matched = true
				break
			}
		}
		if !matched {
			return false
		}
	}
	if (constraints.IPv4 || constraints.IPv6) && ((parsed.ipVersion == 4 && !constraints.IPv4) || (parsed.ipVersion == 6 && !constraints.IPv6)) {
		return false
	}
	if constraints.MaxFlowData > 0 && len(parsed.payload()) > constraints.MaxFlowData {
		return false
	}
	if len(constraints.Payloads) == 0 {
		return true
	}
	evidence := parsed.flowEvidence()
	fingerprints := make(map[string]struct{}, len(evidence.Fingerprints))
	for _, fingerprint := range evidence.Fingerprints {
		fingerprints[normalizeToken(fingerprint)] = struct{}{}
	}
	for _, required := range constraints.Payloads {
		if _, ok := fingerprints[normalizeToken(required)]; ok {
			return true
		}
	}
	return false
}

func makeFakePacket(parsed parsedPacket, action PacketAction, ttl int) ([]byte, error) {
	var payload []byte
	switch action.Payload {
	case "tls_client_hello":
		payload = fakeTLSClientHelloLike(parsed.payload())
	case "quic_initial":
		payload = fakeQUICInitial(parsed.payload())
	case "quic_decoy":
		payload = fakeQUICInitial(nil)
	case "original":
		payload = append([]byte(nil), parsed.payload()...)
	case "protocol_decoy":
		payload = protocolDecoyPayload(parsed)
	case "zero":
		payload = make([]byte, action.PadTo)
	default:
		return nil, fmt.Errorf("unknown fake payload %q", action.Payload)
	}
	if action.PadTo > len(payload) {
		if action.Payload == "tls_client_hello" {
			payload = padTLSClientHello(payload, action.PadTo)
		} else {
			payload = append(payload, make([]byte, action.PadTo-len(payload))...)
		}
	}
	packet, updated, err := resizePacketPayload(parsed, payload)
	if err != nil {
		return nil, err
	}
	if ttl > 0 {
		setPacketTTL(packet, updated, ttl)
	}
	if action.SequenceDelta != 0 && updated.network == NetworkTCP {
		sequence := uint32(int64(updated.tcpSequence) + int64(action.SequenceDelta))
		binary.BigEndian.PutUint32(packet[updated.transportOffset+4:updated.transportOffset+8], sequence)
	}
	calculateChecksums(packet)
	if action.InvalidSum {
		corruptTransportChecksum(packet, updated)
	}
	return packet, nil
}

func protocolDecoyPayload(parsed parsedPacket) []byte {
	original := parsed.payload()
	evidence := parsed.flowEvidence()
	for _, fingerprint := range evidence.Fingerprints {
		switch fingerprint {
		case "discord-media":
			decoy := append([]byte(nil), original...)
			if len(decoy) >= 8 {
				// Discord bytes 4..7 are the request SSRC. A deterministic
				// alternate value makes the decoy distinct while any response is
				// safely ignored by the client waiting for the real request SSRC.
				decoy[4] ^= 0xd3
				decoy[5] ^= 0x15
				decoy[6] ^= 0xc0
				decoy[7] ^= 0xde
			}
			return decoy
		case "stun":
			decoy := append([]byte(nil), original...)
			for index := 8; index < len(decoy) && index < 20; index++ {
				decoy[index] ^= byte(0xa5 + index)
			}
			return decoy
		case "quic-initial":
			return fakeQUICInitial(original)
		}
	}
	return append([]byte(nil), original...)
}

func resolvePacketPositions(payload []byte, action PacketAction) ([]int, error) {
	positions := make([]int, 0, max(1, len(action.Positions)))
	if action.Position != 0 {
		positions = append(positions, action.Position)
	}
	var sniStart, sniEnd int
	var hasSNI bool
	for _, position := range action.Positions {
		resolved := position.Absolute
		if position.Anchor != "" {
			if !hasSNI {
				_, sniStart, sniEnd = locateTLSServerName(payload, true)
				hasSNI = sniStart > 0 && sniEnd > sniStart
			}
			if !hasSNI {
				return nil, fmt.Errorf("cannot resolve %s without a complete SNI extension", position.Anchor)
			}
			switch position.Anchor {
			case "tls-sni-start":
				resolved = sniStart
			case "tls-sni-middle":
				resolved = sniStart + (sniEnd-sniStart)/2
			case "tls-sni-end":
				resolved = sniEnd
			}
			resolved += position.Offset
		}
		if resolved < 1 || resolved >= len(payload) {
			return nil, fmt.Errorf("split position %d is outside payload length %d", resolved, len(payload))
		}
		positions = append(positions, resolved)
	}
	sort.Ints(positions)
	unique := positions[:0]
	for _, position := range positions {
		if len(unique) == 0 || unique[len(unique)-1] != position {
			unique = append(unique, position)
		}
	}
	return unique, nil
}

func splitTCPPacket(parsed parsedPacket, position int) ([][]byte, error) {
	return splitTCPPacketAtPositions(parsed, []int{position})
}

func splitTCPPacketAtPositions(parsed parsedPacket, positions []int) ([][]byte, error) {
	payload := parsed.payload()
	if len(positions) == 0 {
		return nil, errors.New("no TCP split positions")
	}
	parts := make([][]byte, 0, len(positions)+1)
	previous := 0
	for _, position := range positions {
		if position < 1 || position >= len(payload) || position <= previous {
			return nil, fmt.Errorf("split position %d is invalid for payload length %d", position, len(payload))
		}
		parts = append(parts, payload[previous:position])
		previous = position
	}
	parts = append(parts, payload[previous:])
	segments := make([][]byte, 0, len(parts))
	offset := 0
	for index, part := range parts {
		packet, updated, err := resizePacketPayload(parsed, part)
		if err != nil {
			return nil, err
		}
		binary.BigEndian.PutUint32(packet[updated.transportOffset+4:updated.transportOffset+8], parsed.tcpSequence+uint32(offset))
		if index < len(parts)-1 {
			packet[updated.tcpFlagsOffset] &^= 0x09 // FIN + PSH are kept only on the last segment.
		}
		calculateChecksums(packet)
		segments = append(segments, packet)
		offset += len(part)
	}
	return segments, nil
}

func makeOverlapPacket(parsed parsedPacket, overlap int) ([]byte, error) {
	payload := parsed.payload()
	if overlap < 1 || overlap > len(payload) {
		return nil, fmt.Errorf("overlap %d is outside payload length %d", overlap, len(payload))
	}
	fake := make([]byte, overlap)
	for index := range fake {
		fake[index] = byte(0xa5 ^ index)
	}
	packet, updated, err := resizePacketPayload(parsed, fake)
	if err != nil {
		return nil, err
	}
	binary.BigEndian.PutUint32(packet[updated.transportOffset+4:updated.transportOffset+8], parsed.tcpSequence-uint32(overlap))
	packet[updated.tcpFlagsOffset] &^= 0x09
	calculateChecksums(packet)
	return packet, nil
}

func setPacketTTL(packet []byte, parsed parsedPacket, ttl int) {
	if parsed.ipVersion == 4 {
		packet[8] = byte(ttl)
	} else {
		packet[7] = byte(ttl)
	}
}

func corruptTransportChecksum(packet []byte, parsed parsedPacket) {
	offset := parsed.transportOffset + 16
	if parsed.network == NetworkUDP {
		offset = parsed.transportOffset + 6
	}
	if offset+2 <= len(packet) {
		checksum := binary.BigEndian.Uint16(packet[offset : offset+2])
		binary.BigEndian.PutUint16(packet[offset:offset+2], checksum^0xffff)
	}
}

func fakeTLSClientHello() []byte {
	return fakeTLSClientHelloForServerName("www.google.com")
}

func fakeTLSClientHelloForServerName(host string) []byte {
	return fakeTLSClientHelloForServerNameAndSession(host, nil, 0)
}

func fakeTLSClientHelloLike(original []byte) []byte {
	seed := byte(len(original))
	for index, value := range original {
		seed ^= value + byte(index*17)
	}
	return fakeTLSClientHelloForServerNameAndSession("www.google.com", tlsClientHelloSessionID(original), seed)
}

func fakeTLSClientHelloForServerNameAndSession(host string, sessionID []byte, seed byte) []byte {
	if len(sessionID) > 32 {
		sessionID = sessionID[:32]
	}
	serverName := []byte(normalizeHost(host))
	serverNameListLength := 3 + len(serverName)
	serverNameExtensionLength := 2 + serverNameListLength
	extensionsLength := 4 + serverNameExtensionLength
	bodyLength := 2 + 32 + 1 + len(sessionID) + 2 + 2 + 1 + 1 + 2 + extensionsLength
	handshakeLength := 4 + bodyLength
	payload := make([]byte, 5+handshakeLength)
	payload[0] = 0x16
	payload[1] = 0x03
	payload[2] = 0x01
	binary.BigEndian.PutUint16(payload[3:5], uint16(handshakeLength))
	payload[5] = 0x01
	payload[6] = byte(bodyLength >> 16)
	payload[7] = byte(bodyLength >> 8)
	payload[8] = byte(bodyLength)
	cursor := 9
	payload[cursor], payload[cursor+1] = 0x03, 0x03
	cursor += 2
	for index := 0; index < 32; index++ {
		payload[cursor+index] = byte(index*17+3) ^ seed
	}
	cursor += 32
	payload[cursor] = byte(len(sessionID))
	cursor++
	copy(payload[cursor:], sessionID)
	cursor += len(sessionID)
	binary.BigEndian.PutUint16(payload[cursor:cursor+2], 2)
	cursor += 2
	payload[cursor], payload[cursor+1] = 0x13, 0x01
	cursor += 2
	payload[cursor], payload[cursor+1] = 1, 0
	cursor += 2
	binary.BigEndian.PutUint16(payload[cursor:cursor+2], uint16(extensionsLength))
	cursor += 2
	binary.BigEndian.PutUint16(payload[cursor:cursor+2], 0)
	binary.BigEndian.PutUint16(payload[cursor+2:cursor+4], uint16(serverNameExtensionLength))
	cursor += 4
	binary.BigEndian.PutUint16(payload[cursor:cursor+2], uint16(serverNameListLength))
	cursor += 2
	payload[cursor] = 0
	binary.BigEndian.PutUint16(payload[cursor+1:cursor+3], uint16(len(serverName)))
	cursor += 3
	copy(payload[cursor:], serverName)
	return payload
}

func tlsClientHelloSessionID(record []byte) []byte {
	const sessionLengthOffset = 5 + 4 + 2 + 32
	if len(record) <= sessionLengthOffset || record[0] != 0x16 || record[5] != 0x01 {
		return nil
	}
	length := int(record[sessionLengthOffset])
	start := sessionLengthOffset + 1
	if length > 32 || start+length > len(record) {
		return nil
	}
	return append([]byte(nil), record[start:start+length]...)
}

func padTLSClientHello(payload []byte, target int) []byte {
	if target <= len(payload) || len(payload) < 9 || target-len(payload) < 4 {
		return payload
	}
	extensionsLengthOffset, ok := clientHelloExtensionsLengthOffset(payload)
	if !ok {
		return payload
	}
	paddingLength := target - len(payload) - 4
	padded := make([]byte, target)
	copy(padded, payload)
	cursor := len(payload)
	binary.BigEndian.PutUint16(padded[cursor:cursor+2], 21) // RFC 7685 padding extension.
	binary.BigEndian.PutUint16(padded[cursor+2:cursor+4], uint16(paddingLength))
	extensionsLength := int(binary.BigEndian.Uint16(padded[extensionsLengthOffset : extensionsLengthOffset+2]))
	binary.BigEndian.PutUint16(padded[extensionsLengthOffset:extensionsLengthOffset+2], uint16(extensionsLength+4+paddingLength))
	recordLength := len(padded) - 5
	binary.BigEndian.PutUint16(padded[3:5], uint16(recordLength))
	handshakeLength := recordLength - 4
	padded[6], padded[7], padded[8] = byte(handshakeLength>>16), byte(handshakeLength>>8), byte(handshakeLength)
	return padded
}

func clientHelloExtensionsLengthOffset(record []byte) (int, bool) {
	if len(record) < 5+4+2+32+1 || record[0] != 0x16 || record[5] != 0x01 {
		return 0, false
	}
	cursor := 9 + 2 + 32
	if cursor >= len(record) {
		return 0, false
	}
	sessionLength := int(record[cursor])
	cursor++
	if cursor+sessionLength+2 > len(record) {
		return 0, false
	}
	cursor += sessionLength
	cipherLength := int(binary.BigEndian.Uint16(record[cursor : cursor+2]))
	cursor += 2
	if cursor+cipherLength+1 > len(record) {
		return 0, false
	}
	cursor += cipherLength
	compressionLength := int(record[cursor])
	cursor++
	if cursor+compressionLength+2 > len(record) {
		return 0, false
	}
	return cursor + compressionLength, true
}

func fakeQUICInitial(original []byte) []byte {
	// A QUIC Initial commonly already occupies 1200 bytes. Copying it and only
	// filling a missing tail therefore emitted an identical packet, not a decoy.
	// Build a distinct, bounded v1 long-header packet instead. It intentionally
	// cannot authenticate at the origin but retains the shape inspected by DPI.
	payload := make([]byte, 1200)
	payload[0] = 0xc3
	binary.BigEndian.PutUint32(payload[1:5], 1)
	payload[5] = 8
	copy(payload[6:14], []byte{0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08})
	payload[14] = 0 // source connection id length
	payload[15] = 0 // token length
	// Two-byte QUIC varint describing the remaining packet number and payload.
	remaining := len(payload) - 18
	payload[16] = 0x40 | byte(remaining>>8)
	payload[17] = byte(remaining)
	seed := byte(len(original)*31 + 17)
	for index := 18; index < len(payload); index++ {
		payload[index] = byte(index*29+11) ^ seed
	}
	if len(original) == len(payload) && string(original) == string(payload) {
		payload[len(payload)-1] ^= 0xff
	}
	return payload
}
