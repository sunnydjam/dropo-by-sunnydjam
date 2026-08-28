package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBridgeTokenAuthorized(t *testing.T) {
	const token = "deadbeef"
	cases := []struct {
		name     string
		expected string
		header   string
		want     bool
	}{
		{"empty expected denies", "", "", false},
		{"empty expected denies even with header", "", "whatever", false},
		{"correct token", token, token, true},
		{"wrong token", token, "nope", false},
		{"missing token", token, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/api/call", nil)
			if tc.header != "" {
				r.Header.Set(bridgeAuthHeader, tc.header)
			}
			if got := bridgeTokenAuthorized(r, tc.expected); got != tc.want {
				t.Fatalf("bridgeTokenAuthorized = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestRepairBridgeTokenFileRestoresMissingAndStaleToken(t *testing.T) {
	dataPath := t.TempDir()
	const token = "current-core-token"

	repaired, err := repairBridgeTokenFile(dataPath, token)
	if err != nil || !repaired {
		t.Fatalf("initial repair = repaired:%v err:%v, want true nil", repaired, err)
	}
	path := filepath.Join(dataPath, bridgeTokenFileName)
	if data, err := os.ReadFile(path); err != nil || string(data) != token {
		t.Fatalf("initial token file = %q err:%v, want %q", data, err, token)
	}

	repaired, err = repairBridgeTokenFile(dataPath, token)
	if err != nil || repaired {
		t.Fatalf("matching token repair = repaired:%v err:%v, want false nil", repaired, err)
	}

	if err := os.WriteFile(path, []byte("stale-ui-token"), 0600); err != nil {
		t.Fatal(err)
	}
	repaired, err = repairBridgeTokenFile(dataPath, token)
	if err != nil || !repaired {
		t.Fatalf("stale token repair = repaired:%v err:%v, want true nil", repaired, err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != token {
		t.Fatalf("repaired token file = %q err:%v, want %q", data, err, token)
	}
}

func TestMaintainBridgeTokenFileRestoresDeletedToken(t *testing.T) {
	dataPath := t.TempDir()
	const token = "live-core-token"
	if _, err := repairBridgeTokenFile(dataPath, token); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go maintainBridgeTokenFile(ctx, dataPath, token, nil)
	path := filepath.Join(dataPath, bridgeTokenFileName)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * bridgeTokenRepairInterval)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(path); err == nil && string(data) == token {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("token maintainer did not restore the deleted bridge token")
}

// loopbackRequest builds a request whose Host is loopback so it passes the
// DNS-rebinding guard, isolating the auth behavior under test.
func loopbackRequest(method, path string, body *bytes.Buffer) *http.Request {
	var r *http.Request
	if body != nil {
		r = httptest.NewRequest(method, path, body)
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	r.Host = "127.0.0.1:17890"
	return r
}

// TestBridgeMuxGuardsMutating verifies the token gate short-circuits mutating
// endpoints before any App method runs, while leaving read-only endpoints open.
func TestBridgeMuxGuardsMutating(t *testing.T) {
	const token = "s3cr3t-token"
	mux := newBridgeMux(&App{}, token)

	// Mutating endpoint without token -> 401, App.Start never invoked.
	noTok := httptest.NewRecorder()
	mux.ServeHTTP(noTok, loopbackRequest(http.MethodPost, "/api/call", bytes.NewBufferString(`{"method":"Nope"}`)))
	if noTok.Code != http.StatusUnauthorized {
		t.Fatalf("guarded endpoint without token: status = %d, want 401", noTok.Code)
	}

	// Mutating endpoint with token -> auth passes (bogus method yields 400, not 401).
	withTok := httptest.NewRecorder()
	req := loopbackRequest(http.MethodPost, "/api/call", bytes.NewBufferString(`{"method":"Nope"}`))
	req.Header.Set(bridgeAuthHeader, token)
	mux.ServeHTTP(withTok, req)
	if withTok.Code == http.StatusUnauthorized {
		t.Fatalf("guarded endpoint with valid token still returned 401")
	}

	// Read-only OPTIONS preflight is never gated.
	opt := httptest.NewRecorder()
	mux.ServeHTTP(opt, loopbackRequest(http.MethodOptions, "/api/connect", nil))
	if opt.Code != http.StatusNoContent {
		t.Fatalf("OPTIONS preflight: status = %d, want 204", opt.Code)
	}

	// /api/logs is now guarded (it can expose sensitive detail): no token -> 401.
	logsNoTok := httptest.NewRecorder()
	mux.ServeHTTP(logsNoTok, loopbackRequest(http.MethodGet, "/api/logs", nil))
	if logsNoTok.Code != http.StatusUnauthorized {
		t.Fatalf("/api/logs without token: status = %d, want 401", logsNoTok.Code)
	}
}

// TestBridgeMuxRejectsNonLoopbackHost verifies the DNS-rebinding guard: any
// request whose Host is not loopback is refused with 403 before auth/handler.
func TestBridgeMuxRejectsNonLoopbackHost(t *testing.T) {
	const token = "s3cr3t-token"
	mux := newBridgeMux(&App{}, token)

	rebind := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rebind.Host = "attacker.example" // resolves to 127.0.0.1 in a rebinding attack
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, rebind)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-loopback Host: status = %d, want 403", rec.Code)
	}

	// A loopback Host on the same open endpoint is served normally.
	ok := httptest.NewRecorder()
	mux.ServeHTTP(ok, loopbackRequest(http.MethodGet, "/api/status", nil))
	if ok.Code != http.StatusOK {
		t.Fatalf("loopback Host on /api/status: status = %d, want 200", ok.Code)
	}
}

// TestBridgeDropsCORSWildcard guards against reintroducing a wildcard CORS grant
// that would let arbitrary web pages read bridge responses.
func TestBridgeDropsCORSWildcard(t *testing.T) {
	mux := newBridgeMux(&App{}, "tok")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, loopbackRequest(http.MethodGet, "/api/status", nil))
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want empty (no CORS grant)", got)
	}
}

func TestHostHeaderLoopback(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"", true},
		{"127.0.0.1:17890", true},
		{"127.0.0.1", true},
		{"localhost:17890", true},
		{"localhost", true},
		{"[::1]:17890", true},
		{"::1", true},
		{"attacker.example", false},
		{"attacker.example:17890", false},
		{"192.168.1.10:17890", false},
		{"10.0.0.5", false},
	}
	for _, tc := range cases {
		if got := hostHeaderLoopback(tc.host); got != tc.want {
			t.Errorf("hostHeaderLoopback(%q) = %v, want %v", tc.host, got, tc.want)
		}
	}
}

func TestBridgeCallAllowlistRejectsExportedMaintenanceMethods(t *testing.T) {
	_, err := callAppMethod(&App{}, bridgeCallRequest{Method: "RebuildActiveProfileConfig"})
	if err == nil {
		t.Fatal("RebuildActiveProfileConfig unexpectedly exposed through /api/call")
	}
	if _, ok := bridgeCallableMethods["GetAppConfig"]; !ok {
		t.Fatal("GetAppConfig must remain available to the Flutter UI")
	}
	if _, ok := bridgeCallableMethods["DownloadAndInstallUpdate"]; !ok {
		t.Fatal("DownloadAndInstallUpdate must be available to the trusted Flutter UI")
	}
	if _, ok := bridgeCallableMethods["SelectTrafficStrategy"]; !ok {
		t.Fatal("SelectTrafficStrategy must be available to diagnostics through the trusted Flutter UI")
	}
	for _, method := range []string{
		"GetVPNSources", "AddVPNSource", "RemoveVPNSource", "RefreshVPNSources",
		"SetVPNSourceEnabled", "SetVPNSourceNode", "MoveVPNSource",
		"SetFreeAccessServiceMethod", "SetZapretServiceStrategy", "SetHomeRouteServiceVisible",
	} {
		if _, ok := bridgeCallableMethods[method]; !ok {
			t.Fatalf("%s must be available to the trusted Flutter UI", method)
		}
	}
}
