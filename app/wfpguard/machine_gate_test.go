package wfpguard

import (
	"errors"
	"net/netip"
	"reflect"
	"testing"
)

func gateFixture(t *testing.T) (Policy, map[Process][]byte, ReviewPlan) {
	t.Helper()
	policy := Policy{
		Revision: 1, RoutingMode: RoutingModeAllTraffic,
		UserSID: "S-1-5-21-1", TunnelLUID: 100,
		Endpoints: []Endpoint{{
			Process: ProcessSingBox, Protocol: ProtocolTCP,
			IP: netip.MustParseAddr("1.1.1.1"), Port: 443,
			InterfaceLUID: 200,
		}},
	}
	appIDs := map[Process][]byte{ProcessSingBox: {1, 2, 3}}
	plan, err := BuildReviewPlan(policy, appIDs)
	if err != nil {
		t.Fatal(err)
	}
	return policy, appIDs, plan
}

func TestMachineWideGateBlocksCanonicalCandidate(t *testing.T) {
	policy, appIDs, plan := gateFixture(t)
	err := PreflightMachineWideActivation(policy, appIDs, plan)
	if !errors.Is(err, ErrMachineWideActivationBlocked) {
		t.Fatalf("gate must block even a canonical candidate: %v", err)
	}
	var blocked *ActivationBlocked
	if !errors.As(err, &blocked) {
		t.Fatalf("gate did not return typed blockers: %v", err)
	}
	if !reflect.DeepEqual(blocked.Issues, machineWideUnresolvedIssues[:]) {
		t.Fatalf("unexpected gate issues: %v", blocked.Issues)
	}
	seen := make(map[GateIssue]bool)
	for _, issue := range blocked.Issues {
		if issue == "" || seen[issue] {
			t.Fatalf("empty or duplicate gate issue: %q", issue)
		}
		if issue.Requirement() == "" || issue.Requirement() == "unknown gate issue; do not arm" {
			t.Fatalf("gate issue %q has no actionable requirement", issue)
		}
		seen[issue] = true
	}
}

func TestMachineWideGateRejectsNoncanonicalCandidates(t *testing.T) {
	policy, _, original := gateFixture(t)
	tests := map[string]func(*Policy, map[Process][]byte, *ReviewPlan){
		"missing IPv6 deny": func(_ *Policy, _ map[Process][]byte, p *ReviewPlan) {
			p.Rules = p.Rules[:len(p.Rules)-1]
		},
		"broadened endpoint": func(_ *Policy, _ map[Process][]byte, p *ReviewPlan) {
			p.Rules[2].RemotePort = 0
		},
		"changed transport app": func(_ *Policy, _ map[Process][]byte, p *ReviewPlan) {
			p.Rules[2].AppID = []byte{9}
		},
		"changed authorization user": func(_ *Policy, _ map[Process][]byte, p *ReviewPlan) {
			p.UserSID = "S-1-5-21-2"
		},
		"extra wildcard permit": func(_ *Policy, _ map[Process][]byte, p *ReviewPlan) {
			p.Rules = append(p.Rules, ReviewRule{Kind: ReviewPermitEndpoint, Family: ReviewIPv4})
		},
		"invalid policy": func(p *Policy, _ map[Process][]byte, _ *ReviewPlan) {
			p.TunnelLUID = 0
		},
		"untrusted extra app": func(_ *Policy, ids map[Process][]byte, _ *ReviewPlan) {
			ids[ProcessXray] = []byte{9}
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			p := policy
			ids := map[Process][]byte{ProcessSingBox: {1, 2, 3}}
			candidate := original
			candidate.Rules = append([]ReviewRule(nil), original.Rules...)
			mutate(&p, ids, &candidate)
			err := PreflightMachineWideActivation(p, ids, candidate)
			var blocked *ActivationBlocked
			if !errors.As(err, &blocked) || !reflect.DeepEqual(blocked.Issues, []GateIssue{GateInvalidCandidate}) {
				t.Fatalf("expected invalid-candidate blocker, got %v", err)
			}
		})
	}
}
