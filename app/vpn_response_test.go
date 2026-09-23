package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func newVPNResponseTestApp(t *testing.T, handler http.HandlerFunc) (*App, context.Context, uint64) {
	t.Helper()
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	sources := []VPNSource{
		{ID: "alpha", URI: "vless://secret@alpha.example:443", SelectedNodeID: "node-alpha"},
		{ID: "beta", URI: "vless://other-secret@beta.example:443", SelectedNodeID: "node-beta"},
	}
	if err := storage.UpdateProfileVPNSources(1, sources, nil); err != nil {
		t.Fatal(err)
	}
	if err := storage.UpdateProfileConfig(1, map[string]interface{}{"outbounds": []interface{}{
		map[string]interface{}{"tag": "vpn-source-alpha", "type": "socks"},
		map[string]interface{}{"tag": "vpn-source-beta", "type": "socks"},
	}}); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	app := &App{
		storage: storage, configBuilder: NewConfigBuilderForStorage(storage),
		isRunning: true, initialized: true, vpnSourceMonitorGeneration: 3,
		vpnSourceMonitorCancel: cancel, vpnSourceActive: "vpn-source-alpha",
	}
	app.initializedReady.Store(true)
	app.reconnectGeneration.Store(7)
	if handler != nil {
		server := httptest.NewServer(handler)
		t.Cleanup(server.Close)
		parsed, _ := url.Parse(server.URL)
		_, portText, _ := net.SplitHostPort(parsed.Host)
		port, _ := strconv.Atoi(portText)
		app.configBuilder.clashAPI = &clashAPIAccess{port: port, secret: "test-secret"}
	}
	t.Cleanup(app.stopVPNSourceMonitor)
	return app, ctx, 3
}

func TestVPNResponseUsesExistingProbeWithBindingAndAge(t *testing.T) {
	var requests atomic.Int32
	app, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Header.Get("Authorization") != "Bearer test-secret" || r.URL.Path != "/proxies/vpn-source-alpha/delay" || r.URL.Query().Get("url") != vpnResponseProbeTarget {
			t.Errorf("unexpected probe request: %s", r.URL)
		}
		fmt.Fprint(w, `{"delay":42}`)
	})
	if initial := app.vpnResponseSnapshot(true, time.Now()); initial.State != "pending" || initial.LatencyMS != nil {
		t.Fatalf("initial = %+v", initial)
	}
	if healthy, current := app.vpnSourceHealthy(ctx, generation, "vpn-source-alpha"); !healthy || !current {
		t.Fatal("existing source probe failed")
	}
	snapshot := app.vpnResponseSnapshot(true, time.Now().Add(2*time.Second))
	if snapshot.State != "ok" || snapshot.LatencyMS == nil || *snapshot.LatencyMS != 42 || snapshot.SourceID != "alpha" || snapshot.NodeID != "node-alpha" || snapshot.ProfileID != 1 || snapshot.SessionGeneration != 7 || snapshot.ProbeKind != "http" || snapshot.Target != vpnResponseProbeTarget {
		t.Fatalf("response = %+v", snapshot)
	}
	if stamp, err := time.Parse(time.RFC3339, snapshot.CheckedAt); err != nil || stamp.Location() != time.UTC || snapshot.AgeSeconds == nil || *snapshot.AgeSeconds < 2 {
		t.Fatalf("missing truthful age: %+v", snapshot)
	}
	for index := 0; index < 10; index++ {
		app.vpnResponseSnapshot(true, time.Now())
	}
	if requests.Load() != 1 {
		t.Fatalf("snapshot reads initiated probes: %d", requests.Load())
	}
	encoded, err := json.Marshal(app.GetStatus())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"vpnResponse":{"state":"ok"`) || strings.Contains(string(encoded), "other-secret") || strings.Contains(string(encoded), "alpha.example") {
		t.Fatalf("unsafe/missing response snapshot: %s", encoded)
	}
}

func TestVPNResponseNeverPresentsZeroOrTimeoutAsLatency(t *testing.T) {
	app, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"delay":0}`) })
	if healthy, current := app.vpnSourceHealthy(ctx, generation, "vpn-source-alpha"); healthy || !current {
		t.Fatal("zero delay was accepted as a measured response")
	}
	snapshot := app.vpnResponseSnapshot(true, time.Now())
	if snapshot.State != "failed" || snapshot.LatencyMS != nil || snapshot.CheckedAt == "" || snapshot.Error == "" {
		t.Fatalf("failed response = %+v", snapshot)
	}
	encoded, _ := json.Marshal(snapshot)
	if !strings.Contains(string(encoded), `"latencyMs":null`) {
		t.Fatalf("failure included fake ms: %s", encoded)
	}
	for _, test := range []struct {
		status int
		body   string
	}{
		{200, `{}`}, {200, `{"delay":-4}`}, {503, `{"delay":55}`}, {200, `not-json`},
	} {
		t.Run(fmt.Sprint(test.status, test.body), func(t *testing.T) {
			app, _, _ := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(test.status); fmt.Fprint(w, test.body) })
			if result := app.TestProxyDelay("vpn-source-alpha"); result["success"] != false {
				t.Fatalf("invalid delay accepted: %v", result)
			}
		})
	}
}

func TestVPNResponseExpiresAndRejectsClockReversal(t *testing.T) {
	app, ctx, generation := newVPNResponseTestApp(t, nil)
	binding, _ := app.vpnSourceProbeBinding("vpn-source-alpha")
	now := time.Now()
	if !app.recordVPNSourceObservation(ctx, generation, "vpn-source-alpha", binding, 81, true, now) {
		t.Fatal("record failed")
	}
	stale := app.vpnResponseSnapshot(true, now.Add(vpnResponseMaxAge+time.Second))
	if stale.State != "stale" || stale.LatencyMS != nil || stale.CheckedAt == "" || stale.AgeSeconds == nil {
		t.Fatalf("stale response = %+v", stale)
	}
	future := app.vpnResponseSnapshot(true, now.Add(-time.Second))
	if future.State != "pending" || future.LatencyMS != nil || future.CheckedAt != "" {
		t.Fatalf("future sample accepted: %+v", future)
	}
}

func TestVPNResponseClearsAcrossManualSourceNodeProfileAndSessionChanges(t *testing.T) {
	for _, change := range []string{"manual-source", "node", "node-index-mismatch", "profile", "disabled", "session", "stop"} {
		t.Run(change, func(t *testing.T) {
			app, ctx, generation := newVPNResponseTestApp(t, nil)
			binding, _ := app.vpnSourceProbeBinding("vpn-source-alpha")
			if !app.recordVPNSourceObservation(ctx, generation, "vpn-source-alpha", binding, 63, true, time.Now()) {
				t.Fatal("record failed")
			}
			switch change {
			case "manual-source":
				app.activateVPNSource("vpn-source-beta", true)
			case "node", "node-index-mismatch", "disabled":
				profile, _ := app.storage.GetActiveProfile()
				sources := append([]VPNSource(nil), profile.VPNSources...)
				if change == "node" {
					sources[0].SelectedNodeID = "new-node"
				} else if change == "node-index-mismatch" {
					sources[0].NodeIDs = []string{"new-node"}
				} else {
					sources[0].Disabled = true
				}
				if err := app.storage.UpdateProfileVPNSources(profile.ID, sources, nil); err != nil {
					t.Fatal(err)
				}
			case "profile":
				profile, err := app.storage.CreateProfile("Other")
				if err != nil {
					t.Fatal(err)
				}
				if err := app.storage.SetActiveProfileID(profile.ID); err != nil {
					t.Fatal(err)
				}
			case "session":
				app.reconnectGeneration.Add(1)
			case "stop":
				app.stopVPNSourceMonitor()
			}
			snapshot := app.vpnResponseSnapshot(true, time.Now())
			if snapshot.State == "ok" || snapshot.LatencyMS != nil || snapshot.CheckedAt != "" {
				t.Fatalf("stale measurement survived %s: %+v", change, snapshot)
			}
			if change != "manual-source" && app.recordVPNSourceObservation(ctx, generation, "vpn-source-alpha", binding, 88, true, time.Now()) {
				t.Fatalf("old in-flight observation committed after %s", change)
			}
		})
	}
}

func TestVPNResponseCancellationStopsInFlightRequestAndRejectsLateResult(t *testing.T) {
	entered, cancelled := make(chan struct{}), make(chan struct{})
	app, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-r.Context().Done()
		close(cancelled)
	})
	done := make(chan bool, 1)
	go func() { _, current := app.vpnSourceHealthy(ctx, generation, "vpn-source-alpha"); done <- current }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("probe did not enter local API")
	}
	app.stopVPNSourceMonitor()
	select {
	case current := <-done:
		if current {
			t.Fatal("stopped probe remained current")
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel the request")
	}
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("HTTP request context was not cancelled")
	}
	if snapshot := app.vpnResponseSnapshot(false, time.Now()); snapshot.State != "unavailable" || snapshot.LatencyMS != nil || snapshot.CheckedAt != "" {
		t.Fatalf("stopped response = %+v", snapshot)
	}
}

func TestVPNResponsePendingAndFailedBootstrapHaveNoInventedActiveSource(t *testing.T) {
	app, _, _ := newVPNResponseTestApp(t, nil)
	app.vpnSourceActive = ""
	if snapshot := app.vpnResponseSnapshot(true, time.Now()); snapshot.State != "pending" || snapshot.SourceID != "" || snapshot.LatencyMS != nil {
		t.Fatalf("pending bootstrap = %+v", snapshot)
	}
	app.vpnSourceHealthKnown = true
	if snapshot := app.vpnResponseSnapshot(true, time.Now()); snapshot.State != "failed" || snapshot.SourceID != "" || snapshot.LatencyMS != nil {
		t.Fatalf("failed bootstrap = %+v", snapshot)
	}
}
