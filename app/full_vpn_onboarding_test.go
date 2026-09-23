package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

func TestFullVPNFreshDefaultDoesNotChangeSavedOrRecoveryModes(t *testing.T) {
	for _, test := range []struct {
		name    string
		mode    RoutingMode
		corrupt bool
		fresh   bool
	}{
		{name: "fresh", fresh: true},
		{name: "selected-services", mode: RoutingModeBlockedOnly},
		{name: "full-vpn", mode: RoutingModeAllTraffic},
		{name: "legacy-missing"},
		{name: "legacy-foreign", mode: RoutingModeExceptRussia},
		{name: "corrupt-recovery", corrupt: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			storage := NewStorage(t.TempDir())
			if !test.fresh {
				if err := os.MkdirAll(storage.resourcesPath, 0700); err != nil {
					t.Fatal(err)
				}
				data := []byte("invalid json")
				if !test.corrupt {
					settings := storage.createDefaultSettings()
					settings.Version = 1
					settings.App.RoutingMode = test.mode
					var err error
					data, err = json.Marshal(settings)
					if err != nil {
						t.Fatal(err)
					}
				}
				if err := os.WriteFile(storage.settingsPath, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := storage.Init(); err != nil {
				t.Fatal(err)
			}
			want := NormalizeRoutingMode(test.mode)
			if test.fresh && runtime.GOOS == "windows" {
				want = RoutingModeAllTraffic
			}
			if got := storage.GetAppSettings().RoutingMode; got != want {
				t.Fatalf("routing mode = %s, want %s", got, want)
			}
			profile, _ := storage.GetActiveProfile()
			if len(profile.VPNSources) != 0 || profile.SubscriptionURL != "" {
				t.Fatal("fresh/migrated mode implicitly consented to a public source")
			}
			if test.corrupt && !fileExists(storage.settingsPath+".backup") {
				t.Fatal("corrupt settings were not backed up")
			}
			if err := storage.Load(); err != nil {
				t.Fatal(err)
			}
			if storage.GetAppSettings().RoutingMode != want {
				t.Fatal("reload changed routing choice")
			}
		})
	}
}

func TestFullVPNLegacyImportRetainsSelectiveDefaultAndExistingEmptyProfileWins(t *testing.T) {
	t.Setenv("LOCALAPPDATA", t.TempDir())
	base := t.TempDir()
	storage := NewStorage(base)
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	legacy, err := json.Marshal(UserSettings{SubscriptionURL: testVPNSourceOld})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(base, "user_settings.json")
	if err := os.WriteFile(path, legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if err := storage.MigrateFromOldFormat(base); err != nil {
		t.Fatal(err)
	}
	if storage.GetAppSettings().RoutingMode != RoutingModeBlockedOnly {
		t.Fatal("legacy import opted into full VPN")
	}
	profile, _ := storage.GetActiveProfile()
	if profile.SubscriptionURL != testVPNSourceOld {
		t.Fatal("legacy source was not imported")
	}
	if err := storage.UpdateProfileVPNSources(profile.ID, nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if err := storage.Load(); err != nil {
		t.Fatal(err)
	}
	if err := storage.MigrateFromOldFormat(base); err != nil {
		t.Fatal(err)
	}
	profile, _ = storage.GetActiveProfile()
	if hasConfiguredVPNSource(profile) {
		t.Fatal("stale legacy file resurrected a deleted source")
	}
}

func requireUnreadyFullVPN(t *testing.T, app *App) {
	t.Helper()
	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatal(err)
	}
	if app.storage.GetAppSettings().RoutingMode != RoutingModeAllTraffic || hasConfiguredVPNSource(profile) {
		t.Fatal("expected saved full-VPN preference awaiting a source")
	}
	if len(profile.SingboxConfig) != 0 || len(profile.XrayConfig) != 0 || profile.XrayConfigReady {
		t.Fatal("unready profile retained a runnable config")
	}
	if _, err := app.storage.WriteActiveConfigToFile(); err == nil {
		t.Fatal("unready cached config could be exported for launch")
	}
	if err := app.ensureActiveConfigForStart(); err == nil {
		t.Fatal("Start preparation accepted full VPN without a source")
	}
	if err := app.configBuilder.BuildConfigForProfileSources(profile.ID, profile.VPNSources, profile.WireGuardConfigs); err == nil {
		t.Fatal("builder accepted direct fallback for full VPN without a source")
	}
}

func TestFullVPNUnreadyPreferenceInvalidatesCacheAndAllowsSettings(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	profile, _ := app.storage.GetActiveProfile()
	if err := app.storage.UpdateProfileXrayConfig(profile.ID, map[string]interface{}{"stale": true}); err != nil {
		t.Fatal(err)
	}
	result := app.SetRoutingMode(string(RoutingModeAllTraffic))
	if result["success"] != true || result["sourceRequired"] != true {
		t.Fatalf("mode result = %v", result)
	}
	requireUnreadyFullVPN(t, app)
	// A fresh user must still be able to edit service/settings choices while
	// awaiting a subscription, without attempting an impossible config build.
	requireAPISuccess(t, app.SetFreeAccessServiceMethod("youtube", FreeAccessMethodDirect))
	if err := app.storage.Load(); err != nil {
		t.Fatal(err)
	}
	requireUnreadyFullVPN(t, app)
	requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeBlockedOnly)))
	if !app.storage.ActiveProfileHasConfig() {
		t.Fatal("explicit switch back to services did not build a config")
	}
}

func TestFullVPNLastSourceRemovalAndDisablePersistUnreadyAcrossRestart(t *testing.T) {
	for _, remove := range []bool{false, true} {
		t.Run(map[bool]string{false: "disable", true: "remove"}[remove], func(t *testing.T) {
			storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
			app := &App{storage: storage, configBuilder: builder, initialized: true}
			app.initializedReady.Store(true)
			requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeAllTraffic)))
			if result := app.AddPublicVPNSource(publicVPNProviders()[0].ID, false); result["success"] != false {
				t.Fatal("missing consent accepted")
			}
			requireUnreadyFullVPN(t, app)
			requireAPISuccess(t, app.AddPublicVPNSource(publicVPNProviders()[0].ID, true))
			profile, _ := storage.GetActiveProfile()
			id := profile.VPNSources[0].ID
			var result map[string]interface{}
			if remove {
				result = app.RemoveVPNSource(id)
			} else {
				result = app.SetVPNSourceEnabled(id, false)
			}
			if result["success"] != true || result["sourceRequired"] != true {
				t.Fatalf("last-source result = %v", result)
			}
			requireUnreadyFullVPN(t, app)
			if err := storage.Load(); err != nil {
				t.Fatal(err)
			}
			requireUnreadyFullVPN(t, app)
			profile, _ = storage.GetActiveProfile()
			if remove && len(profile.VPNSources) != 0 {
				t.Fatal("removed public source returned")
			}
			if !remove && (len(profile.VPNSources) != 1 || !profile.VPNSources[0].Disabled) {
				t.Fatal("disabled public source returned enabled")
			}
		})
	}
}

func TestFullVPNEmptyProfileSwitchClearsOldConfig(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	profile, err := app.storage.CreateProfile("Empty")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.storage.UpdateProfileConfig(profile.ID, map[string]interface{}{"stale": true}); err != nil {
		t.Fatal(err)
	}
	requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeAllTraffic)))
	requireAPISuccess(t, app.SetActiveProfile(profile.ID))
	requireUnreadyFullVPN(t, app)
	if err := app.storage.Load(); err != nil {
		t.Fatal(err)
	}
	requireUnreadyFullVPN(t, app)
}

func TestFullVPNUnreadyWriteFailurePreservesModeAndProfile(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	before, _ := app.storage.GetActiveProfile()
	snapshot, err := cloneVPNSourceProfile(before)
	if err != nil {
		t.Fatal(err)
	}
	app.storage.settingsPath = t.TempDir() // a directory cannot be atomically replaced by settings.json
	result := app.SetRoutingMode(string(RoutingModeAllTraffic))
	if result["success"] != false {
		t.Fatalf("failed write reported success: %v", result)
	}
	after, _ := app.storage.GetActiveProfile()
	afterSnapshot, err := cloneVPNSourceProfile(after)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(snapshot, afterSnapshot) || app.storage.GetAppSettings().RoutingMode != RoutingModeBlockedOnly || app.configBuilder.GetRoutingMode() != RoutingModeBlockedOnly {
		t.Fatal("failed unready write mutated the previous mode/profile")
	}
}

func TestFullVPNActiveLastSourceRemovalRollsBackAndRecovers(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	requireAPISuccess(t, app.AddVPNSource("Own", testVPNSourceOld))
	requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeAllTraffic)))
	before, _ := app.storage.GetActiveProfile()
	snapshot, err := cloneVPNSourceProfile(before)
	if err != nil {
		t.Fatal(err)
	}
	setVPNSourceTestRunning(app, true)
	starts := 0
	result := app.changeVPNSourcesTransaction(func(candidate *ProfileData) error {
		candidate.VPNSources = nil
		return nil
	}, vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			setVPNSourceTestRunning(app, false)
			return map[string]interface{}{"success": true}
		},
		start: func() map[string]interface{} {
			starts++
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true}
		},
	})
	if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != true || starts != 1 {
		t.Fatalf("active empty-chain transaction = %v, recovery starts = %d", result, starts)
	}
	after, _ := app.storage.GetActiveProfile()
	if !reflect.DeepEqual(snapshot, *after) {
		t.Fatal("active full VPN lost its previous source/config")
	}
}

func TestFullVPNUnreadyDoesNotAcceptInvalidSourceOrUnavailableFeed(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	requireAPISuccess(t, app.SetRoutingMode(string(RoutingModeAllTraffic)))
	for _, uri := range []string{"vless://missing-host", "https://example.com/unavailable"} {
		app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(*http.Request) (*http.Response, error) {
			return nil, fmt.Errorf("offline fixture")
		})}
		if result := app.AddVPNSource("Invalid", uri); result["success"] != false {
			t.Fatalf("unusable new source accepted: %v", result)
		}
		requireUnreadyFullVPN(t, app)
		profile, _ := app.storage.GetActiveProfile()
		if len(profile.VPNSources) != 0 {
			t.Fatal("failed source addition remained saved")
		}
	}
}
