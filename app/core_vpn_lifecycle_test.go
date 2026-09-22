package main

import (
	"sync/atomic"
	"testing"
	"time"
)

func withReconnectTestDelays(t *testing.T, delays []time.Duration) {
	t.Helper()
	previousDelays := vpnReconnectDelays
	vpnReconnectDelays = delays
	t.Cleanup(func() {
		vpnReconnectDelays = previousDelays
	})
}

func waitForReconnectIdle(t *testing.T, app *App) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for app.reconnecting.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if app.reconnecting.Load() {
		t.Fatal("reconnect campaign did not become idle")
	}
}

func TestVPNReconnectStopsAfterSuccessfulAttempt(t *testing.T) {
	var attempts atomic.Int32
	withReconnectTestDelays(t, []time.Duration{0, 0, 0})

	app := NewApp()
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		attempts.Add(1)
		return map[string]interface{}{"success": true}
	}
	app.desiredConnected.Store(true)
	app.scheduleVPNReconnect("test crash")
	waitForReconnectIdle(t, app)

	if got := attempts.Load(); got != 1 {
		t.Fatalf("reconnect attempts = %d, want 1", got)
	}
	if app.hasError.Load() {
		t.Fatal("successful reconnect left error state active")
	}
}

func TestVPNReconnectIsBounded(t *testing.T) {
	var attempts atomic.Int32
	withReconnectTestDelays(t, []time.Duration{0, 0, 0})

	app := NewApp()
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		attempts.Add(1)
		return map[string]interface{}{"success": false, "error": "offline"}
	}
	app.desiredConnected.Store(true)
	app.scheduleVPNReconnect("test crash")
	waitForReconnectIdle(t, app)

	if got := attempts.Load(); got != 3 {
		t.Fatalf("reconnect attempts = %d, want 3", got)
	}
	if !app.hasError.Load() {
		t.Fatal("exhausted reconnect campaign must surface an error")
	}
	status := app.GetStatus()
	if status["vpnState"] != "failed" || status["error"] != "Не удалось восстановить VPN после краткого обрыва: offline" {
		t.Fatalf("failed reconnect status = %#v", status)
	}
}

func TestManualStopCancelsDelayedReconnect(t *testing.T) {
	var attempts atomic.Int32
	withReconnectTestDelays(t, []time.Duration{150 * time.Millisecond})

	app := NewApp()
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		attempts.Add(1)
		return map[string]interface{}{"success": true}
	}
	app.initialized = true
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)
	app.scheduleVPNReconnect("test crash")
	result := app.Stop()
	if result["success"] != true {
		t.Fatalf("Stop() = %#v", result)
	}
	time.Sleep(200 * time.Millisecond)

	if got := attempts.Load(); got != 0 {
		t.Fatalf("stale reconnect attempted %d starts after Stop", got)
	}
	if app.desiredConnected.Load() {
		t.Fatal("manual Stop must clear desired connected state")
	}
}

func TestCancelledReconnectCannotPublishStaleTerminalFailure(t *testing.T) {
	withReconnectTestDelays(t, []time.Duration{0})

	app := NewApp()
	attempted := make(chan struct{})
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		close(attempted)
		return map[string]interface{}{"success": false, "error": "offline"}
	}
	app.desiredConnected.Store(true)

	// Hold the terminal commit while the attempt completes, then invalidate its
	// generation as a newer public intent would do.
	app.vpnLifecycleMu.Lock()
	app.scheduleVPNReconnect("test crash")
	select {
	case <-attempted:
	case <-time.After(time.Second):
		app.vpnLifecycleMu.Unlock()
		t.Fatal("reconnect attempt did not finish")
	}
	app.desiredConnected.Store(false)
	app.cancelVPNReconnect(false)
	app.hasError.Store(false)
	app.vpnLifecycleMu.Unlock()

	time.Sleep(20 * time.Millisecond)
	status := app.GetStatus()
	if app.hasError.Load() || status["vpnState"] == "failed" || status["error"] != "" {
		t.Fatalf("cancelled worker published stale failure: %#v", status)
	}
}

func TestGetStatusPublishesReconnectState(t *testing.T) {
	withReconnectTestDelays(t, []time.Duration{time.Second})

	app := NewApp()
	app.reconnectStartAttempt = func(*App) map[string]interface{} {
		return map[string]interface{}{"success": false}
	}
	app.initialized = true
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)
	app.scheduleVPNReconnect("test crash")
	t.Cleanup(func() { app.cancelVPNReconnect(false) })

	status := app.GetStatus()
	if status["vpnState"] != "reconnecting" || status["connecting"] != true {
		t.Fatalf("reconnect status = %#v", status)
	}
	if status["desiredConnected"] != true || status["reconnectProtected"] != false {
		t.Fatalf("reconnect contract = %#v", status)
	}
}

func TestPublicStartCannotEnterSourceReconnectTransaction(t *testing.T) {
	app := NewApp()
	app.desiredConnected.Store(true)
	generation := app.beginVPNTransactionalReconnect("source update")
	t.Cleanup(func() { app.finishVPNTransactionalReconnect(generation) })

	result := app.Start()
	if result["success"] != false {
		t.Fatalf("Start during transaction = %#v, want rejection", result)
	}
	if !app.desiredConnected.Load() {
		t.Fatal("rejected duplicate Start must not clear the existing connection intent")
	}
}

func TestDuplicatePublicStartCoalescesWithoutSupersedingIntent(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)

	app.vpnLifecycleMu.Lock()
	lifecycleLocked := true
	unlockLifecycle := func() {
		if lifecycleLocked {
			lifecycleLocked = false
			app.vpnLifecycleMu.Unlock()
		}
	}
	defer unlockLifecycle()
	firstDone := make(chan map[string]interface{}, 1)
	go func() { firstDone <- app.Start() }()

	deadline := time.Now().Add(time.Second)
	var generation uint64
	for time.Now().Before(deadline) {
		app.vpnIntentMu.Lock()
		generation = app.activeStartIntent
		app.vpnIntentMu.Unlock()
		if generation != 0 && app.desiredConnected.Load() {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if generation == 0 || !app.desiredConnected.Load() {
		unlockLifecycle()
		t.Fatal("first Start did not publish its active intent")
	}

	duplicate := app.Start()
	if duplicate["success"] != true || duplicate["connecting"] != true || duplicate["unchanged"] != true {
		unlockLifecycle()
		t.Fatalf("duplicate Start result = %#v, want coalesced connecting result", duplicate)
	}
	if got := app.vpnIntentGeneration.Load(); got != generation {
		unlockLifecycle()
		t.Fatalf("duplicate Start changed generation from %d to %d", generation, got)
	}

	// Publish a later stop so the first attempt exits before dependency setup.
	stopDone := make(chan map[string]interface{}, 1)
	go func() { stopDone <- app.Stop() }()
	deadline = time.Now().Add(time.Second)
	for app.desiredConnected.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if app.desiredConnected.Load() {
		unlockLifecycle()
		t.Fatal("Stop did not supersede the coalesced Start intent")
	}
	unlockLifecycle()

	first := <-firstDone
	if first["cancelled"] != true || first["superseded"] != true {
		t.Fatalf("first Start result = %#v, want superseded cancellation", first)
	}
	if stopped := <-stopDone; stopped["success"] != true {
		t.Fatalf("Stop result = %#v", stopped)
	}
}

func TestStartAfterQueuedStopSupersedesOlderPendingStart(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)

	app.vpnLifecycleMu.Lock()
	lifecycleLocked := true
	unlockLifecycle := func() {
		if lifecycleLocked {
			lifecycleLocked = false
			app.vpnLifecycleMu.Unlock()
		}
	}
	defer unlockLifecycle()
	firstDone := make(chan map[string]interface{}, 1)
	go func() { firstDone <- app.Start() }()
	waitForDesiredConnectionState(t, app, true)
	firstGeneration := app.vpnIntentGeneration.Load()

	stopDone := make(chan map[string]interface{}, 1)
	go func() { stopDone <- app.Stop() }()
	waitForDesiredConnectionState(t, app, false)
	stopGeneration := app.vpnIntentGeneration.Load()
	if stopGeneration <= firstGeneration {
		unlockLifecycle()
		t.Fatalf("Stop generation = %d, want newer than %d", stopGeneration, firstGeneration)
	}

	secondDone := make(chan map[string]interface{}, 1)
	go func() { secondDone <- app.Start() }()
	waitForDesiredConnectionState(t, app, true)
	secondGeneration := app.vpnIntentGeneration.Load()
	if secondGeneration <= stopGeneration {
		unlockLifecycle()
		t.Fatalf("later Start generation = %d, want newer than %d", secondGeneration, stopGeneration)
	}
	app.vpnIntentMu.Lock()
	activeGeneration := app.activeStartIntent
	app.vpnIntentMu.Unlock()
	if activeGeneration != secondGeneration {
		unlockLifecycle()
		t.Fatalf("active Start generation = %d, want %d", activeGeneration, secondGeneration)
	}
	select {
	case result := <-secondDone:
		unlockLifecycle()
		t.Fatalf("later Start was incorrectly coalesced: %#v", result)
	default:
	}

	// Supersede every queued command before releasing the lifecycle gate so the
	// test never enters dependency or process setup.
	app.vpnIntentMu.Lock()
	app.vpnIntentGeneration.Add(1)
	app.desiredConnected.Store(false)
	app.vpnIntentMu.Unlock()
	unlockLifecycle()

	if result := <-firstDone; result["superseded"] != true {
		t.Fatalf("first Start result = %#v", result)
	}
	if result := <-stopDone; result["superseded"] != true {
		t.Fatalf("queued Stop result = %#v", result)
	}
	if result := <-secondDone; result["superseded"] != true {
		t.Fatalf("later Start result = %#v", result)
	}
}

func waitForDesiredConnectionState(t *testing.T, app *App, want bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for app.desiredConnected.Load() != want && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := app.desiredConnected.Load(); got != want {
		t.Fatalf("desiredConnected = %v, want %v", got, want)
	}
}

func TestPublicStartIsIdempotentWhenAlreadyRunning(t *testing.T) {
	app := NewApp()
	app.desiredConnected.Store(true)
	app.mu.Lock()
	app.isRunning = true
	app.mu.Unlock()

	before := app.vpnIntentGeneration.Load()
	result := app.Start()
	if result["success"] != true || result["running"] != true || result["unchanged"] != true {
		t.Fatalf("Start while running = %#v, want idempotent success", result)
	}
	if got := app.vpnIntentGeneration.Load(); got != before {
		t.Fatalf("idempotent Start changed generation from %d to %d", before, got)
	}
}

func TestQueuedPublicStartIsIdempotentAfterInternalRestart(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)
	app.desiredConnected.Store(true)

	app.vpnLifecycleMu.Lock()
	startDone := make(chan map[string]interface{}, 1)
	go func() { startDone <- app.Start() }()

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		app.vpnIntentMu.Lock()
		active := app.activeStartIntent
		app.vpnIntentMu.Unlock()
		if active != 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	app.vpnIntentMu.Lock()
	active := app.activeStartIntent
	app.vpnIntentMu.Unlock()
	if active == 0 {
		app.vpnLifecycleMu.Unlock()
		t.Fatal("queued Start did not publish its intent")
	}

	// Model the transaction's successful startVPNForReconnect before it releases
	// vpnLifecycleMu to the queued public command.
	app.mu.Lock()
	app.isRunning = true
	app.mu.Unlock()
	app.vpnLifecycleMu.Unlock()

	result := <-startDone
	if result["success"] != true || result["running"] != true || result["unchanged"] != true {
		t.Fatalf("queued Start after internal restart = %#v, want idempotent success", result)
	}
}

func TestStaleStopCannotOverrideNewerStartIntent(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)
	app.mu.Lock()
	app.isRunning = true
	app.mu.Unlock()
	app.desiredConnected.Store(true)

	app.vpnLifecycleMu.Lock()
	done := make(chan map[string]interface{}, 1)
	go func() { done <- app.Stop() }()
	deadline := time.Now().Add(time.Second)
	for app.desiredConnected.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if app.desiredConnected.Load() {
		app.vpnLifecycleMu.Unlock()
		t.Fatal("Stop did not publish its intent before waiting for lifecycle lock")
	}

	// Model the later public Start at the intent boundary. The stale Stop must
	// become a no-op after it eventually acquires vpnLifecycleMu.
	app.vpnIntentGeneration.Add(1)
	app.desiredConnected.Store(true)
	app.vpnLifecycleMu.Unlock()

	result := <-done
	if result["superseded"] != true {
		t.Fatalf("stale Stop result = %#v", result)
	}
	if !app.isVPNRunning() || !app.desiredConnected.Load() {
		t.Fatal("stale Stop overrode the newer connected intent")
	}
}

func TestStaleStartCannotOverrideNewerStopIntent(t *testing.T) {
	app := NewApp()
	app.initialized = true
	app.initializedReady.Store(true)

	app.vpnLifecycleMu.Lock()
	done := make(chan map[string]interface{}, 1)
	go func() { done <- app.Start() }()
	deadline := time.Now().Add(time.Second)
	for !app.desiredConnected.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !app.desiredConnected.Load() {
		app.vpnLifecycleMu.Unlock()
		t.Fatal("Start did not publish its intent before waiting for lifecycle lock")
	}

	// Model the later public Stop at the intent boundary. Start must return
	// before attempting dependency setup or creating a process.
	app.vpnIntentGeneration.Add(1)
	app.desiredConnected.Store(false)
	app.vpnLifecycleMu.Unlock()

	result := <-done
	if result["cancelled"] != true || result["superseded"] != true {
		t.Fatalf("stale Start result = %#v", result)
	}
	if app.isVPNRunning() || app.desiredConnected.Load() {
		t.Fatal("stale Start overrode the newer stopped intent")
	}
}
