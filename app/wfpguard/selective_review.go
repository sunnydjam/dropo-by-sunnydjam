package wfpguard

import (
	"errors"
	"fmt"
	"net/netip"
	"strings"

	traffic "dropo/trafficorchestrator"
)

const RoutingModeSelectedServices = "blocked_only"

const maxSelectiveReviewServices = 256

// SelectiveReviewPolicy models only a possible per-flow decision in selected-
// services mode. It is deliberately not a WFP policy: ALE cannot identify a
// service from SNI/Host, and a shared CDN IP or browser app ID is not a safe
// WFP block condition. The decision must never be used as proof that a kill
// switch is installed, active, or covers flows not observed by the classifier.
type SelectiveReviewPolicy struct {
	revision   uint64
	classifier *traffic.Classifier
	vpnRoutes  map[string]struct{}
}

// SelectiveReviewDisposition describes an intended treatment of one observed
// flow. GuardObservedFlow is a review signal only, not an executable rule.
type SelectiveReviewDisposition string

const (
	SelectivePreserveDirect    SelectiveReviewDisposition = "preserve_direct"
	SelectiveGuardObservedFlow SelectiveReviewDisposition = "guard_observed_flow"
	SelectiveUnsupportedFlow   SelectiveReviewDisposition = "unsupported_evidence"
)

type SelectiveReviewDecision struct {
	Disposition SelectiveReviewDisposition
	ServiceID   string
	Reason      string
}

// BuildSelectiveReviewPolicy compiles the same validated immutable traffic
// plan as the selective packet engine. Only an explicit VPN route is eligible;
// default, Direct, and Zapret routes never become guard targets. There is no
// catch-all, address-range, process-wide, or service-wide WFP translation.
func BuildSelectiveReviewPolicy(routingMode string, plan traffic.TrafficPlan) (*SelectiveReviewPolicy, error) {
	if routingMode != RoutingModeSelectedServices {
		return nil, fmt.Errorf("selective routing mode must be %q", RoutingModeSelectedServices)
	}
	if len(plan.Services) > maxSelectiveReviewServices || len(plan.Routes) > maxSelectiveReviewServices {
		return nil, fmt.Errorf("selective review exceeds %d services or routes", maxSelectiveReviewServices)
	}
	classifier, err := traffic.NewClassifier(plan)
	if err != nil {
		return nil, fmt.Errorf("selective traffic plan: %w", err)
	}
	routes := make(map[string]struct{})
	for _, route := range plan.Routes {
		if route.Kind == traffic.ServiceRouteVPN {
			routes[route.ServiceID] = struct{}{}
		}
	}
	return &SelectiveReviewPolicy{revision: plan.Revision, classifier: classifier, vpnRoutes: routes}, nil
}

// ReviewObservedFlow accepts only an exact outbound tuple, parsed evidence,
// and the packet engine's final flow decision. In particular, callers must
// not fabricate Host from reverse DNS, an IP catalog, or an IPC request. A
// native WFP implementation would still need an authenticated, race-free
// binding of this observed tuple to a real flow before enforcing anything.
func (p *SelectiveReviewPolicy) ReviewObservedFlow(revision uint64, tuple traffic.FlowTuple, evidence traffic.FlowEvidence, routed traffic.FlowDecision) (SelectiveReviewDecision, error) {
	if p == nil || p.classifier == nil {
		return SelectiveReviewDecision{}, errors.New("selective review policy is unavailable")
	}
	if revision != p.revision {
		return SelectiveReviewDecision{}, errors.New("selective traffic plan revision is stale")
	}
	if err := validateSelectiveTuple(tuple, evidence); err != nil {
		return SelectiveReviewDecision{}, err
	}
	if !isPublicUnicast(tuple.Destination) {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, Reason: "private or non-public destination"}, nil
	}
	classification := p.classifier.Classify(evidence)
	if classification.WorkNetwork {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, Reason: "work-network precedence"}, nil
	}
	if classification.Direct {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, Reason: "explicit direct precedence"}, nil
	}
	if !classification.Matched {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, Reason: "unclassified traffic remains direct"}, nil
	}
	if _, vpn := p.vpnRoutes[classification.ServiceID]; !vpn {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, ServiceID: classification.ServiceID, Reason: "service is not explicitly routed through VPN"}, nil
	}
	if routed.PlanRevision != revision {
		return SelectiveReviewDecision{Disposition: SelectiveUnsupportedFlow, ServiceID: classification.ServiceID, Reason: "no current packet-engine flow decision"}, nil
	}
	if routed.Disposition == traffic.FlowDirect || routed.Disposition == traffic.FlowWorkNetwork {
		return SelectiveReviewDecision{Disposition: SelectivePreserveDirect, ServiceID: classification.ServiceID, Reason: "packet engine preserved this flow outside VPN"}, nil
	}
	if routed.Disposition != traffic.FlowService || routed.Route != traffic.ServiceRouteVPN || routed.ServiceID != classification.ServiceID {
		return SelectiveReviewDecision{Disposition: SelectiveUnsupportedFlow, ServiceID: classification.ServiceID, Reason: "packet-engine route does not confirm this VPN service"}, nil
	}
	// IP-only and process-only evidence is unsafe on shared addresses and
	// applications. The packet classifier may use it for routing, but a
	// disconnected-VPN WFP guarantee cannot be inferred from that alone.
	if !hasSelectiveContentEvidence(classification, evidence) {
		return SelectiveReviewDecision{Disposition: SelectiveUnsupportedFlow, ServiceID: classification.ServiceID, Reason: "VPN route lacks observed host or protocol evidence"}, nil
	}
	return SelectiveReviewDecision{Disposition: SelectiveGuardObservedFlow, ServiceID: classification.ServiceID, Reason: "positive service evidence for this exact observed flow"}, nil
}

func validateSelectiveTuple(tuple traffic.FlowTuple, evidence traffic.FlowEvidence) error {
	if tuple.Network != traffic.NetworkTCP && tuple.Network != traffic.NetworkUDP {
		return errors.New("selective flow protocol must be TCP or UDP")
	}
	if !tuple.Source.IsValid() || !tuple.Destination.IsValid() ||
		tuple.Source.Zone() != "" || tuple.Destination.Zone() != "" ||
		tuple.Source.Is4In6() || tuple.Destination.Is4In6() ||
		tuple.Source.BitLen() != tuple.Destination.BitLen() ||
		tuple.SourcePort == 0 || tuple.DestinationPort == 0 {
		return errors.New("selective flow requires an exact same-family tuple")
	}
	destination, err := netip.ParseAddr(evidence.Destination)
	if err != nil || destination != tuple.Destination ||
		evidence.Network != tuple.Network || evidence.Port != int(tuple.DestinationPort) {
		return errors.New("selective flow evidence does not match the exact tuple")
	}
	if strings.TrimSpace(evidence.Host) != evidence.Host {
		return errors.New("selective flow host evidence is not canonical")
	}
	if len(evidence.Host) > 253 || len(evidence.ProcessName) > 4096 || len(evidence.Fingerprints) > 16 {
		return errors.New("selective flow evidence exceeds its bounds")
	}
	for _, fingerprint := range evidence.Fingerprints {
		if len(fingerprint) > 64 {
			return errors.New("selective flow fingerprint exceeds its bound")
		}
	}
	return nil
}

func hasSelectiveContentEvidence(classification traffic.Classification, flow traffic.FlowEvidence) bool {
	for _, item := range classification.Evidence {
		switch item {
		case "exact-host", "domain-suffix":
			return true
		}
	}
	// Generic STUN, QUIC and TLS fingerprints are not service identity. The
	// Discord discovery signature is usable only together with the dedicated
	// Discord process and service-scoped destination evidence.
	if classification.ServiceID == "discord" &&
		containsSelectiveEvidence(classification.Evidence, "process-identity") &&
		containsSelectiveEvidence(classification.Evidence, "destination-cidr") {
		for _, fingerprint := range flow.Fingerprints {
			if fingerprint == "discord-media" {
				return true
			}
		}
	}
	return false
}

func containsSelectiveEvidence(evidence []string, target string) bool {
	for _, value := range evidence {
		if value == target {
			return true
		}
	}
	return false
}
