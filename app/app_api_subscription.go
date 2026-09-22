package main

// Subscription management methods for dropo.
// This file contains subscription-related API methods

import (
	"fmt"
	"strings"
)

// subscriptionReconnectOps keeps subscription mutations deterministic and
// testable. Production uses the lifecycle coordinator's internal reconnect
// methods so a temporary stop does not clear the user's connected intent or
// RestoreVPNOnStartup.
type subscriptionReconnectOps struct {
	build   func(string) error
	stop    func() map[string]interface{}
	start   func() map[string]interface{}
	restore func(ProfileData) error
}

// TestSubscription tests a subscription URL and returns available proxies
func (a *App) TestSubscription(url string) map[string]interface{} {
	fetcher := NewSubscriptionFetcher()
	proxies, err := fetcher.ParseSource(url)
	if err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   err.Error(),
			"count":   0,
		}
	}

	// Filter unsupported transports (e.g., xhttp which is Xray-only)
	filterResult := FilterUnsupportedTransports(proxies)
	filteredProxies := filterResult.Supported

	// Convert proxies to simple format for frontend
	proxyList := []map[string]interface{}{}
	for _, p := range filteredProxies {
		proxyList = append(proxyList, map[string]interface{}{
			"type":   p.Type,
			"raw":    p.Raw,
			"name":   p.Name,
			"server": p.Server,
			"port":   p.ServerPort,
		})
	}

	result := map[string]interface{}{
		"success": true,
		"count":   len(filteredProxies),
		"proxies": proxyList,
	}

	// Add warning if some proxies were filtered out
	if len(filterResult.Filtered) > 0 {
		result["warning"] = filterResult.Message
		result["filteredCount"] = len(filterResult.Filtered)
		result["totalOriginal"] = len(proxies)

		// If ALL proxies were filtered, return error
		if filterResult.AllFiltered {
			return map[string]interface{}{
				"success": false,
				"error":   filterResult.Message,
				"count":   0,
			}
		}
	}

	return result
}

// GenerateAndSaveConfig generates config from settings and saves it
func (a *App) GenerateAndSaveConfig() map[string]interface{} {
	result := a.changeVPNSubscriptionTransaction(nil, false, "Генерируем конфиг...", a.subscriptionReconnectOps())
	if !apiResultSucceeded(result) {
		return result
	}
	configPath, err := a.storage.GetConfigPath()
	if err != nil {
		result["success"] = false
		result["error"] = fmt.Sprintf("Конфиг создан, но не удалось подготовить его для запуска: %v", err)
		return result
	}
	result["path"] = configPath
	return result
}

// UpdateSubscriptions fetches all subscriptions and regenerates config
func (a *App) UpdateSubscriptions() map[string]interface{} {
	return a.changeVPNSubscriptionTransaction(nil, false, "Обновляем подписки...", a.subscriptionReconnectOps())
}

// ==================== Subscription Management (New API) ====================

// GetCurrentSubscription возвращает текущую подписку пользователя
func (a *App) GetCurrentSubscription() map[string]interface{} {
	// Ждём инициализации
	a.waitForInit()

	if a.storage == nil {
		return map[string]interface{}{
			"hasSubscription": false,
			"error":           "Storage не инициализирован",
		}
	}

	settings, err := a.storage.GetUserSettings()
	if err != nil {
		return map[string]interface{}{
			"hasSubscription": false,
			"error":           err.Error(),
		}
	}

	if settings.SubscriptionURL == "" {
		return map[string]interface{}{
			"hasSubscription": false,
		}
	}

	return map[string]interface{}{
		"hasSubscription": true,
		"url":             settings.SubscriptionURL,
		"lastUpdated":     settings.LastUpdated,
		"proxyCount":      settings.ProxyCount,
	}
}

// TestVPNConnection тестирует подписку или прямую ссылку
func (a *App) TestVPNConnection(url string) map[string]interface{} {
	busyID := a.beginBusy("Проверяем VPN-подписку...")
	defer a.endBusy(busyID)

	// Ждём инициализации
	a.waitForInit()

	if a.configBuilder == nil {
		return map[string]interface{}{
			"success": false,
			"error":   "ConfigBuilder не инициализирован",
		}
	}

	a.updateBusy(busyID, "Скачиваем и разбираем список серверов...")
	result, err := a.configBuilder.TestSubscription(url)
	if err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   err.Error(),
		}
	}

	return map[string]interface{}{
		"success":      result.Success,
		"error":        result.Error,
		"count":        result.Count,
		"isDirectLink": result.IsDirectLink,
		"proxies":      result.Proxies,
	}
}

// SetVPNSubscription устанавливает подписку и генерирует конфиг
func (a *App) SetVPNSubscription(url string) map[string]interface{} {
	url = strings.TrimSpace(url)
	return a.changeVPNSubscriptionTransaction(&url, false, "Сохраняем VPN-подписку...", a.subscriptionReconnectOps())
}

// RemoveVPNSubscription удаляет подписку и генерирует конфиг без прокси
func (a *App) RemoveVPNSubscription() map[string]interface{} {
	empty := ""
	return a.changeVPNSubscriptionTransaction(&empty, false, "Удаляем VPN-подписку...", a.subscriptionReconnectOps())
}

// RefreshVPNSubscription обновляет текущую подписку
func (a *App) RefreshVPNSubscription() map[string]interface{} {
	return a.changeVPNSubscriptionTransaction(nil, true, "Обновляем VPN-подписку...", a.subscriptionReconnectOps())
}

func (a *App) subscriptionReconnectOps() subscriptionReconnectOps {
	if a == nil {
		return subscriptionReconnectOps{}
	}
	return subscriptionReconnectOps{
		// Resolve configBuilder at execution time: API calls can arrive while
		// initialization is still completing, and the transaction waits for it.
		build: func(url string) error {
			if a.configBuilder == nil {
				return fmt.Errorf("ConfigBuilder не инициализирован")
			}
			return a.configBuilder.BuildConfig(url)
		},
		stop:    a.stopVPNForReconnect,
		start:   a.startVPNForReconnect,
		restore: a.restoreVPNSourceProfile,
	}
}

// changeVPNSubscriptionTransaction applies one subscription mutation while
// settingsPolicyMu excludes other routing/source changes. When the VPN is
// active, the method does not report success until the new configuration is
// running. Any build/start failure restores the complete previous profile and
// synchronously tries to recover the old connection.
//
// requestedURL == nil means "rebuild the currently saved subscription".
func (a *App) changeVPNSubscriptionTransaction(
	requestedURL *string,
	requireSubscription bool,
	busyMessage string,
	ops subscriptionReconnectOps,
) map[string]interface{} {
	result := map[string]interface{}{
		"success":            false,
		"wasRunning":         false,
		"restarted":          false,
		"connectionRestored": false,
		"rolledBack":         false,
		"restartCancelled":   false,
	}
	if a == nil {
		result["error"] = "VPN application is not initialized"
		return result
	}

	a.waitForInit()
	a.settingsPolicyMu.Lock()
	defer a.settingsPolicyMu.Unlock()
	// Serialize the complete stop/build/start/rollback window with public
	// lifecycle operations. Subscription downloads can be slow, but user Stop
	// still records desiredConnected=false before waiting and therefore cancels
	// the internal restart without exposing a half-written config to Start.
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()

	if a.storage == nil || a.configBuilder == nil || ops.build == nil {
		result["error"] = "ConfigBuilder не инициализирован"
		return result
	}

	a.mu.Lock()
	wasRunning := a.isRunning
	wasStarting := a.isStarting
	a.mu.Unlock()
	if wasStarting || a.reconnecting.Load() || a.vpnStopping.Load() {
		result["error"] = "Дождитесь завершения текущего подключения VPN и повторите изменение подписки"
		return result
	}
	if wasRunning && !a.desiredConnected.Load() {
		result["error"] = "VPN уже отключается; повторите изменение подписки после остановки"
		return result
	}

	profile, err := a.storage.GetActiveProfile()
	if err != nil || profile == nil {
		if err == nil {
			err = fmt.Errorf("активный профиль не найден")
		}
		result["error"] = fmt.Sprintf("Не удалось загрузить текущую подписку: %v", err)
		return result
	}
	previous, err := cloneVPNSourceProfile(profile)
	if err != nil {
		result["error"] = fmt.Sprintf("Не удалось подготовить изменение подписки: %v", err)
		return result
	}

	targetURL := previous.SubscriptionURL
	if requestedURL != nil {
		targetURL = strings.TrimSpace(*requestedURL)
	}
	if requireSubscription && strings.TrimSpace(targetURL) == "" {
		result["error"] = "Нет сохранённой подписки"
		return result
	}

	result["wasRunning"] = wasRunning
	result["connectionRestored"] = !wasRunning
	transactionGeneration := uint64(0)
	if wasRunning {
		transactionGeneration = a.beginVPNTransactionalReconnect("Применяем изменения VPN-подписки")
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
		copySubscriptionTransitionMetadata(result, stopResult)
		if !apiResultSucceeded(stopResult) {
			primary := "Не удалось остановить VPN для изменения подписки: " + apiResultMessage(stopResult)
			if a.isVPNRunning() {
				result["connectionRestored"] = true
				result["error"] = primary
				return result
			}
			recovery := a.recoverSubscriptionConnection(true, ops, result)
			if recovery != "" {
				primary += "; " + recovery
			}
			result["error"] = primary
			return result
		}
		if a.isVPNRunning() {
			result["connectionRestored"] = true
			result["error"] = "VPN не остановился; подписка не изменена"
			return result
		}
	}

	busyID := a.beginBusy(busyMessage)
	err = ops.build(targetURL)
	a.endBusy(busyID)
	if err != nil {
		rollbackErr := a.restoreVPNSourceProfileWith(previous, ops.restore)
		result["rolledBack"] = rollbackErr == nil
		recovery := rollbackRecoveryMessage(rollbackErr, wasRunning)
		if rollbackErr == nil {
			recovery = a.recoverSubscriptionConnection(wasRunning, ops, result)
		}
		result["error"] = formatVPNSourceTransactionError(
			"Не удалось обновить VPN-подписку: "+err.Error(),
			rollbackErr,
			recovery,
		)
		return result
	}

	if wasRunning {
		startResult := ops.start()
		copySubscriptionTransitionMetadata(result, startResult)
		if subscriptionReconnectCancelled(startResult) {
			// Manual disconnect is authoritative. Keep the valid subscription
			// mutation, but never recreate the session behind the user's back.
			result["success"] = true
			result["restartCancelled"] = true
			result["connectionRestored"] = true
			return a.finishSubscriptionMutationResult(result)
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
				recovery = a.recoverSubscriptionConnection(true, ops, result)
			}
			result["error"] = formatVPNSourceTransactionError(
				"Новая подписка сохранена, но VPN не переподключился: "+startError,
				rollbackErr,
				recovery,
			)
			return result
		}
		result["restarted"] = true
		result["connectionRestored"] = true
	}

	result["success"] = true
	return a.finishSubscriptionMutationResult(result)
}

func (a *App) finishSubscriptionMutationResult(result map[string]interface{}) map[string]interface{} {
	settings, err := a.storage.GetUserSettings()
	if err != nil {
		result["success"] = false
		result["error"] = "Подписка применена, но не удалось прочитать обновлённый профиль: " + err.Error()
		return result
	}
	result["proxyCount"] = settings.ProxyCount
	return result
}

func (a *App) recoverSubscriptionConnection(
	wasRunning bool,
	ops subscriptionReconnectOps,
	result map[string]interface{},
) string {
	if !wasRunning {
		result["connectionRestored"] = true
		return ""
	}
	if ops.start == nil {
		return "координатор восстановления VPN недоступен"
	}
	recoveryResult := ops.start()
	copySubscriptionTransitionMetadata(result, recoveryResult)
	if subscriptionReconnectCancelled(recoveryResult) {
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

func copySubscriptionTransitionMetadata(target, transition map[string]interface{}) {
	if target == nil || transition == nil {
		return
	}
	for _, key := range []string{"generation", "protectionHeld", "reconnectProtected"} {
		if value, ok := transition[key]; ok {
			target[key] = value
		}
	}
}

func subscriptionReconnectCancelled(result map[string]interface{}) bool {
	cancelled, _ := result["cancelled"].(bool)
	return cancelled
}
