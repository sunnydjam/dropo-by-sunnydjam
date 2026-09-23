package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestReduceMotionDefaultsOffAndPersistsAcrossReload(t *testing.T) {
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	if storage.GetAppSettings().ReduceMotion {
		t.Fatal("fresh settings unexpectedly reduce motion")
	}
	settings := storage.GetAppSettings()
	settings.ReduceMotion = true
	if err := storage.UpdateAppSettings(settings); err != nil {
		t.Fatal(err)
	}
	if err := storage.Load(); err != nil {
		t.Fatal(err)
	}
	if !storage.GetAppSettings().ReduceMotion {
		t.Fatal("saved reduced motion was lost on reload")
	}

	// Older settings contain no field: missing must migrate to false, not to an
	// inferred preference based on VPN mode, hardware, or a previous process.
	data, err := os.ReadFile(storage.settingsPath)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]interface{}
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatal(err)
	}
	delete(saved["app"].(map[string]interface{}), "reduce_motion")
	data, err = json.Marshal(saved)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(storage.settingsPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := storage.Load(); err != nil {
		t.Fatal(err)
	}
	if storage.GetAppSettings().ReduceMotion {
		t.Fatal("legacy settings without preference did not default off")
	}
}

func TestReduceMotionChangesWhileRunningWithoutTouchingNetwork(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	beforeProfile, _ := app.storage.GetActiveProfile()
	beforeJSON, err := json.Marshal(beforeProfile)
	if err != nil {
		t.Fatal(err)
	}
	beforeSettings := app.storage.GetAppSettings()
	app.mu.Lock()
	app.isRunning = true
	app.mu.Unlock()
	app.desiredConnected.Store(true)
	app.reconnectGeneration.Store(17)
	// No builder exists: a presentation preference must not require a config
	// rebuild or otherwise dereference/start the network stack.
	app.configBuilder = nil
	for _, reduced := range []bool{true, false, true} {
		result := app.SetReduceMotion(reduced)
		if result["success"] != true || result["reduceMotion"] != reduced {
			t.Fatalf("presentation update = %v", result)
		}
		afterSettings := app.storage.GetAppSettings()
		if afterSettings.ReduceMotion != reduced {
			t.Fatal("API did not save preference")
		}
		afterSettings.ReduceMotion = beforeSettings.ReduceMotion
		if !reflect.DeepEqual(beforeSettings, afterSettings) {
			t.Fatal("presentation API changed other settings")
		}
		afterProfile, _ := app.storage.GetActiveProfile()
		afterJSON, err := json.Marshal(afterProfile)
		if err != nil {
			t.Fatal(err)
		}
		if string(beforeJSON) != string(afterJSON) {
			t.Fatal("presentation API mutated profile/config/source data")
		}
		if !app.isVPNRunning() || !app.desiredConnected.Load() || app.reconnecting.Load() || app.reconnectGeneration.Load() != 17 {
			t.Fatal("presentation API changed VPN lifecycle")
		}
		if config := app.GetAppConfig(); config["reduceMotion"] != reduced {
			t.Fatal("GetAppConfig did not expose saved preference")
		}
	}
}

func TestSaveAppConfigPreservesReduceMotion(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	stubApplyAutoStart(t)
	requireAPISuccess(t, app.SetReduceMotion(true))
	settings := app.storage.GetAppSettings()
	requireAPISuccess(t, app.SaveAppConfig(settings.AutoStart, settings.EnableLogging, false, settings.Notifications, settings.AutoUpdateSub, "dark", "ru", string(settings.LogLevel), settings.SubUpdateInterval))
	if !app.storage.GetAppSettings().ReduceMotion {
		t.Fatal("SaveAppConfig reset reduced motion")
	}
	if err := app.storage.Load(); err != nil {
		t.Fatal(err)
	}
	if !app.storage.GetAppSettings().ReduceMotion || app.storage.GetAppSettings().Theme != ThemeDark {
		t.Fatal("reloaded presentation choices changed")
	}
}

func TestReduceMotionBridgeRequiresAuthentication(t *testing.T) {
	if _, ok := bridgeCallableMethods["SetReduceMotion"]; !ok {
		t.Fatal("presentation API missing from allowlist")
	}
	request := httptest.NewRequest(http.MethodPost, "http://127.0.0.1/api/call", strings.NewReader(`{"method":"SetReduceMotion","args":[true]}`))
	recorder := httptest.NewRecorder()
	newBridgeMux(&App{}, "test-token").ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated presentation mutation = %d", recorder.Code)
	}
}

func TestReduceMotionSaveFailurePreservesPreviousPreference(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	app.storage.settingsPath = t.TempDir()
	if result := app.SetReduceMotion(true); result["success"] != false {
		t.Fatalf("failed write reported success: %v", result)
	}
	if app.storage.GetAppSettings().ReduceMotion {
		t.Fatal("failed write changed in-memory preference")
	}
}

func TestPresentationSettingsSerializeWithOtherPolicyChanges(t *testing.T) {
	for _, operation := range []string{"reduce-motion", "save-app-config"} {
		t.Run(operation, func(t *testing.T) {
			app := newInitializedSettingsScenarioApp(t)
			stubApplyAutoStart(t)
			app.settingsPolicyMu.Lock()
			locked := true
			defer func() {
				if locked {
					app.settingsPolicyMu.Unlock()
				}
			}()
			done := make(chan map[string]interface{}, 1)
			go func() {
				if operation == "reduce-motion" {
					done <- app.SetReduceMotion(true)
				} else {
					done <- app.SaveAppConfig(true, true, true, true, true, "dark", "ru", "info", 24)
				}
			}()
			select {
			case result := <-done:
				t.Fatalf("presentation transaction ignored policy lock: %v", result)
			case <-time.After(30 * time.Millisecond):
			}
			// Simulate the concurrent policy holder committing before the blocked
			// presentation operation reads its settings snapshot.
			settings := app.storage.GetAppSettings()
			settings.RoutingMode = RoutingModeAllTraffic
			settings.ReduceMotion = true
			if err := app.storage.UpdateAppSettings(settings); err != nil {
				t.Fatal(err)
			}
			app.settingsPolicyMu.Unlock()
			locked = false
			select {
			case result := <-done:
				requireAPISuccess(t, result)
			case <-time.After(time.Second):
				t.Fatal("presentation transaction remained blocked")
			}
			settings = app.storage.GetAppSettings()
			if settings.RoutingMode != RoutingModeAllTraffic || !settings.ReduceMotion {
				t.Fatal("presentation transaction overwrote a newer routing/presentation choice")
			}
		})
	}
}
