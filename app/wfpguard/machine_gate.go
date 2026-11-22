package wfpguard

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
)

// Machine-wide activation is deliberately blocked until a native design can
// prove packet-level egress coverage as well as exact transport ownership.
// ReviewPlan alone is an ALE-oriented design sketch, not an enforcement plan.
//
// Microsoft WFP references:
//   https://learn.microsoft.com/en-us/windows/win32/fwp/ale-stateful-filtering
//   https://learn.microsoft.com/en-us/windows/win32/fwp/ale-re-authorization
//   https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-conditions-available-at-each-filtering-layer
//   https://learn.microsoft.com/en-us/windows/win32/fwp/filter-arbitration
//   https://learn.microsoft.com/en-us/windows/win32/fwp/object-management

var ErrMachineWideActivationBlocked = errors.New("machine-wide WFP activation is not ready")

// GateIssue identifies one unresolved safety property. These are stable codes
// for tests and diagnostics, not user-controlled overrides or approval tokens.
type GateIssue string

const (
	GateInvalidCandidate      GateIssue = "invalid_candidate"
	GatePacketEgressIdentity  GateIssue = "packet_egress_identity"
	GateALEReauthorization    GateIssue = "ale_reauthorization"
	GateBootstrapControlPlane GateIssue = "bootstrap_control_plane"
	GateOverlayPrecedence     GateIssue = "overlay_precedence"
	GateExistingFlows         GateIssue = "existing_flows"
	GateFilterOwnership       GateIssue = "filter_ownership"
	GateBootAndRecovery       GateIssue = "boot_and_recovery"
	GateVMLeakEvidence        GateIssue = "vm_leak_evidence"
)

// Requirement describes the evidence needed before a future implementation
// may remove a blocker. It is informational; supplying a string or test flag
// does not satisfy the gate.
func (issue GateIssue) Requirement() string {
	switch issue {
	case GateInvalidCandidate:
		return "rebuild an exact ReviewPlan from the validated policy and trusted, signature-verified transport app IDs"
	case GatePacketEgressIdentity:
		return "prove packet-by-packet physical egress cannot bypass the ALE app-bound exception; packet/transport WFP layers lack ALE_APP_ID, and IPPACKET lacks protocol and port conditions"
	case GateALEReauthorization:
		return "prove ALE reauthorization with FWP_EMPTY interface fields fails closed without breaking the tunnel or endpoint reconnect"
	case GateBootstrapControlPlane:
		return "define and test bounded DHCPv4/DHCPv6 and IPv6 neighbor-discovery/bootstrap exceptions without opening public DNS or arbitrary physical egress"
	case GateOverlayPrecedence:
		return "prove private/LAN and approved work-network/WireGuard overlay routes retain priority without becoming a public VPN-source catch-all"
	case GateExistingFlows:
		return "prove pre-existing TCP, UDP and IPv6 flows cannot continue on a physical interface after arming or route changes"
	case GateFilterOwnership:
		return "atomically stage provider, sublayer and all IPv4/IPv6 rules, then read back exact ownership, conditions, weights, actions, lifetime and revision before reporting active"
	case GateBootAndRecovery:
		return "prove reboot, BFE/service restart, crash, upgrade, disable and uninstall semantics, including the gap before persistent filters load"
	case GateVMLeakEvidence:
		return "capture Windows VM leak tests for other users and system services, IPv4/IPv6, adapter changes, sleep/wake, reconnect and tunnel failure"
	default:
		return "unknown gate issue; do not arm"
	}
}

// ActivationBlocked is returned even for a canonical ReviewPlan. No caller
// may infer protection from the plan or from successful policy validation.
type ActivationBlocked struct {
	Issues []GateIssue
}

func (e *ActivationBlocked) Error() string {
	parts := make([]string, len(e.Issues))
	for i, issue := range e.Issues {
		parts[i] = string(issue)
	}
	return fmt.Sprintf("%v: %s", ErrMachineWideActivationBlocked, strings.Join(parts, ", "))
}

func (e *ActivationBlocked) Unwrap() error { return ErrMachineWideActivationBlocked }

// PreflightMachineWideActivation is a fail-closed gate for the proposed full-
// device guard. It first requires a bit-for-bit canonical review plan built
// from a validated policy and trusted, signature-verified app IDs. It then
// returns the unresolved native and VM requirements. It NEVER returns nil in
// this version; it does not create, update, or delete any WFP object.
//
// The app IDs must come from the installed binaries, not IPC. The UserSID in
// the policy binds IPC authorization; it must not narrow machine-wide traffic.
func PreflightMachineWideActivation(policy Policy, appIDs map[Process][]byte, candidate ReviewPlan) error {
	expected, err := BuildReviewPlan(policy, appIDs)
	if err != nil || !reflect.DeepEqual(candidate, expected) {
		return &ActivationBlocked{Issues: []GateIssue{GateInvalidCandidate}}
	}
	return &ActivationBlocked{Issues: append([]GateIssue(nil), machineWideUnresolvedIssues[:]...)}
}

// A pure ALE_AUTH_CONNECT deny is insufficient: WFP authorizes flows and may
// leave existing traffic permitted until reauthorization. A packet-layer deny
// addresses egress coverage but the OUTBOUND_IPPACKET and OUTBOUND_TRANSPORT
// layer condition schemas have no ALE_APP_ID; IPPACKET additionally has no
// protocol or remote-port condition. The design must prove an acceptable
// combined policy before permitting even a staged AddFilter transaction.
var machineWideUnresolvedIssues = [...]GateIssue{
	GatePacketEgressIdentity,
	GateALEReauthorization,
	GateBootstrapControlPlane,
	GateOverlayPrecedence,
	GateExistingFlows,
	GateFilterOwnership,
	GateBootAndRecovery,
	GateVMLeakEvidence,
}
