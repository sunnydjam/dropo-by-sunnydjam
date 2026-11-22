package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

const vpnSourcePreparationBudget = 45 * time.Second

// vpnSourceReconnectOps keeps the source mutation transaction testable without
// launching native networking processes. Production always supplies the
// lifecycle coordinator's internal reconnect methods so user intent and the
// persisted restore flag survive the temporary stop.
type vpnSourceReconnectOps struct {
	stop    func() map[string]interface{}
	start   func() map[string]interface{}
	restore func(ProfileData) error
}

// changeVPNSourcesTransaction applies a source-chain mutation and, when the VPN
// was active, does not return until the new configuration is running or the old
// profile has been restored and its connection recovery has completed.
func (a *App) changeVPNSourcesTransaction(change func(*ProfileData) error, ops vpnSourceReconnectOps) map[string]interface{} {
	return a.changeVPNSourcesTransactionValidated(change, nil, ops)
}

// validateSources runs after subscription refresh but before any generated
// configuration is saved. A manual stable-ID selection must not become the
// provider's first node if the chosen server disappears during that refresh.
func (a *App) changeVPNSourcesTransactionValidated(change func(*ProfileData) error, validateSources func([]VPNSource) error, ops vpnSourceReconnectOps) map[string]interface{} {
	a.waitForInit()
	a.settingsPolicyMu.Lock()
	defer a.settingsPolicyMu.Unlock()
	// Serialize snapshots and the eventual commit, not subscription downloads.
	// Public Stop must remain usable while a provider is slow.
	a.vpnLifecycleMu.Lock()
	lifecycleLocked := true
	defer func() {
		if lifecycleLocked {
			a.vpnLifecycleMu.Unlock()
		}
	}()

	result := map[string]interface{}{
		"success":            false,
		"wasRunning":         false,
		"restarted":          false,
		"connectionRestored": false,
		"rolledBack":         false,
		"restartCancelled":   false,
	}
	if a.storage == nil || a.configBuilder == nil {
		result["error"] = "VPN storage is not initialized"
		return result
	}
	if change == nil {
		result["error"] = "VPN source change is not initialized"
		return result
	}
	a.mu.Lock()
	wasRunning := a.isRunning
	wasStarting := a.isStarting
	a.mu.Unlock()
	if wasStarting || a.vpnStopping.Load() || a.reconnecting.Load() {
		result["error"] = "Дождитесь завершения текущего подключения VPN и повторите изменение источников"
		return result
	}

	profile, err := a.storage.GetActiveProfile()
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	previous, err := cloneVPNSourceProfile(profile)
	if err != nil {
		result["error"] = fmt.Sprintf("Не удалось подготовить изменение VPN-источников: %v", err)
		return result
	}
	candidate, err := cloneVPNSourceProfile(&previous)
	if err != nil {
		result["error"] = fmt.Sprintf("Не удалось подготовить изменение VPN-источников: %v", err)
		return result
	}
	if err := change(&candidate); err != nil {
		result["error"] = err.Error()
		return result
	}
	for index := range candidate.VPNSources {
		if strings.TrimSpace(candidate.VPNSources[index].ID) == "" {
			candidate.VPNSources[index].ID = nextVPNSourceID(candidate.VPNSources)
		}
	}
	// The candidate list is an explicit replacement. In particular, an empty
	// list must not be interpreted as a request to import the old summary URL.
	candidate.SubscriptionURL = ""
	normalizeProfileVPNSources(&candidate)
	hasEnabledSource := false
	for _, source := range candidate.VPNSources {
		if !source.Disabled {
			hasEnabledSource = true
			break
		}
	}
	// Only an actually empty/disabled chain can skip building. An enabled but
	// malformed or unsupported newly added key must still fail validation.
	if !wasRunning && NormalizeRoutingMode(a.storage.GetAppSettings().RoutingMode) == RoutingModeAllTraffic && !hasEnabledSource {
		if err := a.storage.saveUnreadyVPNProfile(candidate, nil); err != nil {
			result["error"] = "Не удалось сохранить VPN-источники: " + err.Error()
			return result
		}
		result["success"] = true
		result["connectionRestored"] = true
		return a.finishVPNSourceChangeResult(result)
	}

	result["wasRunning"] = wasRunning
	result["connectionRestored"] = !wasRunning || a.isVPNRunning()
	// Prepare a complete candidate without touching disk or stopping the session.
	// One budget covers the whole source list; cancellation cannot use a cached
	// partial result and cannot later resurrect the user's stopped session.
	parent := a.ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancelPreparation := context.WithTimeout(parent, vpnSourcePreparationBudget)
	a.vpnIntentMu.Lock()
	expectedIntent := a.vpnIntentGeneration.Load()
	a.sourcePrepareCancel = cancelPreparation
	a.vpnIntentMu.Unlock()
	defer func() {
		cancelPreparation()
		a.vpnIntentMu.Lock()
		a.sourcePrepareCancel = nil
		a.vpnIntentMu.Unlock()
	}()
	preparer := a.configBuilder.sourcePreparationBuilder()
	busyID := a.beginBusy("Подготавливаем VPN-источники без отключения...")
	defer a.endBusy(busyID)
	a.vpnLifecycleMu.Unlock()
	lifecycleLocked = false
	prepared, prepareErr := preparer.prepareConfigForProfileSources(ctx, candidate.ID, candidate.VPNSources, candidate.WireGuardConfigs, validateSources, candidate.VPNSourceSelectionMode == "priority")
	a.vpnLifecycleMu.Lock()
	lifecycleLocked = true
	if ctx.Err() != nil || a.vpnIntentGeneration.Load() != expectedIntent || a.isShuttingDown() {
		result["cancelled"] = true
		result["restartCancelled"] = true
		result["error"] = "Подготовка VPN-источников отменена или превысила время ожидания; прежние настройки сохранены"
		return result
	}
	if prepareErr != nil {
		result["error"] = "Не удалось подготовить VPN-источники: " + prepareErr.Error()
		return result
	}
	current, currentErr := a.storage.GetActiveProfile()
	a.mu.Lock()
	wasRunning, wasStarting = a.isRunning, a.isStarting
	a.mu.Unlock()
	if currentErr != nil || current.ID != candidate.ID || wasStarting || a.vpnStopping.Load() || a.reconnecting.Load() {
		result["error"] = "Состояние VPN изменилось во время подготовки; повторите изменение источников"
		return result
	}
	// Refresh rollback metadata after preparation (renaming/starred flags may
	// change independently). Source/settings changes are excluded by policyMu.
	previous, err = cloneVPNSourceProfile(current)
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	result["wasRunning"] = wasRunning
	result["connectionRestored"] = !wasRunning
	transactionGeneration := uint64(0)
	if wasRunning {
		transactionGeneration = a.beginVPNTransactionalReconnect("Применяем изменения VPN-источников")
		result["generation"] = transactionGeneration
		result["protectionHeld"] = false
		result["reconnectProtected"] = false
		defer a.finishVPNTransactionalReconnect(transactionGeneration)
	}
	if wasRunning {
		if ops.stop == nil || ops.start == nil {
			result["error"] = "VPN reconnect coordinator is not initialized"
			return result
		}
		stopResult := ops.stop()
		copyVPNSourceTransitionMetadata(result, stopResult)
		if !apiResultSucceeded(stopResult) {
			primary := "Не удалось остановить VPN для изменения источников: " + apiResultMessage(stopResult)
			if a.isVPNRunning() {
				result["connectionRestored"] = true
				result["error"] = primary
				return result
			}
			recovery := a.recoverVPNSourceConnection(true, ops, result)
			if strings.TrimSpace(recovery) != "" {
				primary += "; " + recovery
			}
			result["error"] = primary
			return result
		}
		if a.isVPNRunning() {
			result["error"] = "VPN не остановился; цепочка источников не изменена"
			result["connectionRestored"] = true
			return result
		}
	}

	a.updateBusy(busyID, "Применяем подготовленные VPN-источники...")
	if err := a.storage.commitPreparedVPNSourceConfig(candidate.ID, prepared); err != nil {
		rollbackErr := a.restoreVPNSourceProfileWith(previous, ops.restore)
		result["rolledBack"] = rollbackErr == nil
		recovery := rollbackRecoveryMessage(rollbackErr, wasRunning)
		if rollbackErr == nil {
			recovery = a.recoverVPNSourceConnection(wasRunning, ops, result)
		}
		result["error"] = formatVPNSourceTransactionError(
			"Не удалось обновить VPN-источники: "+err.Error(),
			rollbackErr,
			recovery,
		)
		return result
	}

	if wasRunning {
		startResult := ops.start()
		copyVPNSourceTransitionMetadata(result, startResult)
		if vpnSourceReconnectCancelled(startResult) {
			// An explicit user disconnect wins over an internal restart. The source
			// change is valid and remains saved, while the desired stopped state has
			// already been reached by the lifecycle coordinator.
			result["success"] = true
			result["restartCancelled"] = true
			result["connectionRestored"] = true
			return a.finishVPNSourceChangeResult(result)
		}
		if !apiResultSucceeded(startResult) || !a.isVPNRunning() {
			startError := apiResultMessage(startResult)
			if apiResultSucceeded(startResult) {
				startError = "VPN не перешёл в состояние подключено"
			}
			rollbackErr := a.restoreVPNSourceProfileWith(previous, ops.restore)
			result["rolledBack"] = rollbackErr == nil
			recovery := rollbackRecoveryMessage(rollbackErr, true)
			if rollbackErr == nil {
				recovery = a.recoverVPNSourceConnection(true, ops, result)
			}
			result["error"] = formatVPNSourceTransactionError(
				"Новая цепочка источников сохранена, но VPN не переподключился: "+startError,
				rollbackErr,
				recovery,
			)
			return result
		}
		result["restarted"] = true
		result["connectionRestored"] = true
	}

	result["success"] = true
	return a.finishVPNSourceChangeResult(result)
}

func (a *App) finishVPNSourceChangeResult(result map[string]interface{}) map[string]interface{} {
	updated, err := a.storage.GetActiveProfile()
	if err != nil {
		result["success"] = false
		result["error"] = "VPN-источники применены, но не удалось прочитать сохранённый профиль: " + err.Error()
		return result
	}
	result["sources"] = publicVPNSources(updated.VPNSources)
	result["sourceCount"] = len(updated.VPNSources)
	result["sourceRequired"] = NormalizeRoutingMode(a.storage.GetAppSettings().RoutingMode) == RoutingModeAllTraffic && !hasConfiguredVPNSource(updated)
	return result
}

// recoverVPNSourceConnection synchronously restores the expected running state
// after a failed build or failed first start. A user disconnect cancels the
// recovery and is considered an authoritative, successfully reached state.
func (a *App) recoverVPNSourceConnection(wasRunning bool, ops vpnSourceReconnectOps, result map[string]interface{}) string {
	if !wasRunning {
		result["connectionRestored"] = true
		return ""
	}
	if ops.start == nil {
		return "координатор восстановления VPN недоступен"
	}
	recoveryResult := ops.start()
	copyVPNSourceTransitionMetadata(result, recoveryResult)
	if vpnSourceReconnectCancelled(recoveryResult) {
		result["restartCancelled"] = true
		result["connectionRestored"] = true
		return ""
	}
	if !apiResultSucceeded(recoveryResult) || !a.isVPNRunning() {
		message := apiResultMessage(recoveryResult)
		if apiResultSucceeded(recoveryResult) {
			message = "VPN не перешёл в состояние подключено"
		}
		return "не удалось восстановить прежнее VPN-подключение: " + message
	}
	result["connectionRestored"] = true
	return "прежнее VPN-подключение восстановлено"
}

func copyVPNSourceTransitionMetadata(target, transition map[string]interface{}) {
	if target == nil || transition == nil {
		return
	}
	for _, key := range []string{"generation", "protectionHeld", "reconnectProtected"} {
		if value, ok := transition[key]; ok {
			target[key] = value
		}
	}
}

func vpnSourceReconnectCancelled(result map[string]interface{}) bool {
	cancelled, _ := result["cancelled"].(bool)
	return cancelled
}

func formatVPNSourceTransactionError(primary string, rollbackErr error, recovery string) string {
	parts := []string{strings.TrimSpace(primary)}
	if rollbackErr != nil {
		parts = append(parts, "не удалось восстановить прежний профиль: "+rollbackErr.Error())
	} else {
		parts = append(parts, "прежний профиль восстановлен")
	}
	if strings.TrimSpace(recovery) != "" {
		parts = append(parts, recovery)
	}
	return strings.Join(parts, "; ")
}

func rollbackRecoveryMessage(rollbackErr error, wasRunning bool) string {
	if rollbackErr != nil && wasRunning {
		return "VPN оставлен отключённым: прежний профиль не был надёжно восстановлен"
	}
	return ""
}

func (a *App) restoreVPNSourceProfileWith(snapshot ProfileData, restore func(ProfileData) error) error {
	if restore != nil {
		return restore(snapshot)
	}
	return a.restoreVPNSourceProfile(snapshot)
}

func cloneVPNSourceProfile(profile *ProfileData) (ProfileData, error) {
	if profile == nil {
		return ProfileData{}, fmt.Errorf("profile is nil")
	}
	data, err := json.Marshal(profile)
	if err != nil {
		return ProfileData{}, err
	}
	var cloned ProfileData
	if err := json.Unmarshal(data, &cloned); err != nil {
		return ProfileData{}, err
	}
	return cloned, nil
}

// restoreVPNSourceProfile replaces the complete profile in one storage write.
// Restore source, Xray and sing-box fields together, including after a candidate
// config was committed successfully but its reconnect failed.
func (a *App) restoreVPNSourceProfile(snapshot ProfileData) error {
	if a.storage == nil {
		return fmt.Errorf("VPN storage is not initialized")
	}
	restored, err := cloneVPNSourceProfile(&snapshot)
	if err != nil {
		return err
	}
	s := a.storage
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.data.Profiles {
		if s.data.Profiles[index].ID != restored.ID {
			continue
		}
		current := s.data.Profiles[index]
		s.data.Profiles[index] = restored
		if err := s.saveInternal(); err != nil {
			s.data.Profiles[index] = current
			return err
		}
		return nil
	}
	return fmt.Errorf("profile with ID %d not found", restored.ID)
}
