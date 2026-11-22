package main

import (
	"errors"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testVPNSourceOld = "vless://11111111-1111-1111-1111-111111111111@old.example.test:443?security=tls&type=tcp#Old"
	testVPNSourceNew = "vless://22222222-2222-2222-2222-222222222222@new.example.test:443?security=tls&type=tcp#New"
)

func TestVPNSourceChangeWaitsForSynchronousReconnect(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)

	startEntered := make(chan struct{})
	releaseStart := make(chan struct{})
	done := make(chan map[string]interface{}, 1)
	var stopCalls atomic.Int32
	var startCalls atomic.Int32
	ops := vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			stopCalls.Add(1)
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true, "running": false, "generation": 7}
		},
		start: func() map[string]interface{} {
			startCalls.Add(1)
			close(startEntered)
			<-releaseStart
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true, "running": true, "generation": 7}
		},
	}

	go func() {
		done <- app.changeVPNSourcesTransaction(func(profile *ProfileData) error {
			source, err := newVPNSource("source-new", "New", testVPNSourceNew)
			if err != nil {
				return err
			}
			profile.VPNSources = append(profile.VPNSources, source)
			return nil
		}, ops)
	}()

	select {
	case <-startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("source transaction never reached synchronous restart")
	}
	select {
	case result := <-done:
		t.Fatalf("source transaction returned before restart completed: %+v", result)
	case <-time.After(50 * time.Millisecond):
	}
	close(releaseStart)

	var result map[string]interface{}
	select {
	case result = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("source transaction did not return after restart completed")
	}
	if result["success"] != true || result["restarted"] != true || result["connectionRestored"] != true {
		t.Fatalf("source transaction result = %+v", result)
	}
	if result["generation"] != 7 || stopCalls.Load() != 1 || startCalls.Load() != 1 {
		t.Fatalf("transition metadata/calls = result:%+v stop:%d start:%d", result, stopCalls.Load(), startCalls.Load())
	}
	profile, err := app.storage.GetActiveProfile()
	if err != nil || len(profile.VPNSources) != 1 || profile.VPNSources[0].URI != testVPNSourceNew {
		t.Fatalf("stored source = %+v, err=%v", profile, err)
	}
}

func TestVPNSourceChangeRollsBackAndRecoversAfterRestartFailure(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	oldSource, err := newVPNSource("source-old", "Old", testVPNSourceOld)
	if err != nil {
		t.Fatal(err)
	}
	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	if err := app.configBuilder.BuildConfigForProfileSources(profile.ID, []VPNSource{oldSource}, profile.WireGuardConfigs); err != nil {
		t.Fatalf("prepare old source: %v", err)
	}
	before, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	beforeSnapshot, err := cloneVPNSourceProfile(before)
	if err != nil {
		t.Fatal(err)
	}
	setVPNSourceTestRunning(app, true)

	startCalls := 0
	ops := vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true, "running": false}
		},
		start: func() map[string]interface{} {
			startCalls++
			if startCalls == 1 {
				return map[string]interface{}{"success": false, "error": "new configuration refused"}
			}
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true, "running": true}
		},
	}
	result := app.changeVPNSourcesTransaction(func(candidate *ProfileData) error {
		newSource, sourceErr := newVPNSource("source-new", "New", testVPNSourceNew)
		if sourceErr != nil {
			return sourceErr
		}
		candidate.VPNSources = []VPNSource{newSource}
		return nil
	}, ops)

	if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != true {
		t.Fatalf("failed reconnect result = %+v", result)
	}
	if startCalls != 2 {
		t.Fatalf("start calls = %d, want failed new start plus old-config recovery", startCalls)
	}
	if !strings.Contains(result["error"].(string), "прежнее VPN-подключение восстановлено") {
		t.Fatalf("recovery is not reported: %+v", result)
	}
	after, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	afterSnapshot, err := cloneVPNSourceProfile(after)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(afterSnapshot, beforeSnapshot) {
		t.Fatalf("profile was not fully rolled back\nafter:  %+v\nbefore: %+v", afterSnapshot, beforeSnapshot)
	}
}

func TestVPNSourceChangeKeepsSavedChangeWhenUserCancelsRestart(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	ops := vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true, "running": false}
		},
		start: func() map[string]interface{} {
			return map[string]interface{}{"success": false, "cancelled": true, "error": "Переподключение отменено"}
		},
	}
	result := app.changeVPNSourcesTransaction(func(profile *ProfileData) error {
		source, err := newVPNSource("source-new", "New", testVPNSourceNew)
		if err != nil {
			return err
		}
		profile.VPNSources = []VPNSource{source}
		return nil
	}, ops)

	if result["success"] != true || result["restartCancelled"] != true || result["connectionRestored"] != true {
		t.Fatalf("cancelled reconnect result = %+v", result)
	}
	if result["restarted"] != false || result["rolledBack"] != false {
		t.Fatalf("cancelled reconnect must save without restart/rollback: %+v", result)
	}
	profile, err := app.storage.GetActiveProfile()
	if err != nil || len(profile.VPNSources) != 1 || profile.VPNSources[0].URI != testVPNSourceNew {
		t.Fatalf("cancelled restart lost saved source: profile=%+v err=%v", profile, err)
	}
}

func TestVPNSourceChangeDoesNotMutateProfileWhenStopFails(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	before, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	beforeSnapshot, err := cloneVPNSourceProfile(before)
	if err != nil {
		t.Fatal(err)
	}
	setVPNSourceTestRunning(app, true)
	startCalls := 0
	result := app.changeVPNSourcesTransaction(func(profile *ProfileData) error {
		source, sourceErr := newVPNSource("source-new", "New", testVPNSourceNew)
		if sourceErr != nil {
			return sourceErr
		}
		profile.VPNSources = []VPNSource{source}
		return nil
	}, vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			return map[string]interface{}{"success": false, "error": "stop refused"}
		},
		start: func() map[string]interface{} {
			startCalls++
			return map[string]interface{}{"success": true}
		},
	})

	if result["success"] != false || result["connectionRestored"] != true || startCalls != 0 {
		t.Fatalf("stop failure result = %+v, startCalls=%d", result, startCalls)
	}
	after, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	afterSnapshot, err := cloneVPNSourceProfile(after)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(afterSnapshot, beforeSnapshot) {
		t.Fatalf("stop failure mutated profile\nafter:  %+v\nbefore: %+v", afterSnapshot, beforeSnapshot)
	}
}

func TestVPNSourceChangeRecoversWhenFailedStopLeftVPNDown(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	startCalls := 0
	result := app.changeVPNSourcesTransaction(func(profile *ProfileData) error {
		source, err := newVPNSource("source-new", "New", testVPNSourceNew)
		if err != nil {
			return err
		}
		profile.VPNSources = []VPNSource{source}
		return nil
	}, vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": false, "error": "partial stop"}
		},
		start: func() map[string]interface{} {
			startCalls++
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true, "running": true}
		},
	})

	if result["success"] != false || result["connectionRestored"] != true || startCalls != 1 {
		t.Fatalf("partial stop recovery result = %+v, startCalls=%d", result, startCalls)
	}
	if !strings.Contains(result["error"].(string), "прежнее VPN-подключение восстановлено") {
		t.Fatalf("partial stop recovery is not reported: %+v", result)
	}
	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.VPNSources) != 0 {
		t.Fatalf("failed stop applied source mutation: %+v", profile.VPNSources)
	}
}

func TestVPNSourceChangeRejectsMutationDuringConnectionTransition(t *testing.T) {
	for _, state := range []string{"starting", "stopping", "reconnecting"} {
		t.Run(state, func(t *testing.T) {
			app := newInitializedSettingsScenarioApp(t)
			switch state {
			case "starting":
				app.mu.Lock()
				app.isStarting = true
				app.mu.Unlock()
			case "stopping":
				app.vpnStopping.Store(true)
			case "reconnecting":
				app.reconnecting.Store(true)
			}
			changeCalls := 0
			result := app.changeVPNSourcesTransaction(func(*ProfileData) error {
				changeCalls++
				return nil
			}, vpnSourceReconnectOps{})
			if result["success"] != false || changeCalls != 0 {
				t.Fatalf("transition result = %+v, changeCalls=%d", result, changeCalls)
			}
			if !strings.Contains(result["error"].(string), "Дождитесь завершения") {
				t.Fatalf("transition error = %+v", result)
			}
		})
	}
}

func TestVPNSourceChangeDoesNotRestartAfterRollbackFailure(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	setVPNSourceTestRunning(app, true)
	startCalls := 0
	result := app.changeVPNSourcesTransaction(func(profile *ProfileData) error {
		source, err := newVPNSource("source-new", "New", testVPNSourceNew)
		if err != nil {
			return err
		}
		profile.VPNSources = []VPNSource{source}
		return nil
	}, vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true}
		},
		start: func() map[string]interface{} {
			startCalls++
			return map[string]interface{}{"success": false, "error": "new start failed"}
		},
		restore: func(ProfileData) error {
			return errors.New("rollback storage unavailable")
		},
	})

	if result["success"] != false || result["rolledBack"] != false || result["connectionRestored"] != false {
		t.Fatalf("rollback failure result = %#v", result)
	}
	if startCalls != 1 {
		t.Fatalf("start calls = %d, want only the failed candidate start", startCalls)
	}
	errorText := result["error"].(string)
	if !strings.Contains(errorText, "rollback storage unavailable") || !strings.Contains(errorText, "VPN оставлен отключённым") {
		t.Fatalf("rollback failure was not reported safely: %s", errorText)
	}
}

func setVPNSourceTestRunning(app *App, running bool) {
	app.mu.Lock()
	app.isRunning = running
	app.mu.Unlock()
}
