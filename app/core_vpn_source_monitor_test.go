package main

import (
	"testing"
	"time"
)

func TestVPNSourceHealthStateUsesHysteresisAndCircuitBreaker(t *testing.T) {
	now := time.Unix(1000, 0)
	state := nextVPNSourceHealthState(vpnSourceHealthState{}, false, now)
	if state.ConsecutiveFailures != 1 || !state.OpenUntil.IsZero() {
		t.Fatalf("first failure must not open circuit: %+v", state)
	}
	state = nextVPNSourceHealthState(state, false, now.Add(time.Second))
	if state.ConsecutiveFailures != vpnSourceFailureThreshold || !state.OpenUntil.After(now) {
		t.Fatalf("confirmed failures must open circuit: %+v", state)
	}
	state = nextVPNSourceHealthState(state, true, state.OpenUntil.Add(time.Second))
	if state.ConsecutiveFailures != 0 || state.ConsecutiveSuccesses != 1 || !state.OpenUntil.IsZero() {
		t.Fatalf("successful check after cooldown must close circuit: %+v", state)
	}
}

func TestVPNSourceRecoveryRequiresConsecutiveSuccesses(t *testing.T) {
	now := time.Unix(2000, 0)
	state := vpnSourceHealthState{}
	for index := 0; index < vpnSourceRecoveryThreshold; index++ {
		state = nextVPNSourceHealthState(state, true, now.Add(time.Duration(index)*time.Second))
	}
	if state.ConsecutiveSuccesses != vpnSourceRecoveryThreshold {
		t.Fatalf("recovery successes = %d", state.ConsecutiveSuccesses)
	}
	state = nextVPNSourceHealthState(state, false, now.Add(time.Minute))
	if state.ConsecutiveSuccesses != 0 {
		t.Fatalf("failure must reset recovery hysteresis: %+v", state)
	}
}

func TestFullVPNSourceFailureIsReportedOnlyForRunningAllTraffic(t *testing.T) {
	failed, message := fullVPNSourceFailure(true, RoutingModeAllTraffic, true, false, "node unavailable")
	if !failed || message != "node unavailable" {
		t.Fatalf("all-traffic failure = (%v, %q), want (true, node unavailable)", failed, message)
	}

	for _, test := range []struct {
		name      string
		running   bool
		mode      RoutingMode
		known     bool
		available bool
	}{
		{name: "stopped", mode: RoutingModeAllTraffic, known: true},
		{name: "selective", running: true, mode: RoutingModeBlockedOnly, known: true},
		{name: "pending", running: true, mode: RoutingModeAllTraffic},
		{name: "healthy", running: true, mode: RoutingModeAllTraffic, known: true, available: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			failed, message := fullVPNSourceFailure(test.running, test.mode, test.known, test.available, "node unavailable")
			if failed || message != "" {
				t.Fatalf("failure = (%v, %q), want (false, empty)", failed, message)
			}
		})
	}
}

func TestFullVPNSourceFailureUsesSafeDefaultMessage(t *testing.T) {
	failed, message := fullVPNSourceFailure(true, RoutingModeAllTraffic, true, false, "")
	if !failed || message != vpnSourceUnavailableMessage {
		t.Fatalf("failure = (%v, %q), want default message", failed, message)
	}
}
