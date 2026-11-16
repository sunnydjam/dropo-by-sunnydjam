package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestVPNSourcePreparationKeepsSessionAndStorageUntilCommit(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	app.desiredConnected.Store(true)
	old, _ := app.storage.GetActiveProfile()
	before, _ := cloneVPNSourceProfile(old)
	entered, release := make(chan struct{}), make(chan struct{})
	var fetches, stops atomic.Int32
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		fetches.Add(1)
		if !app.isVPNRunning() {
			t.Error("source fetched after VPN had been stopped")
		}
		current, _ := app.storage.GetActiveProfile()
		if !sameVPNSourceProfile(current, before) {
			t.Error("preparation wrote a partial profile")
		}
		if !app.vpnLifecycleMu.TryLock() {
			t.Error("network preparation holds lifecycle lock")
		} else {
			app.vpnLifecycleMu.Unlock()
		}
		close(entered)
		select {
		case <-release:
		case <-r.Context().Done():
			return nil, r.Context().Err()
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(testVPNSourceNew)), Header: make(http.Header)}, nil
	})}
	done := make(chan map[string]interface{}, 1)
	go func() {
		done <- app.changeVPNSourcesTransaction(func(p *ProfileData) error {
			p.VPNSources = []VPNSource{{ID: "new", URI: "https://slow.example.test/sub"}}
			return nil
		}, vpnSourceReconnectOps{
			stop: func() map[string]interface{} {
				stops.Add(1)
				setVPNSourceTestRunning(app, false)
				return map[string]interface{}{"success": true}
			},
			start: func() map[string]interface{} {
				setVPNSourceTestRunning(app, true)
				return map[string]interface{}{"success": true}
			},
		})
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("preparation not started")
	}
	if stops.Load() != 0 {
		t.Fatal("stopped during preparation")
	}
	close(release)
	select {
	case result := <-done:
		if result["success"] != true {
			t.Fatalf("result: %+v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("commit not completed")
	}
	if stops.Load() != 1 || fetches.Load() != 1 {
		t.Fatalf("stops=%d fetches=%d", stops.Load(), fetches.Load())
	}
}

func TestVPNSourcePreparationStopCancelsHTTPWithoutRestart(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	// No native handles/processes: public Stop only exercises intent/locks and fixtures.
	app.desiredConnected.Store(true)
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	entered := make(chan struct{})
	var restarts atomic.Int32
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		close(entered)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	done := make(chan map[string]interface{}, 1)
	go func() {
		done <- app.changeVPNSourcesTransaction(func(p *ProfileData) error {
			p.VPNSources = []VPNSource{{ID: "slow", URI: "https://slow.example.test/list", CachedNodes: []string{testVPNSourceNew}}}
			return nil
		}, vpnSourceReconnectOps{
			stop: func() map[string]interface{} {
				t.Error("cancelled preparation reached stop")
				return map[string]interface{}{"success": true}
			},
			start: func() map[string]interface{} { restarts.Add(1); return map[string]interface{}{"success": true} },
		})
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("fetch not started")
	}
	stopDone := make(chan struct{})
	go func() { app.Stop(); close(stopDone) }()
	select {
	case <-stopDone:
	case <-time.After(time.Second):
		t.Fatal("Stop blocked on subscription fetch")
	}
	select {
	case result := <-done:
		if result["success"] != false || result["cancelled"] != true {
			t.Fatalf("cancel result %+v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("HTTP cancellation did not complete")
	}
	after, _ := app.storage.GetActiveProfile()
	if !sameVPNSourceProfile(after, snapshot) || restarts.Load() != 0 {
		t.Fatal("cancelled work changed profile/restarted VPN")
	}
}

func TestVPNSourcePreparationDeadlineRejectsCachedPartialCandidate(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	app.ctx = ctx
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	var fetches atomic.Int32
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		fetches.Add(1)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	result := app.changeVPNSourcesTransaction(func(p *ProfileData) error {
		p.VPNSources = []VPNSource{{ID: "slow", URI: "https://slow.example.test/list", CachedNodes: []string{testVPNSourceNew}}, {ID: "next", URI: "https://next.example.test/list"}}
		return nil
	}, vpnSourceReconnectOps{stop: func() map[string]interface{} { t.Error("deadline stopped working VPN"); return nil }})
	after, _ := app.storage.GetActiveProfile()
	if result["cancelled"] != true || fetches.Load() != 1 || !app.isVPNRunning() || !sameVPNSourceProfile(after, snapshot) {
		t.Fatalf("deadline applied partial config: %+v", result)
	}
}

func TestPreparedVPNSourceCommitIsAtomicOnDiskFailure(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	source, _ := newVPNSource("new", "New", testVPNSourceNew)
	prepared, err := app.configBuilder.prepareConfigForProfileSources(context.Background(), before.ID, []VPNSource{source}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	app.storage.settingsPath = t.TempDir() // Cannot replace an existing directory with the settings file.
	if err := app.storage.commitPreparedVPNSourceConfig(before.ID, prepared); err == nil {
		t.Fatal("expected atomic write failure")
	}
	after, _ := app.storage.GetActiveProfile()
	if !sameVPNSourceProfile(after, snapshot) {
		t.Fatal("failed write left a partial config in memory")
	}
	if _, err := os.Stat(app.storage.settingsPath); errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed write removed original destination")
	}
}

func sameVPNSourceProfile(profile *ProfileData, snapshot ProfileData) bool {
	cloned, err := cloneVPNSourceProfile(profile)
	return err == nil && reflect.DeepEqual(cloned, snapshot)
}

func TestVPNSourcePreparationRejectsNewerIntentBeforeCommit(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	entered, release := make(chan struct{}), make(chan struct{})
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		close(entered)
		<-release
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(testVPNSourceNew)), Header: make(http.Header)}, nil
	})}
	done := make(chan map[string]interface{}, 1)
	go func() {
		done <- app.changeVPNSourcesTransaction(func(p *ProfileData) error {
			p.VPNSources = []VPNSource{{ID: "new", URI: "https://slow.example.test/sub"}}
			return nil
		}, vpnSourceReconnectOps{
			stop:  func() map[string]interface{} { t.Error("stale preparation interrupted a newer intent"); return nil },
			start: func() map[string]interface{} { t.Error("stale preparation started VPN"); return nil },
		})
	}()
	<-entered
	// The generation fence also protects against a late successful transport.
	app.vpnIntentGeneration.Add(1)
	close(release)
	select {
	case result := <-done:
		if result["cancelled"] != true {
			t.Fatalf("stale request committed: %+v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("stale transaction did not finish")
	}
	after, _ := app.storage.GetActiveProfile()
	if !sameVPNSourceProfile(after, snapshot) || !app.isVPNRunning() {
		t.Fatal("stale candidate changed active configuration")
	}
}

func TestLegacySubscriptionEntryPointUsesPreparedSources(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		current, _ := app.storage.GetActiveProfile()
		if !sameVPNSourceProfile(current, snapshot) {
			t.Error("legacy endpoint wrote profile before download finished")
		}
		if !app.vpnLifecycleMu.TryLock() {
			t.Error("legacy endpoint keeps lifecycle locked during HTTP")
		} else {
			app.vpnLifecycleMu.Unlock()
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(testVPNSourceNew)), Header: make(http.Header)}, nil
	})}
	result := app.SetVPNSubscription("https://subscription.example.test/list")
	if result["success"] != true || result["proxyCount"] != 1 {
		t.Fatalf("legacy response contract changed: %+v", result)
	}
}

func TestVPNSourceReconnectRequiresActualRunningState(t *testing.T) {
	for _, recoveryRuns := range []bool{true, false} {
		name := "recovery-also-stopped"
		if recoveryRuns {
			name = "recovery-starts"
		}
		t.Run(name, func(t *testing.T) {
			app := newInitializedSettingsScenarioApp(t)
			setVPNSourceTestRunning(app, true)
			before, _ := app.storage.GetActiveProfile()
			snapshot, _ := cloneVPNSourceProfile(before)
			starts := 0
			result := app.changeVPNSourcesTransaction(func(p *ProfileData) error {
				p.VPNSources = []VPNSource{{ID: "new", URI: testVPNSourceNew}}
				return nil
			}, vpnSourceReconnectOps{
				stop: func() map[string]interface{} {
					setVPNSourceTestRunning(app, false)
					return map[string]interface{}{"success": true}
				},
				start: func() map[string]interface{} {
					starts++
					// A successful response without a running session must not commit
					// the candidate or claim recovery. Both phases need this check.
					setVPNSourceTestRunning(app, starts == 2 && recoveryRuns)
					return map[string]interface{}{"success": true}
				},
			})
			if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != recoveryRuns || starts != 2 {
				t.Fatalf("spurious restart success accepted: %+v, starts=%d", result, starts)
			}
			after, _ := app.storage.GetActiveProfile()
			if !sameVPNSourceProfile(after, snapshot) {
				t.Fatal("failed candidate was not rolled back")
			}
		})
	}
}

func TestPreparedSourceRestartDoesNotRefreshSubscriptionAgain(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	settings := app.storage.GetAppSettings()
	settings.AutoUpdateSub = true
	settings.LastSubUpdate = time.Time{}
	if err := app.storage.UpdateAppSettings(settings); err != nil {
		t.Fatal(err)
	}
	// The runtime file belongs to the previous direct-only session, while the
	// newly prepared profile contains the first VPN source.
	if err := os.WriteFile(app.storage.ActiveConfigFilePath(), []byte(`{"outbounds":[{"type":"direct","tag":"direct"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	setVPNSourceTestRunning(app, true)
	fetches := 0
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(r *http.Request) (*http.Response, error) {
		fetches++
		if !app.isVPNRunning() {
			t.Error("restart downloaded the subscription after disconnecting")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(testVPNSourceNew)), Header: make(http.Header)}, nil
	})}
	result := app.changeVPNSourcesTransaction(func(p *ProfileData) error {
		p.VPNSources = []VPNSource{{ID: "new", URI: "https://subscription.example.test/list"}}
		return nil
	}, vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true}
		},
		start: func() map[string]interface{} {
			if err := app.autoUpdateSubscriptionBeforeStart(""); err != nil {
				t.Fatal(err)
			}
			if err := app.ensureActiveConfigForStart(); err != nil {
				t.Fatal(err)
			}
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true}
		},
	})
	if result["success"] != true || fetches != 1 {
		t.Fatalf("prepared restart should fetch once before stop: %+v, fetches=%d", result, fetches)
	}
}
