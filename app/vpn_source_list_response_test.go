package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestVPNSourceListShowsIndependentObservationsWithoutProbing(t *testing.T) {
	var requests atomic.Int32
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, `{"delay":42}`)
	})
	for _, tag := range []string{"vpn-source-alpha", "vpn-source-beta"} {
		if healthy, current := a.vpnSourceHealthy(ctx, generation, tag); !healthy || !current {
			t.Fatal("probe did not complete")
		}
	}
	for i := 0; i < 3; i++ {
		result := a.GetVPNSources()
		if result["running"] != true {
			t.Fatalf("missing running state: %v", result)
		}
		views := result["sources"].([]map[string]interface{})
		for i, view := range views {
			response := view["response"].(vpnResponse)
			if response.State != "ok" || response.LatencyMS == nil || *response.LatencyMS != 42 || response.SourceID != view["id"] {
				t.Fatalf("incorrect bound observation: %+v", response)
			}
			if view["active"] != (i == 0) {
				t.Fatalf("inactive source marked active: %v", view)
			}
		}
		encoded, _ := json.Marshal(result)
		for _, secret := range []string{"secret@", "alpha.example", "other-secret", "test-secret"} {
			if strings.Contains(string(encoded), secret) {
				t.Fatal("source response leaked credentials")
			}
		}
	}
	if requests.Load() != 2 {
		t.Fatalf("list reads initiated probes: %d", requests.Load())
	}
}

func TestVPNSourceListResponseRejectsObsoleteSamples(t *testing.T) {
	for _, change := range []string{"stale", "future", "node", "profile", "disabled", "session", "stop", "offline"} {
		t.Run(change, func(t *testing.T) {
			a, ctx, generation := newVPNResponseTestApp(t, nil)
			const tag = "vpn-source-beta" // Not the active source.
			binding, _ := a.vpnSourceProbeBinding(tag)
			now := time.Now()
			if !a.recordVPNSourceObservation(ctx, generation, tag, binding, 21, true, now) {
				t.Fatal("record failed")
			}
			running := true
			switch change {
			case "stale":
				now = now.Add(vpnResponseMaxAge + time.Second)
			case "future":
				now = now.Add(-time.Second)
			case "node", "disabled":
				profile, _ := a.storage.GetActiveProfile()
				if change == "node" {
					profile.VPNSources[1].SelectedNodeID = "changed"
				} else {
					profile.VPNSources[1].Disabled = true
				}
				if err := a.storage.UpdateProfileVPNSources(profile.ID, profile.VPNSources, nil); err != nil {
					t.Fatal(err)
				}
			case "profile":
				profile, err := a.storage.CreateProfile("Other")
				if err != nil {
					t.Fatal(err)
				}
				if err := a.storage.SetActiveProfileID(profile.ID); err != nil {
					t.Fatal(err)
				}
			case "session":
				a.reconnectGeneration.Add(1)
			case "stop":
				a.stopVPNSourceMonitor()
			case "offline":
				running = false
			}
			response := a.vpnSourceResponseSnapshot(tag, running, now)
			if response.State == "ok" || response.LatencyMS != nil {
				t.Fatalf("obsolete response: %+v", response)
			}
		})
	}
}
