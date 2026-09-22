package main

import (
	"testing"
	"time"
)

// Until a persistent Windows filtering owner exists, connection state must
// never be mistaken for leak protection. In particular, "connected" and
// "reconnecting" do not imply that packets are blocked outside the tunnel.
func TestWindowsVPNStatusDoesNotClaimReconnectProtection(t *testing.T) {
	tests := []struct {
		name          string
		wantState     string
		wantConnected bool
		setup         func(*App)
	}{
		{name: "stopped", wantState: "stopped"},
		{
			name:      "starting",
			wantState: "starting",
			setup: func(app *App) {
				app.desiredConnected.Store(true)
				app.mu.Lock()
				app.isStarting = true
				app.mu.Unlock()
			},
		},
		{
			name:          "connected",
			wantState:     "connected",
			wantConnected: true,
			setup: func(app *App) {
				app.desiredConnected.Store(true)
				app.mu.Lock()
				app.isRunning = true
				app.mu.Unlock()
			},
		},
		{
			name:      "reconnecting",
			wantState: "reconnecting",
			setup: func(app *App) {
				app.desiredConnected.Store(true)
				app.reconnecting.Store(true)
			},
		},
		{
			name:      "failed",
			wantState: "failed",
			setup: func(app *App) {
				app.desiredConnected.Store(true)
				app.hasError.Store(true)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := NewApp()
			app.initialized = true
			app.initializedReady.Store(true)
			if tt.setup != nil {
				tt.setup(app)
			}

			status := app.GetStatus()
			if got := status["vpnState"]; got != tt.wantState {
				t.Fatalf("vpnState = %v, want %s", got, tt.wantState)
			}
			if got := status["connected"]; got != tt.wantConnected {
				t.Fatalf("connected = %v, want %v", got, tt.wantConnected)
			}
			if got, ok := status["reconnectProtected"].(bool); !ok || got {
				t.Fatalf("reconnectProtected = %v, want explicit false", status["reconnectProtected"])
			}
			protection, ok := status["vpnProtection"].(VPNProtectionStatus)
			if !ok || protection.Available || protection.Active {
				t.Fatalf("vpnProtection = %#v, want an explicit unavailable, inactive capability", status["vpnProtection"])
			}
		})
	}
}

func TestManualStopDoesNotClaimReconnectProtection(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)
	app.reconnecting.Store(true)

	result := app.Stop()
	if result["success"] != true {
		t.Fatalf("Stop() = %#v", result)
	}
	status := app.GetStatus()
	if status["desiredConnected"] != false || status["reconnectProtected"] != false {
		t.Fatalf("manual Stop protection status = %#v", status)
	}
}

func TestTerminalReconnectFailureDoesNotClaimProtection(t *testing.T) {
	app := NewApp()
	withReconnectTestDelays(t, app, []time.Duration{0})
	app.initialized = true
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		return map[string]interface{}{"success": false, "error": "offline"}
	}
	app.scheduleVPNReconnect("test crash")

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		status := app.GetStatus()
		if status["vpnState"] == "failed" {
			if status["reconnectProtected"] != false || status["desiredConnected"] != true {
				t.Fatalf("terminal reconnect failure protection status = %#v", status)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("reconnect did not reach failed state: %#v", app.GetStatus())
}

func TestWindowsProtectionCapabilityPreservesDirectFirstMode(t *testing.T) {
	selective := vpnProtectionStatusForPlatform(RoutingModeBlockedOnly, "windows")
	if selective.Available || selective.Active || selective.EligibleMode || selective.TargetScope != "vpn_services" || selective.State != "selective_guard_not_integrated" {
		t.Fatalf("selective mode must target only VPN-designated traffic without advertising protection: %+v", selective)
	}

	full := vpnProtectionStatusForPlatform(RoutingModeAllTraffic, "windows")
	if full.Available || full.Active || !full.EligibleMode || full.TargetScope != "device" || full.State != "guard_not_integrated" {
		t.Fatalf("full-tunnel mode must identify device scope without claiming active protection: %+v", full)
	}

	other := vpnProtectionStatusForPlatform(RoutingModeAllTraffic, "linux")
	if other.Available || other.Active || other.EligibleMode || other.TargetScope != "" || other.State != "unsupported_platform" {
		t.Fatalf("non-Windows desktop must not inherit Windows protection: %+v", other)
	}
}
