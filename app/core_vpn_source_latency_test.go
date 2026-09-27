package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestVPNSourceLatencyRankingStableAndFailSafe(t *testing.T) {
	tags := []string{"slow", "unknown", "fast", "tie", "failed"}
	got := rankVPNSourceLatencies(tags, map[string]int{"slow": 90, "fast": 20, "tie": 20, "failed": -1})
	if !reflect.DeepEqual(got, []string{"fast", "tie", "slow", "unknown", "failed"}) {
		t.Fatalf("ranking = %v", got)
	}
	if tags[0] != "slow" {
		t.Fatal("ranking mutated saved source priority")
	}
}

func TestVPNSourceLatencyMigrationPreservesExistingPriority(t *testing.T) {
	legacy := ProfileData{VPNSources: []VPNSource{{ID: "first"}, {ID: "second"}}}
	normalizeProfileVPNSources(&legacy)
	if legacy.VPNSourceSelectionMode != "priority" {
		t.Fatal("legacy priority silently replaced")
	}
	legacy.VPNSourceSelectionMode = "latency"
	normalizeProfileVPNSources(&legacy)
	if legacy.VPNSourceSelectionMode != "latency" {
		t.Fatal("explicit auto preference lost")
	}
	fresh := ProfileData{}
	normalizeProfileVPNSources(&fresh)
	if fresh.VPNSourceSelectionMode != "latency" {
		t.Fatal("new profile must choose by latency")
	}
}

func TestVPNSourceLatencyProbeConcurrencyIsBounded(t *testing.T) {
	var inFlight, peak atomic.Int32
	entered := make(chan struct{}, 12)
	release := make(chan struct{})
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		n := inFlight.Add(1)
		defer inFlight.Add(-1)
		for {
			old := peak.Load()
			if n <= old || peak.CompareAndSwap(old, n) {
				break
			}
		}
		entered <- struct{}{}
		<-release
		fmt.Fprint(w, `{"delay":30}`)
	})
	var sources []VPNSource
	var outbounds []interface{}
	for i := 0; i < 9; i++ {
		id := fmt.Sprintf("source-%d", i)
		sources = append(sources, VPNSource{ID: id, SelectedNodeID: id})
		outbounds = append(outbounds, map[string]interface{}{"tag": "vpn-source-" + id, "type": "socks"})
	}
	if err := a.storage.UpdateProfileVPNSources(1, sources, nil, false); err != nil {
		t.Fatal(err)
	}
	if err := a.storage.UpdateProfileConfig(1, map[string]interface{}{"outbounds": outbounds}); err != nil {
		t.Fatal(err)
	}
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	done := make(chan struct{})
	go func() { a.selectInitialVPNSource(ctx, generation); close(done) }()
	for i := 0; i < vpnSourceProbeWorkers; i++ {
		<-entered
	}
	close(release)
	<-done
	if peak.Load() > vpnSourceProbeWorkers || peak.Load() < 2 {
		t.Fatalf("probe concurrency = %d", peak.Load())
	}
}

func TestVPNSourceLatencySelectionMeasuresOnlyIndependentSources(t *testing.T) {
	var mu sync.Mutex
	var probes, switches []string
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method == http.MethodPut {
			var body struct {
				Name string `json:"name"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			switches = append(switches, body.Name)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		probes = append(probes, r.URL.Path)
		if strings.Contains(r.URL.Path, "alpha") {
			fmt.Fprint(w, `{"delay":180}`)
		} else {
			fmt.Fprint(w, `{"delay":30}`)
		}
	})
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	a.selectInitialVPNSource(ctx, generation)
	if a.activeVPNSource() != "vpn-source-beta" {
		t.Fatalf("selected %s", a.activeVPNSource())
	}
	if got := a.sessionVPNSourceTags(); !reflect.DeepEqual(got, []string{"vpn-source-beta", "vpn-source-alpha"}) {
		t.Fatalf("fallback chain = %v", got)
	}
	if got := a.configuredVPNSourceTags(); got[0] != "vpn-source-alpha" {
		t.Fatal("automatic selection rewrote saved order")
	}
	// A healthy session is not switched back to the slower configured first
	// source, even after the usual preferred-source recovery cooldown.
	a.checkActiveVPNSource(ctx, generation)
	mu.Lock()
	defer mu.Unlock()
	if !reflect.DeepEqual(switches, []string{"vpn-source-beta"}) {
		t.Fatalf("unexpected switches %v", switches)
	}
	for _, path := range probes {
		if path != "/proxies/vpn-source-alpha/delay" && path != "/proxies/vpn-source-beta/delay" {
			t.Fatalf("probed a sibling or an unrelated selector: %s", path)
		}
	}
}

func TestVPNSourceLatencySelectionHonorsManualChoiceDuringProbe(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	var writes atomic.Int32
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			writes.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		once.Do(func() { close(entered) })
		<-release
		fmt.Fprint(w, `{"delay":20}`)
	})
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	done := make(chan struct{})
	go func() { a.selectInitialVPNSource(ctx, generation); close(done) }()
	<-entered
	if result := a.SelectVPNSource("alpha"); result["success"] != true {
		t.Fatalf("manual selection failed: %v", result)
	}
	close(release)
	<-done
	if writes.Load() != 1 || a.activeVPNSource() != "vpn-source-alpha" {
		t.Fatal("automatic comparison overrode manual selection")
	}
}

func TestVPNSourceLatencySelectionStopCancelsProbes(t *testing.T) {
	entered := make(chan struct{})
	var once sync.Once
	var writes atomic.Int32
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			writes.Add(1)
			return
		}
		once.Do(func() { close(entered) })
		<-r.Context().Done()
	})
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	done := make(chan struct{})
	go func() { a.selectInitialVPNSource(ctx, generation); close(done) }()
	<-entered
	a.stopVPNSourceMonitor()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("comparison did not cancel with its VPN session")
	}
	if writes.Load() != 0 || a.activeVPNSource() != "" {
		t.Fatal("stale comparison changed a stopped session")
	}
}

func TestVPNSourceLatencyManualPriorityPersistsAndSkipsComparison(t *testing.T) {
	var probes atomic.Int32
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		probes.Add(1)
		fmt.Fprint(w, `{"delay":180}`)
	})
	p, _ := a.storage.GetActiveProfile()
	if err := a.storage.UpdateProfileVPNSources(p.ID, p.VPNSources, nil, true); err != nil {
		t.Fatal(err)
	}
	if err := a.storage.Load(); err != nil {
		t.Fatal(err)
	}
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	a.selectInitialVPNSource(ctx, generation)
	if probes.Load() != 1 || a.activeVPNSource() != "vpn-source-alpha" || a.automaticVPNSourceSelection() {
		t.Fatal("manual priority was replaced by latency selection")
	}
	// A subscription refresh must retain the preference when no policy was supplied.
	if err := a.storage.UpdateProfileVPNSources(p.ID, p.VPNSources, nil); err != nil {
		t.Fatal(err)
	}
	if a.automaticVPNSourceSelection() {
		t.Fatal("refresh reset manual preference")
	}
	if err := a.storage.UpdateProfileVPNSources(p.ID, p.VPNSources, nil, false); err != nil {
		t.Fatal(err)
	}
	if !a.automaticVPNSourceSelection() {
		t.Fatal("automatic selection was not restored")
	}
}

func TestVPNSourceLatencyFailedAndCancelledChecksNeverWin(t *testing.T) {
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if strings.Contains(r.URL.Path, "alpha") {
			fmt.Fprint(w, `{"delay":0}`)
			return
		}
		fmt.Fprint(w, `{"delay":85}`)
	})
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	a.selectInitialVPNSource(ctx, generation)
	if a.activeVPNSource() != "vpn-source-beta" {
		t.Fatal("failed sample won latency selection")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	a.selectInitialVPNSource(cancelled, generation)
	if a.activeVPNSource() != "vpn-source-beta" {
		t.Fatal("cancelled comparison changed selection")
	}
}

func TestVPNSourceLatencyFailureUsesIndependentFallback(t *testing.T) {
	var betaFailed atomic.Bool
	a, ctx, generation := newVPNResponseTestApp(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if strings.Contains(r.URL.Path, "beta") {
			if betaFailed.Load() {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			fmt.Fprint(w, `{"delay":20}`)
		} else {
			fmt.Fprint(w, `{"delay":100}`)
		}
	})
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	a.selectInitialVPNSource(ctx, generation)
	betaFailed.Store(true)
	a.checkActiveVPNSource(ctx, generation)
	if a.activeVPNSource() != "vpn-source-beta" {
		t.Fatal("one transient failure replaced active source")
	}
	a.checkActiveVPNSource(ctx, generation)
	if a.activeVPNSource() != "vpn-source-alpha" {
		t.Fatal("failed source did not advance to independent fallback")
	}
}
