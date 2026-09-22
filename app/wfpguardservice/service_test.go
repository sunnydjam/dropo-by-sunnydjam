package wfpguardservice

import (
	"net/netip"
	"testing"

	"dropo/wfpguard"
)

const testSID = "S-1-5-21-100-200-300-1001"

func testArmRequest() wfpguard.Request {
	return wfpguard.Request{
		Version:   wfpguard.ProtocolVersion,
		Operation: wfpguard.OperationArm,
		Policy: &wfpguard.Policy{
			Revision:    1,
			RoutingMode: wfpguard.RoutingModeAllTraffic,
			UserSID:     testSID,
			TunnelLUID:  10,
			Endpoints: []wfpguard.Endpoint{{
				Process:       wfpguard.ProcessSingBox,
				Protocol:      wfpguard.ProtocolTCP,
				IP:            netip.MustParseAddr("8.8.8.8"),
				Port:          443,
				InterfaceLUID: 20,
			}},
		},
	}
}

func TestHandlerNeverReportsActiveOrAdvancesRevision(t *testing.T) {
	h, err := NewHandler(testSID)
	if err != nil {
		t.Fatal(err)
	}
	for _, request := range []wfpguard.Request{
		{Version: wfpguard.ProtocolVersion, Operation: wfpguard.OperationStatus},
		testArmRequest(),
		{Version: wfpguard.ProtocolVersion, Operation: wfpguard.OperationDisarm, ExpectedRevision: 1},
	} {
		response := h.Handle(testSID, request)
		if response.ProtectionActive || response.Revision != 0 || response.State != "not_integrated" {
			t.Fatalf("unimplemented service claimed protection: %+v", response)
		}
	}
}

func TestHandlerChecksCallerAndPolicySID(t *testing.T) {
	h, _ := NewHandler(testSID)
	for _, caller := range []string{"", "S-1-5-21-100-200-300-1002"} {
		response := h.Handle(caller, testArmRequest())
		if response.Error != ErrUnauthorized.Error() {
			t.Fatalf("caller %q: %+v", caller, response)
		}
	}
	request := testArmRequest()
	request.Policy.UserSID = "S-1-5-21-100-200-300-1002"
	response := h.Handle(testSID, request)
	if response.Error != ErrUnauthorized.Error() {
		t.Fatalf("policy SID mismatch: %+v", response)
	}
}

func TestHandlerRevisionFence(t *testing.T) {
	h, _ := NewHandler(testSID)
	request := testArmRequest()
	request.ExpectedRevision = 1
	request.Policy.Revision = 2
	response := h.Handle(testSID, request)
	if response.Error != ErrStaleRevision.Error() {
		t.Fatalf("stale arm: %+v", response)
	}
	request = testArmRequest()
	response = h.Handle(testSID, request)
	if response.Error != ErrNotIntegrated.Error() {
		t.Fatalf("non-stale arm should still be unimplemented: %+v", response)
	}
}

func TestHandlerRequiresUserSID(t *testing.T) {
	if _, err := NewHandler(""); err == nil {
		t.Fatal("empty user SID accepted")
	}
}
