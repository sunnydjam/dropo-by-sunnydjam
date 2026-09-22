package main

import (
	"context"
	"fmt"
	"time"
)

// The retry ladder is deliberately short. It repairs transient process or
// network failures without leaving an unbounded background loop that can
// resurrect a session after the user pressed Disconnect.
var vpnReconnectDelays = []time.Duration{
	750 * time.Millisecond,
	2 * time.Second,
	5 * time.Second,
}

type vpnReconnectSnapshot struct {
	Active     bool
	Generation uint64
	Attempt    int
	Total      int
	Reason     string
	Error      string
}

func (a *App) vpnReconnectSnapshot() vpnReconnectSnapshot {
	if a == nil {
		return vpnReconnectSnapshot{}
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	return vpnReconnectSnapshot{
		Active:     a.reconnecting.Load(),
		Generation: a.reconnectGeneration.Load(),
		Attempt:    a.reconnectAttempt,
		Total:      len(vpnReconnectDelays),
		Reason:     a.reconnectReason,
		Error:      a.reconnectError,
	}
}

func (a *App) vpnTransactionalReconnectActive() bool {
	if a == nil {
		return false
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	return a.reconnecting.Load() && a.reconnectCancel == nil && a.reconnectReason != ""
}

// cancelVPNReconnect invalidates every delayed attempt before a new user
// transition is queued. It is safe to call when no campaign is active.
func (a *App) cancelVPNReconnect(emit bool) {
	if a == nil {
		return
	}
	a.reconnectMu.Lock()
	cancel := a.reconnectCancel
	wasActive := a.reconnecting.Load()
	if cancel != nil {
		cancel()
	}
	a.reconnectCancel = nil
	a.reconnectReason = ""
	a.reconnectAttempt = 0
	a.reconnectError = ""
	a.reconnecting.Store(false)
	a.reconnectGeneration.Add(1)
	generation := a.reconnectGeneration.Load()
	a.reconnectMu.Unlock()
	if emit && wasActive {
		a.emitVPNLifecycleState("stopped", generation, 0, "Переподключение отменено")
	}
}

// scheduleVPNReconnect starts a generation-fenced recovery campaign after an
// unexpected sing-box exit. It restores connectivity only while the user's
// desiredConnected intent remains true.
func (a *App) scheduleVPNReconnect(reason string) {
	if a == nil || !a.desiredConnected.Load() || a.isShuttingDown() {
		return
	}

	a.reconnectMu.Lock()
	if a.reconnectCancel != nil {
		a.reconnectCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	generation := a.reconnectGeneration.Add(1)
	a.reconnectCancel = cancel
	a.reconnectReason = reason
	a.reconnectAttempt = 0
	a.reconnectError = ""
	a.reconnecting.Store(true)
	a.reconnectMu.Unlock()

	a.hasError.Store(false)
	UpdateTrayIcon("connecting")
	a.emitVPNLifecycleState("reconnecting", generation, 0, reason)
	go a.runVPNReconnect(ctx, generation, reason)
}

// beginVPNTransactionalReconnect exposes a source/settings restart as one
// continuous reconnecting phase. Unlike crash recovery it has no retry context;
// the calling transaction performs stop, apply, start and rollback in order.
func (a *App) beginVPNTransactionalReconnect(reason string) uint64 {
	if a == nil {
		return 0
	}
	a.reconnectMu.Lock()
	if a.reconnectCancel != nil {
		a.reconnectCancel()
	}
	generation := a.reconnectGeneration.Add(1)
	a.reconnectCancel = nil
	a.reconnectReason = reason
	a.reconnectAttempt = 0
	a.reconnectError = ""
	a.reconnecting.Store(true)
	a.reconnectMu.Unlock()
	a.emitVPNLifecycleState("reconnecting", generation, 0, reason)
	return generation
}

func (a *App) finishVPNTransactionalReconnect(generation uint64) {
	if a == nil {
		return
	}
	a.reconnectMu.Lock()
	if a.reconnectGeneration.Load() == generation && a.reconnectCancel == nil {
		a.reconnectReason = ""
		a.reconnectAttempt = 0
		a.reconnecting.Store(false)
	}
	a.reconnectMu.Unlock()
}

func (a *App) runVPNReconnect(ctx context.Context, generation uint64, reason string) {
	lastError := ""
	for index, delay := range vpnReconnectDelays {
		attempt := index + 1
		if !a.setVPNReconnectAttempt(ctx, generation, attempt) {
			return
		}
		a.emitVPNLifecycleState("reconnecting", generation, attempt,
			fmt.Sprintf("Переподключение %d/%d", attempt, len(vpnReconnectDelays)))

		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}
		if !a.vpnReconnectCurrent(ctx, generation) {
			return
		}

		startAttempt := a.reconnectStartAttempt
		var result map[string]interface{}
		if startAttempt == nil {
			result = a.startVPNReconnectAttempt(ctx, generation)
		} else {
			result = startAttempt(a)
		}
		if ok, _ := result["success"].(bool); ok {
			if !a.completeVPNReconnectSuccess(ctx, generation, attempt) {
				return
			}
			return
		}
		lastError, _ = result["error"].(string)
		if lastError == "" {
			lastError = "неизвестная ошибка запуска"
		}
		a.writeLog(fmt.Sprintf("[Reconnect] attempt %d/%d failed: %s", attempt, len(vpnReconnectDelays), lastError))
	}

	message := "Не удалось восстановить VPN после краткого обрыва"
	if lastError != "" {
		message += ": " + lastError
	}
	a.completeVPNReconnectFailure(ctx, generation, message)
}

// startVPNReconnectAttempt closes the small race between the worker's timer
// check and acquiring the lifecycle lock. A newer Start/Stop generation can
// invalidate the attempt while it is queued, so generation is checked again
// after serialization and immediately before any side effect.
func (a *App) startVPNReconnectAttempt(ctx context.Context, generation uint64) map[string]interface{} {
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	if !a.vpnReconnectCurrent(ctx, generation) {
		return map[string]interface{}{"success": false, "cancelled": true, "error": "Переподключение отменено"}
	}
	return a.startVPN(a.vpnIntentGeneration.Load())
}

func (a *App) vpnReconnectCurrent(ctx context.Context, generation uint64) bool {
	if a == nil || ctx == nil || ctx.Err() != nil || a.isShuttingDown() || !a.desiredConnected.Load() {
		return false
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	return a.reconnectCancel != nil && a.reconnectGeneration.Load() == generation
}

func (a *App) setVPNReconnectAttempt(ctx context.Context, generation uint64, attempt int) bool {
	if !a.vpnReconnectCurrent(ctx, generation) {
		return false
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	if a.reconnectCancel == nil || a.reconnectGeneration.Load() != generation {
		return false
	}
	a.reconnectAttempt = attempt
	return true
}

func (a *App) finishVPNReconnect(ctx context.Context, generation uint64) bool {
	if !a.vpnReconnectCurrent(ctx, generation) {
		return false
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	if a.reconnectCancel == nil || a.reconnectGeneration.Load() != generation {
		return false
	}
	a.reconnectCancel = nil
	a.reconnectReason = ""
	a.reconnectAttempt = 0
	a.reconnecting.Store(false)
	return true
}

// Terminal reconnect commits are lifecycle-serialized. A newer public
// Start/Stop can invalidate the generation while waiting for this lock; in
// that case the stale worker performs no tray, error, log, or event updates.
func (a *App) completeVPNReconnectSuccess(ctx context.Context, generation uint64, attempt int) bool {
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	if !a.finishVPNReconnect(ctx, generation) {
		return false
	}
	a.hasError.Store(false)
	a.writeLog(fmt.Sprintf("[Reconnect] VPN restored on attempt %d/%d", attempt, len(vpnReconnectDelays)))
	a.emitVPNLifecycleState("connected", generation, attempt, "VPN восстановлен")
	return true
}

func (a *App) completeVPNReconnectFailure(ctx context.Context, generation uint64, message string) bool {
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	if !a.finishVPNReconnect(ctx, generation) {
		return false
	}
	a.setVPNLifecycleError(generation, message)
	a.hasError.Store(true)
	UpdateTrayIcon("error")
	a.AddToLogBuffer(message)
	a.emitVPNLifecycleState("failed", generation, len(vpnReconnectDelays), message)
	return true
}

func (a *App) setVPNLifecycleError(generation uint64, message string) {
	if a == nil {
		return
	}
	a.reconnectMu.Lock()
	defer a.reconnectMu.Unlock()
	if a.reconnectGeneration.Load() == generation {
		a.reconnectError = message
	}
}

func (a *App) emitVPNLifecycleState(state string, generation uint64, attempt int, message string) {
	if a == nil || a.ctx == nil {
		return
	}
	payload := map[string]interface{}{
		"vpnState":          state,
		"state":             state,
		"connected":         state == "connected",
		"running":           state == "connected",
		"connecting":        state == "starting" || state == "reconnecting",
		"disconnecting":     state == "disconnecting",
		"desiredConnected":  a.desiredConnected.Load(),
		"sessionGeneration": generation,
		"reconnectAttempt":  attempt,
		"reconnectTotal":    len(vpnReconnectDelays),
		"message":           message,
	}
	if state == "failed" {
		payload["hasError"] = true
		payload["error"] = message
	}
	a.emitEvent("vpn-status-changed", payload)
}
