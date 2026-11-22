package wfpguard

import (
	"bytes"
	"net/netip"
	"reflect"
	"slices"
	"testing"
)

func reviewPolicy() Policy {
	return Policy{
		Revision: 7, RoutingMode: RoutingModeAllTraffic,
		UserSID: "S-1-5-21-42", TunnelLUID: 100,
		Endpoints: []Endpoint{
			{Process: ProcessXray, Protocol: ProtocolUDP, IP: netip.MustParseAddr("2606:4700::1111"), Port: 443, InterfaceLUID: 201},
			{Process: ProcessSingBox, Protocol: ProtocolTCP, IP: netip.MustParseAddr("1.1.1.1"), Port: 8443, InterfaceLUID: 200},
		},
	}
}

func TestBuildReviewPlanExactFamilyCoverage(t *testing.T) {
	appIDs := map[Process][]byte{ProcessSingBox: {1, 2, 3}, ProcessXray: {4, 5, 6}}
	plan, err := BuildReviewPlan(reviewPolicy(), appIDs)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Revision != 7 || plan.UserSID != "S-1-5-21-42" || len(plan.Rules) != 6 {
		t.Fatalf("unexpected review plan: %+v", plan)
	}
	for i, family := range []ReviewFamily{ReviewIPv4, ReviewIPv6} {
		rule := plan.Rules[i]
		if rule.Kind != ReviewPermitTunnel || rule.Family != family || rule.InterfaceLUID != 100 ||
			rule.Process != "" || len(rule.AppID) != 0 || rule.RemoteIP.IsValid() || rule.RemotePort != 0 {
			t.Fatalf("tunnel rule %d is broad or malformed: %+v", i, rule)
		}
	}
	for _, rule := range plan.Rules[2:4] {
		if rule.Kind != ReviewPermitEndpoint || rule.InterfaceLUID == 0 || rule.InterfaceLUID == 100 ||
			rule.Process == "" || len(rule.AppID) == 0 || rule.Protocol == "" ||
			!rule.RemoteIP.IsValid() || rule.RemotePort == 0 {
			t.Fatalf("endpoint exception is not exact: %+v", rule)
		}
		if rule.RemoteIP.Is4() != (rule.Family == ReviewIPv4) {
			t.Fatalf("endpoint assigned wrong IP family: %+v", rule)
		}
	}
	for i, family := range []ReviewFamily{ReviewIPv4, ReviewIPv6} {
		rule := plan.Rules[4+i]
		if rule.Kind != ReviewBlockAll || rule.Family != family || rule.InterfaceLUID != 0 ||
			rule.Process != "" || len(rule.AppID) != 0 || rule.RemoteIP.IsValid() || rule.RemotePort != 0 {
			t.Fatalf("deny rule %d has unexpected exception: %+v", i, rule)
		}
	}
}

func TestBuildReviewPlanIndependentOfInputOrderAndMemory(t *testing.T) {
	policy := reviewPolicy()
	ids := map[Process][]byte{ProcessSingBox: {1, 2}, ProcessXray: {3, 4}}
	first, err := BuildReviewPlan(policy, ids)
	if err != nil {
		t.Fatal(err)
	}
	slices.Reverse(policy.Endpoints)
	second, err := BuildReviewPlan(policy, ids)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("plan depends on endpoint input order:\n%+v\n%+v", first, second)
	}
	ids[ProcessSingBox][0] = 99
	if bytes.Equal(first.Rules[2].AppID, ids[ProcessSingBox]) || bytes.Equal(first.Rules[3].AppID, ids[ProcessSingBox]) {
		t.Fatal("review plan aliases app-ID input")
	}
}

func TestBuildReviewPlanFailsClosedOnUnresolvedIdentity(t *testing.T) {
	valid := reviewPolicy()
	cases := []map[Process][]byte{
		nil,
		{ProcessSingBox: {1}},
		{ProcessSingBox: {1}, ProcessXray: nil},
		{ProcessSingBox: {1}, ProcessXray: {1}},
		{ProcessSingBox: {1}, ProcessXray: {2}, ProcessWireGuard: {3}},
		{ProcessSingBox: bytes.Repeat([]byte{1}, maxReviewAppIDBytes+1), ProcessXray: {2}},
	}
	for i, ids := range cases {
		if plan, err := BuildReviewPlan(valid, ids); err == nil || len(plan.Rules) != 0 {
			t.Errorf("case %d accepted unresolved or ambiguous process identity: %+v, %v", i, plan, err)
		}
	}
	invalid := valid
	invalid.RoutingMode = "blocked_only"
	if plan, err := BuildReviewPlan(invalid, map[Process][]byte{ProcessSingBox: {1}, ProcessXray: {2}}); err == nil || len(plan.Rules) != 0 {
		t.Fatalf("non-full-tunnel policy accepted: %+v, %v", plan, err)
	}
}
