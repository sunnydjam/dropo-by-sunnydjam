package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

const (
	subscriptionTestOldURL = "vless://old@old.example.com:443?security=tls#Old"
	subscriptionTestNewURL = "vless://new@new.example.com:443?security=tls#New"
)

func newSubscriptionTransactionTestApp(t *testing.T) (*App, *Storage) {
	t.Helper()
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	if err := writeSubscriptionTransactionTestProfile(storage, subscriptionTestOldURL, 2, "old"); err != nil {
		t.Fatal(err)
	}
	settings := storage.GetAppSettings()
	settings.RestoreVPNOnStartup = true
	if err := storage.UpdateAppSettings(settings); err != nil {
		t.Fatal(err)
	}

	app := &App{
		storage:       storage,
		configBuilder: NewConfigBuilderForStorage(storage),
		initialized:   true,
		isRunning:     true,
	}
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)
	return app, storage
}

func writeSubscriptionTransactionTestProfile(storage *Storage, rawURL string, count int, marker string) error {
	profileID := storage.GetActiveProfileID()
	var sources []VPNSource
	if strings.TrimSpace(rawURL) != "" {
		source, err := newVPNSource("source-1", "Primary", rawURL)
		if err != nil {
			return err
		}
		source.NodeCount = count
		source.LastUpdated = marker
		source.CachedNodes = []string{rawURL}
		sources = []VPNSource{source}
	}
	if err := storage.UpdateProfileVPNSources(profileID, sources, nil); err != nil {
		return err
	}
	return storage.UpdateProfileConfig(profileID, map[string]interface{}{"marker": marker})
}

func subscriptionTestStop(app *App, events *[]string) func() map[string]interface{} {
	return func() map[string]interface{} {
		*events = append(*events, "stop")
		app.mu.Lock()
		app.isRunning = false
		app.mu.Unlock()
		return map[string]interface{}{"success": true, "generation": uint64(7)}
	}
}

func subscriptionTestStart(app *App, events *[]string) func() map[string]interface{} {
	return func() map[string]interface{} {
		*events = append(*events, "start")
		app.mu.Lock()
		app.isRunning = true
		app.mu.Unlock()
		return map[string]interface{}{"success": true, "protectionHeld": true}
	}
}

func TestSubscriptionMutationWaitsForReconnectAndPreservesIntent(t *testing.T) {
	app, storage := newSubscriptionTransactionTestApp(t)
	events := make([]string, 0, 3)
	startEntered := make(chan struct{})
	allowStart := make(chan struct{})
	resultReady := make(chan map[string]interface{}, 1)

	ops := subscriptionReconnectOps{
		stop: subscriptionTestStop(app, &events),
		build: func(rawURL string) error {
			events = append(events, "build")
			return writeSubscriptionTransactionTestProfile(storage, rawURL, 3, "new")
		},
		start: func() map[string]interface{} {
			events = append(events, "start")
			close(startEntered)
			<-allowStart
			app.mu.Lock()
			app.isRunning = true
			app.mu.Unlock()
			return map[string]interface{}{"success": true, "reconnectProtected": true}
		},
	}

	go func() {
		resultReady <- app.changeVPNSubscriptionTransaction(
			stringPointer(subscriptionTestNewURL),
			false,
			"test",
			ops,
		)
	}()

	select {
	case <-startEntered:
	case <-time.After(time.Second):
		t.Fatal("subscription transaction did not reach reconnect")
	}
	select {
	case result := <-resultReady:
		t.Fatalf("subscription mutation returned before reconnect completed: %#v", result)
	default:
	}
	close(allowStart)

	var result map[string]interface{}
	select {
	case result = <-resultReady:
	case <-time.After(time.Second):
		t.Fatal("subscription transaction did not finish after reconnect")
	}
	if result["success"] != true || result["restarted"] != true || result["connectionRestored"] != true {
		t.Fatalf("transaction result = %#v", result)
	}
	if result["reconnectProtected"] != true || result["generation"] != uint64(7) {
		t.Fatalf("reconnect metadata was not preserved: %#v", result)
	}
	if !reflect.DeepEqual(events, []string{"stop", "build", "start"}) {
		t.Fatalf("operation order = %v", events)
	}
	profile, _ := storage.GetActiveProfile()
	if profile.SubscriptionURL != subscriptionTestNewURL || profile.ProxyCount != 3 {
		t.Fatalf("updated profile = %#v", profile)
	}
	if !app.desiredConnected.Load() || !storage.GetAppSettings().RestoreVPNOnStartup {
		t.Fatal("internal reconnect changed user or startup restore intent")
	}
}

func TestSubscriptionMutationBuildFailureRollsBackAndRecovers(t *testing.T) {
	app, storage := newSubscriptionTransactionTestApp(t)
	beforeProfile, _ := storage.GetActiveProfile()
	before, _ := cloneVPNSourceProfile(beforeProfile)
	events := make([]string, 0, 3)

	result := app.changeVPNSubscriptionTransaction(
		stringPointer(subscriptionTestNewURL),
		false,
		"test",
		subscriptionReconnectOps{
			stop: subscriptionTestStop(app, &events),
			build: func(rawURL string) error {
				events = append(events, "build")
				if err := writeSubscriptionTransactionTestProfile(storage, rawURL, 9, "partial"); err != nil {
					return err
				}
				return errors.New("synthetic build failure")
			},
			start: subscriptionTestStart(app, &events),
		},
	)

	if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != true {
		t.Fatalf("transaction result = %#v", result)
	}
	if !strings.Contains(result["error"].(string), "synthetic build failure") {
		t.Fatalf("build error was lost: %#v", result)
	}
	if !reflect.DeepEqual(events, []string{"stop", "build", "start"}) {
		t.Fatalf("operation order = %v", events)
	}
	after, _ := storage.GetActiveProfile()
	if !reflect.DeepEqual(after, &before) {
		t.Fatalf("profile was not rolled back\nafter:  %#v\nbefore: %#v", after, before)
	}
	if !app.isVPNRunning() || !app.desiredConnected.Load() || !storage.GetAppSettings().RestoreVPNOnStartup {
		t.Fatal("old connection intent was not recovered after build failure")
	}
}

func TestSubscriptionMutationStartFailureRollsBackBeforeRecovery(t *testing.T) {
	app, storage := newSubscriptionTransactionTestApp(t)
	beforeProfile, _ := storage.GetActiveProfile()
	before, _ := cloneVPNSourceProfile(beforeProfile)
	events := make([]string, 0, 4)
	startCalls := 0

	result := app.changeVPNSubscriptionTransaction(
		stringPointer(subscriptionTestNewURL),
		false,
		"test",
		subscriptionReconnectOps{
			stop: subscriptionTestStop(app, &events),
			build: func(rawURL string) error {
				events = append(events, "build")
				return writeSubscriptionTransactionTestProfile(storage, rawURL, 4, "new")
			},
			start: func() map[string]interface{} {
				startCalls++
				if startCalls == 1 {
					events = append(events, "start-new")
					profile, _ := storage.GetActiveProfile()
					if profile.SubscriptionURL != subscriptionTestNewURL {
						t.Errorf("first start saw subscription %q", profile.SubscriptionURL)
					}
					return map[string]interface{}{"success": false, "error": "synthetic start failure"}
				}
				events = append(events, "start-old")
				profile, _ := storage.GetActiveProfile()
				if !reflect.DeepEqual(profile, &before) {
					t.Errorf("recovery started before old profile was restored: %#v", profile)
				}
				app.mu.Lock()
				app.isRunning = true
				app.mu.Unlock()
				return map[string]interface{}{"success": true}
			},
		},
	)

	if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != true {
		t.Fatalf("transaction result = %#v", result)
	}
	if !strings.Contains(result["error"].(string), "synthetic start failure") {
		t.Fatalf("start error was lost: %#v", result)
	}
	if !reflect.DeepEqual(events, []string{"stop", "build", "start-new", "start-old"}) {
		t.Fatalf("operation order = %v", events)
	}
	after, _ := storage.GetActiveProfile()
	if !reflect.DeepEqual(after, &before) {
		t.Fatalf("profile after recovery = %#v, want %#v", after, before)
	}
}

func TestSubscriptionMutationManualDisconnectCancelsRestartWithoutRollback(t *testing.T) {
	app, storage := newSubscriptionTransactionTestApp(t)
	events := make([]string, 0, 3)

	result := app.changeVPNSubscriptionTransaction(
		stringPointer(subscriptionTestNewURL),
		false,
		"test",
		subscriptionReconnectOps{
			stop: subscriptionTestStop(app, &events),
			build: func(rawURL string) error {
				events = append(events, "build")
				return writeSubscriptionTransactionTestProfile(storage, rawURL, 5, "new")
			},
			start: func() map[string]interface{} {
				events = append(events, "start-cancelled")
				app.desiredConnected.Store(false)
				settings := storage.GetAppSettings()
				settings.RestoreVPNOnStartup = false
				if err := storage.UpdateAppSettings(settings); err != nil {
					t.Fatal(err)
				}
				return map[string]interface{}{"success": false, "cancelled": true, "error": "cancelled"}
			},
		},
	)

	if result["success"] != true || result["restartCancelled"] != true || result["rolledBack"] != false {
		t.Fatalf("transaction result = %#v", result)
	}
	profile, _ := storage.GetActiveProfile()
	if profile.SubscriptionURL != subscriptionTestNewURL {
		t.Fatalf("valid subscription change was rolled back after manual stop: %#v", profile)
	}
	if app.desiredConnected.Load() || storage.GetAppSettings().RestoreVPNOnStartup {
		t.Fatal("manual disconnect did not remain authoritative")
	}
}

func TestSubscriptionMutationStopFailureDoesNotTouchProfile(t *testing.T) {
	app, storage := newSubscriptionTransactionTestApp(t)
	before, _ := storage.GetActiveProfile()
	buildCalled := false

	result := app.changeVPNSubscriptionTransaction(
		stringPointer(subscriptionTestNewURL),
		false,
		"test",
		subscriptionReconnectOps{
			stop: func() map[string]interface{} {
				return map[string]interface{}{"success": false, "error": "synthetic stop failure"}
			},
			build: func(string) error {
				buildCalled = true
				return nil
			},
			start: func() map[string]interface{} {
				t.Fatal("start must not run while the old VPN is still active")
				return nil
			},
		},
	)

	if result["success"] != false || result["connectionRestored"] != true {
		t.Fatalf("transaction result = %#v", result)
	}
	if buildCalled {
		t.Fatal("profile build ran after stop failure")
	}
	after, _ := storage.GetActiveProfile()
	if after.SubscriptionURL != before.SubscriptionURL ||
		after.ProxyCount != before.ProxyCount ||
		!reflect.DeepEqual(after.SingboxConfig, before.SingboxConfig) {
		t.Fatalf("profile changed after stop failure: %#v", after)
	}
}

func TestSubscriptionMutationDoesNotRestartAfterRollbackFailure(t *testing.T) {
	app, _ := newSubscriptionTransactionTestApp(t)
	events := make([]string, 0, 3)
	startCalls := 0

	result := app.changeVPNSubscriptionTransaction(
		stringPointer(subscriptionTestNewURL),
		false,
		"test",
		subscriptionReconnectOps{
			stop: subscriptionTestStop(app, &events),
			build: func(string) error {
				events = append(events, "build")
				return errors.New("candidate build failed")
			},
			start: func() map[string]interface{} {
				startCalls++
				return map[string]interface{}{"success": true}
			},
			restore: func(ProfileData) error {
				return errors.New("rollback storage unavailable")
			},
		},
	)

	if result["success"] != false || result["rolledBack"] != false || result["connectionRestored"] != false {
		t.Fatalf("rollback failure result = %#v", result)
	}
	if startCalls != 0 {
		t.Fatalf("unsafe recovery start called %d time(s)", startCalls)
	}
	errorText := result["error"].(string)
	if !strings.Contains(errorText, "rollback storage unavailable") || !strings.Contains(errorText, "VPN оставлен отключённым") {
		t.Fatalf("rollback failure was not reported safely: %s", errorText)
	}
}

func TestStoppedSubscriptionMutationSerializesConcurrentStart(t *testing.T) {
	app, _ := newSubscriptionTransactionTestApp(t)
	app.mu.Lock()
	app.isRunning = false
	app.mu.Unlock()
	app.desiredConnected.Store(false)

	buildEntered := make(chan struct{})
	releaseBuild := make(chan struct{})
	transactionDone := make(chan map[string]interface{}, 1)
	go func() {
		transactionDone <- app.changeVPNSubscriptionTransaction(
			stringPointer(subscriptionTestNewURL),
			false,
			"test",
			subscriptionReconnectOps{
				build: func(string) error {
					close(buildEntered)
					<-releaseBuild
					return nil
				},
			},
		)
	}()

	select {
	case <-buildEntered:
	case <-time.After(time.Second):
		t.Fatal("stopped subscription mutation did not enter build")
	}

	startDone := make(chan map[string]interface{}, 1)
	go func() { startDone <- app.Start() }()
	deadline := time.Now().Add(time.Second)
	for !app.desiredConnected.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !app.desiredConnected.Load() {
		close(releaseBuild)
		t.Fatal("concurrent Start did not publish intent")
	}
	select {
	case result := <-startDone:
		close(releaseBuild)
		t.Fatalf("Start entered a stopped config transaction: %#v", result)
	case <-time.After(50 * time.Millisecond):
	}

	// Avoid launching native dependencies after the transaction releases; the
	// assertion above is specifically that Start could not see the partial config.
	app.desiredConnected.Store(false)
	close(releaseBuild)
	if result := <-transactionDone; result["success"] != true {
		t.Fatalf("subscription transaction = %#v", result)
	}
	if result := <-startDone; result["cancelled"] != true {
		t.Fatalf("serialized Start result = %#v", result)
	}
}

func stringPointer(value string) *string {
	return &value
}
