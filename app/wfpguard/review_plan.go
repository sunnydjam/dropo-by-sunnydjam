package wfpguard

import (
	"bytes"
	"fmt"
	"net/netip"
	"slices"
)

// ReviewPlan is a non-executable description of the outbound policy that a
// future privileged service must implement and independently verify. It does
// not contain WFP keys, native condition values, or a method to install rules.
// In particular, it is not proof of protection or suitable for active=true.
//
// Windows ALE_AUTH_CONNECT is stateful. Its next-hop-interface condition may
// also be empty during reauthorization. A production implementation must
// resolve those cases, pre-existing flows, DHCP/ND bootstrap, process identity,
// and machine-wide versus user-only scope in VM tests before using this plan.
type ReviewPlan struct {
	Revision uint64
	UserSID  string // authorization binding only; not an assumed WFP traffic scope
	Rules    []ReviewRule
}

type ReviewRuleKind uint8

const (
	ReviewBlockAll ReviewRuleKind = iota + 1
	ReviewPermitTunnel
	ReviewPermitEndpoint
)

type ReviewFamily uint8

const (
	ReviewIPv4 ReviewFamily = 4
	ReviewIPv6 ReviewFamily = 6
)

// ReviewRule describes an intended match, not a native FWPM_FILTER0. Every
// endpoint exception includes an exact transport app ID, protocol, remote IP,
// port, and physical interface. Only block-all rules have no conditions.
type ReviewRule struct {
	Kind          ReviewRuleKind
	Family        ReviewFamily
	InterfaceLUID uint64
	Process       Process
	AppID         []byte
	Protocol      Protocol
	RemoteIP      netip.Addr
	RemotePort    uint16
}

const maxReviewAppIDBytes = 4096

// BuildReviewPlan validates the policy and resolves the process identities
// into opaque, exact WFP app-ID blobs supplied by a trusted caller. The caller
// must obtain those blobs from signature-verified installed binaries; an IPC
// client must never supply them. This function never accesses or changes WFP.
func BuildReviewPlan(policy Policy, appIDs map[Process][]byte) (ReviewPlan, error) {
	if err := policy.Validate(); err != nil {
		return ReviewPlan{}, fmt.Errorf("guard policy: %w", err)
	}

	used := make(map[Process]struct{})
	for _, endpoint := range policy.Endpoints {
		used[endpoint.Process] = struct{}{}
	}
	if len(appIDs) != len(used) {
		return ReviewPlan{}, fmt.Errorf("app IDs must correspond exactly to used transport processes")
	}
	for process := range used {
		id, ok := appIDs[process]
		if !ok || len(id) == 0 || len(id) > maxReviewAppIDBytes {
			return ReviewPlan{}, fmt.Errorf("missing or unbounded app ID for %q", process)
		}
		for other := range used {
			if other != process && bytes.Equal(id, appIDs[other]) {
				return ReviewPlan{}, fmt.Errorf("transport processes %q and %q share one app ID", process, other)
			}
		}
	}

	plan := ReviewPlan{
		Revision: policy.Revision,
		UserSID:  policy.UserSID,
		Rules: []ReviewRule{
			{Kind: ReviewPermitTunnel, Family: ReviewIPv4, InterfaceLUID: policy.TunnelLUID},
			{Kind: ReviewPermitTunnel, Family: ReviewIPv6, InterfaceLUID: policy.TunnelLUID},
		},
	}

	endpoints := slices.Clone(policy.Endpoints)
	slices.SortFunc(endpoints, func(a, b Endpoint) int {
		if n := a.IP.Compare(b.IP); n != 0 {
			return n
		}
		if n := bytes.Compare([]byte(a.Process), []byte(b.Process)); n != 0 {
			return n
		}
		if n := bytes.Compare([]byte(a.Protocol), []byte(b.Protocol)); n != 0 {
			return n
		}
		if a.Port != b.Port {
			return int(a.Port) - int(b.Port)
		}
		if a.InterfaceLUID < b.InterfaceLUID {
			return -1
		}
		if a.InterfaceLUID > b.InterfaceLUID {
			return 1
		}
		return 0
	})
	for _, endpoint := range endpoints {
		family := ReviewIPv6
		if endpoint.IP.Is4() {
			family = ReviewIPv4
		}
		plan.Rules = append(plan.Rules, ReviewRule{
			Kind: ReviewPermitEndpoint, Family: family,
			InterfaceLUID: endpoint.InterfaceLUID,
			Process:       endpoint.Process, AppID: bytes.Clone(appIDs[endpoint.Process]),
			Protocol: endpoint.Protocol, RemoteIP: endpoint.IP, RemotePort: endpoint.Port,
		})
	}
	// Deny rules are last in the review order. A native WFP implementation
	// must use verified sublayer/filter weights so exact permits are considered
	// before the hard block within the same sublayer on both IP families.
	plan.Rules = append(plan.Rules,
		ReviewRule{Kind: ReviewBlockAll, Family: ReviewIPv4},
		ReviewRule{Kind: ReviewBlockAll, Family: ReviewIPv6},
	)
	return plan, nil
}
