package wfpguard

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"strings"
	"testing"
)

func validProtocolPolicy() Policy {
	return Policy{
		Revision:    2,
		RoutingMode: RoutingModeAllTraffic,
		UserSID:     "S-1-5-21-100-200-300-1001",
		TunnelLUID:  42,
		Endpoints: []Endpoint{{
			Process:       ProcessSingBox,
			Protocol:      ProtocolTCP,
			IP:            netip.MustParseAddr("1.1.1.1"),
			Port:          443,
			InterfaceLUID: 7,
		}},
	}
}

func TestDecodeGuardRequestAcceptsStrictArm(t *testing.T) {
	request := Request{Version: ProtocolVersion, Operation: OperationArm, ExpectedRevision: 1, Policy: pointerToPolicy(validProtocolPolicy())}
	data, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRequest(bytes.NewReader(data))
	if err != nil || decoded.Policy == nil || decoded.Policy.Revision != 2 {
		t.Fatalf("decoded request = %+v, err = %v", decoded, err)
	}
}

func TestDecodeGuardRequestRejectsUnsafeFrames(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"empty", ""},
		{"unknown operation", `{"version":1,"operation":"exec"}`},
		{"unknown field", `{"version":1,"operation":"status","command":"netsh"}`},
		{"duplicate field", `{"version":1,"operation":"status","operation":"arm"}`},
		{"case folded duplicate", `{"version":1,"Version":2,"operation":"status"}`},
		{"nested duplicate", `{"version":1,"operation":"arm","policy":{"Revision":1,"Revision":2}}`},
		{"trailing object", `{"version":1,"operation":"status"} {"version":1}`},
		{"wrong version", `{"version":2,"operation":"status"}`},
		{"status mutation", `{"version":1,"operation":"status","expectedRevision":1}`},
		{"arm without policy", `{"version":1,"operation":"arm"}`},
		{"disarm without revision", `{"version":1,"operation":"disarm"}`},
		{"oversized", strings.Repeat("x", MaxRequestBytes+1)},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := DecodeRequest(strings.NewReader(tt.body)); err == nil {
				t.Fatalf("unsafe guard frame %q accepted", tt.name)
			}
		})
	}
}

func TestGuardRequestRevisionFence(t *testing.T) {
	policy := validProtocolPolicy()
	if err := (Request{Version: ProtocolVersion, Operation: OperationArm, ExpectedRevision: 2, Policy: &policy}).Validate(); err == nil {
		t.Fatal("arm accepted a non-advancing revision")
	}
	if err := (Request{Version: ProtocolVersion, Operation: OperationDisarm, ExpectedRevision: 2}).Validate(); err != nil {
		t.Fatalf("valid fenced disarm rejected: %v", err)
	}
	if err := (Request{Version: ProtocolVersion, Operation: OperationDisarm, ExpectedRevision: 2, Policy: &policy}).Validate(); err == nil {
		t.Fatal("disarm accepted a replacement policy")
	}
}

func pointerToPolicy(policy Policy) *Policy { return &policy }
