package main

import (
	"context"
	"fmt"
	"strings"
	"time"
)

const vpnSourceHealthInterval = 30 * time.Second
const vpnResponseMaxAge = 90 * time.Second

const (
	vpnSourceStartupReadyTimeout = 5 * time.Second
	vpnSourceFailureThreshold    = 2
	vpnSourceRecoveryThreshold   = 3
	vpnSourceCircuitOpen         = 2 * time.Minute
	vpnSourceSwitchCooldown      = 20 * time.Second
	vpnSourceUnavailableMessage  = "VPN-источник не прошёл проверку. Проверьте параметры профиля или обновите VPN-подписку."
)

type vpnSourceHealthState struct {
	ConsecutiveFailures  int
	ConsecutiveSuccesses int
	OpenUntil            time.Time
}

type vpnSourceProbeBinding struct {
	ProfileID         int
	SourceID          string
	NodeID            string
	SessionGeneration uint64
}

type vpnSourceObservation struct {
	Binding   vpnSourceProbeBinding
	CheckedAt time.Time
	LatencyMS int // zero is absence, never an observed 0 ms
	Success   bool
}

// vpnResponse is presentation-only telemetry from existing source-health
// work. Reading it never probes, changes selectors, or delays connection-ready.
type vpnResponse struct {
	State             string `json:"state"`
	LatencyMS         *int   `json:"latencyMs"`
	CheckedAt         string `json:"checkedAt"`
	AgeSeconds        *int64 `json:"ageSeconds"`
	SourceID          string `json:"sourceId"`
	NodeID            string `json:"nodeId"`
	ProfileID         int    `json:"profileId"`
	SessionGeneration uint64 `json:"sessionGeneration"`
	ProbeKind         string `json:"probeKind"`
	Target            string `json:"target"`
	Error             string `json:"error"`
}

func (a *App) vpnSourceProbeBinding(tag string) (vpnSourceProbeBinding, bool) {
	if a == nil || a.storage == nil || !strings.HasPrefix(tag, "vpn-source-") {
		return vpnSourceProbeBinding{}, false
	}
	s := a.storage
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.data == nil {
		return vpnSourceProbeBinding{}, false
	}
	for _, profile := range s.data.Profiles {
		if profile.ID != s.data.App.ActiveProfileID {
			continue
		}
		outbounds, _ := profile.SingboxConfig["outbounds"].([]interface{})
		if !outboundTagExists(outbounds, tag) {
			return vpnSourceProbeBinding{}, false
		}
		for _, source := range profile.VPNSources {
			if source.Disabled || "vpn-source-"+source.ID != tag {
				continue
			}
			nodeID := source.SelectedNodeID
			if len(source.NodeIDs) > 0 {
				if source.SelectedNode < 0 || source.SelectedNode >= len(source.NodeIDs) {
					return vpnSourceProbeBinding{}, false
				}
				selectedID := source.NodeIDs[source.SelectedNode]
				if nodeID != "" && nodeID != selectedID {
					return vpnSourceProbeBinding{}, false
				}
				nodeID = selectedID
			}
			if nodeID == "" && isDirectProxyLink(source.URI) {
				if node, err := (&SubscriptionFetcher{}).ParseSingleLink(source.URI); err == nil && node.Server != "" {
					nodeID = vpnNodeFingerprint(node)
				}
			}
			if nodeID == "" {
				return vpnSourceProbeBinding{}, false
			}
			return vpnSourceProbeBinding{
				ProfileID: profile.ID, SourceID: source.ID, NodeID: nodeID,
				SessionGeneration: a.reconnectGeneration.Load(),
			}, true
		}
	}
	return vpnSourceProbeBinding{}, false
}

func (a *App) recordVPNSourceObservation(ctx context.Context, generation uint64, tag string, binding vpnSourceProbeBinding, delay int, success bool, checkedAt time.Time) bool {
	current, ok := a.vpnSourceProbeBinding(tag)
	if !ok || current != binding || ctx.Err() != nil {
		return false
	}
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if ctx.Err() != nil || a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation || binding.SessionGeneration != a.reconnectGeneration.Load() {
		return false
	}
	if a.vpnSourceObservations == nil {
		a.vpnSourceObservations = make(map[string]vpnSourceObservation)
	}
	if !success || delay <= 0 {
		delay, success = 0, false
	}
	a.vpnSourceObservations[tag] = vpnSourceObservation{
		Binding: binding, CheckedAt: checkedAt, LatencyMS: delay, Success: success,
	}
	return true
}

func (a *App) vpnResponseSnapshot(running bool, now time.Time) vpnResponse {
	result := vpnResponse{State: "unavailable", ProbeKind: "http", Target: vpnResponseProbeTarget}
	if a == nil {
		return result
	}
	result.SessionGeneration = a.reconnectGeneration.Load()
	if !running || a.vpnStopping.Load() {
		return result
	}
	a.vpnSourceMonitorMu.Lock()
	generation, tag := a.vpnSourceMonitorGeneration, a.vpnSourceActive
	monitorActive := a.vpnSourceMonitorCancel != nil
	known, available := a.vpnSourceHealthKnown, a.vpnSourceAvailable
	a.vpnSourceMonitorMu.Unlock()
	if !monitorActive {
		return result
	}
	if tag == "" {
		if len(a.configuredVPNSourceTags()) > 0 {
			result.State = "pending"
			if known && !available {
				result.State, result.Error = "failed", vpnSourceUnavailableMessage
			}
		}
		return result
	}
	binding, ok := a.vpnSourceProbeBinding(tag)
	if !ok || binding.SessionGeneration != result.SessionGeneration {
		return result
	}
	result.State = "pending"
	result.SourceID, result.NodeID, result.ProfileID = binding.SourceID, binding.NodeID, binding.ProfileID
	a.vpnSourceMonitorMu.Lock()
	observation, measured := a.vpnSourceObservations[tag]
	current := a.vpnSourceMonitorCancel != nil && a.vpnSourceMonitorGeneration == generation && a.vpnSourceActive == tag
	a.vpnSourceMonitorMu.Unlock()
	if !current || a.vpnStopping.Load() || a.reconnectGeneration.Load() != binding.SessionGeneration {
		result.State, result.SourceID, result.NodeID, result.ProfileID = "unavailable", "", "", 0
		return result
	}
	if !measured || observation.Binding != binding || observation.CheckedAt.IsZero() {
		return result
	}
	age := now.Sub(observation.CheckedAt)
	// A clock jump must not make a future sample appear newly measured.
	if age < 0 {
		return result
	}
	seconds := int64(age / time.Second)
	result.CheckedAt, result.AgeSeconds = observation.CheckedAt.UTC().Format(time.RFC3339), &seconds
	if age > vpnResponseMaxAge {
		result.State = "stale"
		return result
	}
	if observation.Success && observation.LatencyMS > 0 {
		result.State = "ok"
		latency := observation.LatencyMS
		result.LatencyMS = &latency
	} else {
		result.State, result.Error = "failed", "Последняя HTTP-проверка через VPN-источник не получила ответ."
	}
	return result
}

func nextVPNSourceHealthState(state vpnSourceHealthState, healthy bool, now time.Time) vpnSourceHealthState {
	if healthy {
		state.ConsecutiveFailures = 0
		state.ConsecutiveSuccesses++
		if !now.Before(state.OpenUntil) {
			state.OpenUntil = time.Time{}
		}
		return state
	}
	state.ConsecutiveSuccesses = 0
	state.ConsecutiveFailures++
	if state.ConsecutiveFailures >= vpnSourceFailureThreshold {
		state.OpenUntil = now.Add(vpnSourceCircuitOpen)
	}
	return state
}

func (a *App) configuredVPNSourceTags() []string {
	if a == nil || a.storage == nil {
		return nil
	}
	profile, err := a.storage.GetActiveProfile()
	if err != nil {
		return nil
	}
	config, _ := a.storage.GetProfileConfig(profile.ID)
	outbounds, _ := config["outbounds"].([]interface{})
	result := make([]string, 0, len(profile.VPNSources))
	for _, source := range profile.VPNSources {
		if source.Disabled {
			continue
		}
		tag := "vpn-source-" + source.ID
		if outboundTagExists(outbounds, tag) {
			result = append(result, tag)
		}
	}
	return result
}

func (a *App) selectFirstHealthyVPNSource(ctx context.Context, generation uint64) string {
	tags := a.configuredVPNSourceTags()
	if len(tags) == 0 {
		return ""
	}
	for _, tag := range tags {
		healthy, current := a.vpnSourceHealthy(ctx, generation, tag)
		if !current {
			return ""
		}
		if _, current = a.recordVPNSourceHealthForMonitor(generation, tag, healthy, time.Now()); !current {
			return ""
		}
		if healthy && a.switchVPNSourceForMonitor(ctx, generation, tag) {
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
			a.writeLog(fmt.Sprintf("[VPNSources] active source=%s; fallback order contains %d source(s)", tag, len(tags)))
			return tag
		}
		a.writeLog(fmt.Sprintf("[VPNSources] source %s failed its selected-node health check; trying next source", tag))
	}
	a.setVPNSourceAvailabilityForMonitor(generation, false, vpnSourceUnavailableMessage)
	a.writeLog("[VPNSources] no selected source node passed health check; service routing will use its direct/local fallback policy")
	return ""
}

func (a *App) vpnSourceHealthy(ctx context.Context, generation uint64, tag string) (bool, bool) {
	binding, hasBinding := a.vpnSourceProbeBinding(tag)
	for attempt := 0; attempt < 2; attempt++ {
		if !a.vpnSourceMonitorCurrent(ctx, generation) {
			return false, false
		}
		delay, err := a.testProxyDelayContext(ctx, tag)
		if !a.vpnSourceMonitorCurrent(ctx, generation) {
			return false, false
		}
		if err == nil && delay > 0 {
			if hasBinding {
				a.recordVPNSourceObservation(ctx, generation, tag, binding, delay, true, time.Now())
			}
			return true, true
		}
		if attempt == 0 {
			timer := time.NewTimer(300 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return false, false
			case <-timer.C:
			}
		}
	}
	if hasBinding {
		a.recordVPNSourceObservation(ctx, generation, tag, binding, 0, false, time.Now())
	}
	return false, a.vpnSourceMonitorCurrent(ctx, generation)
}

func (a *App) startVPNSourceMonitor() {
	if a == nil {
		return
	}
	a.stopVPNSourceMonitor()
	ctx, cancel := context.WithCancel(context.Background())
	a.vpnSourceMonitorMu.Lock()
	a.vpnSourceMonitorGeneration++
	generation := a.vpnSourceMonitorGeneration
	a.vpnSourceMonitorCancel = cancel
	a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	a.vpnSourceObservations = make(map[string]vpnSourceObservation)
	a.vpnSourceManual = ""
	a.vpnSourceLastSwitch = time.Time{}
	a.vpnSourceHealthKnown = false
	a.vpnSourceAvailable = false
	a.vpnSourceHealthError = ""
	a.vpnSourceMonitorMu.Unlock()
	go a.runVPNSourceMonitor(ctx, generation)
}

func (a *App) runVPNSourceMonitor(ctx context.Context, generation uint64) {
	// The process is marked running before sing-box finishes opening its Clash
	// API. Probing sooner produces a false negative even though the VLESS
	// outbound becomes usable milliseconds later. This entire wait and every
	// remote health probe stay in the background; startup readiness depends only
	// on sing-box, the immutable traffic plan and safe selector defaults.
	if len(a.configuredVPNSourceTags()) > 0 {
		readyDeadline := time.Now().Add(vpnSourceStartupReadyTimeout)
		ready := false
		for a.vpnSourceMonitorCurrent(ctx, generation) && time.Now().Before(readyDeadline) {
			if a.clashAPIPortReady(250 * time.Millisecond) {
				ready = true
				break
			}
			timer := time.NewTimer(100 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
		if !ready && a.vpnSourceMonitorCurrent(ctx, generation) {
			a.writeLog("[VPNSources] Clash API was not ready for the startup health check; background monitoring will retry")
		}
	}
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	a.selectFirstHealthyVPNSource(ctx, generation)
	ticker := time.NewTicker(vpnSourceHealthInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.checkActiveVPNSource(ctx, generation)
		}
	}
}

func (a *App) stopVPNSourceMonitor() {
	if a == nil {
		return
	}
	a.vpnSourceMonitorMu.Lock()
	cancel := a.vpnSourceMonitorCancel
	a.vpnSourceMonitorGeneration++
	a.vpnSourceMonitorCancel = nil
	a.vpnSourceActive = ""
	a.vpnSourceManual = ""
	a.vpnSourceLastSwitch = time.Time{}
	a.vpnSourceHealth = nil
	a.vpnSourceObservations = nil
	a.vpnSourceHealthKnown = false
	a.vpnSourceAvailable = false
	a.vpnSourceHealthError = ""
	a.vpnSourceMonitorMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (a *App) checkActiveVPNSource(ctx context.Context, generation uint64) {
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	tags := a.configuredVPNSourceTags()
	if len(tags) == 0 {
		return
	}
	active, current := a.activeVPNSourceForMonitor(generation)
	if !current {
		return
	}
	if active == "" {
		a.selectFirstHealthyVPNSource(ctx, generation)
		return
	}
	now := time.Now()
	healthy, current := a.vpnSourceHealthy(ctx, generation, active)
	if !current {
		return
	}
	activeState, current := a.recordVPNSourceHealthForMonitor(generation, active, healthy, now)
	if !current {
		return
	}
	if healthy {
		a.setVPNSourceAvailabilityForMonitor(generation, true, "")
		a.maybeRecoverPreferredVPNSource(ctx, generation, tags, active, now)
		return
	}
	if activeState.ConsecutiveFailures < vpnSourceFailureThreshold {
		a.writeLog(fmt.Sprintf("[VPNSources] transient health failure for %s (%d/%d); keeping the active source", active, activeState.ConsecutiveFailures, vpnSourceFailureThreshold))
		return
	}
	if !a.clearManualVPNSourceForMonitor(generation, active) {
		return
	}
	start := 0
	for index, tag := range tags {
		if tag == active {
			start = index + 1
			break
		}
	}
	for offset := 0; offset < len(tags); offset++ {
		tag := tags[(start+offset)%len(tags)]
		canAttempt, current := a.vpnSourceCanAttemptForMonitor(generation, tag, now)
		if !current {
			return
		}
		if tag == active || !canAttempt {
			continue
		}
		candidateHealthy, current := a.vpnSourceHealthy(ctx, generation, tag)
		if !current {
			return
		}
		if _, current = a.recordVPNSourceHealthForMonitor(generation, tag, candidateHealthy, now); !current {
			return
		}
		if candidateHealthy && a.switchVPNSourceForMonitor(ctx, generation, tag) {
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
			a.writeLog(fmt.Sprintf("[VPNSources] failed over from %s to %s; no sibling node was selected", active, tag))
			return
		}
	}
	a.setVPNSourceAvailabilityForMonitor(generation, false, vpnSourceUnavailableMessage)
	a.writeLog(fmt.Sprintf("[VPNSources] active source %s failed and no next source is healthy", active))
}

func (a *App) maybeRecoverPreferredVPNSource(ctx context.Context, generation uint64, tags []string, active string, now time.Time) {
	activeIndex := -1
	a.vpnSourceMonitorMu.Lock()
	if a.vpnSourceMonitorGeneration != generation || a.vpnSourceMonitorCancel == nil {
		a.vpnSourceMonitorMu.Unlock()
		return
	}
	manual := a.vpnSourceManual
	lastSwitch := a.vpnSourceLastSwitch
	a.vpnSourceMonitorMu.Unlock()
	if manual != "" || now.Sub(lastSwitch) < vpnSourceSwitchCooldown {
		return
	}
	for index, tag := range tags {
		if tag == active {
			activeIndex = index
			break
		}
	}
	if activeIndex <= 0 {
		return
	}
	for _, tag := range tags[:activeIndex] {
		canAttempt, current := a.vpnSourceCanAttemptForMonitor(generation, tag, now)
		if !current {
			return
		}
		if !canAttempt {
			continue
		}
		healthy, current := a.vpnSourceHealthy(ctx, generation, tag)
		if !current {
			return
		}
		state, current := a.recordVPNSourceHealthForMonitor(generation, tag, healthy, now)
		if !current {
			return
		}
		if !healthy || state.ConsecutiveSuccesses < vpnSourceRecoveryThreshold {
			continue
		}
		if a.switchVPNSourceForMonitor(ctx, generation, tag) {
			a.writeLog(fmt.Sprintf("[VPNSources] recovered preferred source %s after %d consecutive successful checks", tag, state.ConsecutiveSuccesses))
		}
		return
	}
}

func (a *App) vpnSourceMonitorCurrent(ctx context.Context, generation uint64) bool {
	if a == nil || ctx == nil || ctx.Err() != nil {
		return false
	}
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	return a.vpnSourceMonitorCancel != nil && a.vpnSourceMonitorGeneration == generation
}

func (a *App) activeVPNSourceForMonitor(generation uint64) (string, bool) {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation {
		return "", false
	}
	return a.vpnSourceActive, true
}

func (a *App) recordVPNSourceHealthForMonitor(generation uint64, tag string, healthy bool, now time.Time) (vpnSourceHealthState, bool) {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation || a.vpnSourceHealth == nil {
		return vpnSourceHealthState{}, false
	}
	state := nextVPNSourceHealthState(a.vpnSourceHealth[tag], healthy, now)
	a.vpnSourceHealth[tag] = state
	return state, true
}

func (a *App) setVPNSourceAvailabilityForMonitor(generation uint64, available bool, message string) bool {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation {
		return false
	}
	a.vpnSourceHealthKnown = true
	a.vpnSourceAvailable = available
	if available {
		message = ""
	}
	a.vpnSourceHealthError = message
	return true
}

func (a *App) vpnSourceAvailabilitySnapshot() (known bool, available bool, message string) {
	if a == nil {
		return false, false, ""
	}
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	return a.vpnSourceHealthKnown, a.vpnSourceAvailable, a.vpnSourceHealthError
}

func fullVPNSourceFailure(running bool, routingMode RoutingMode, healthKnown, sourceAvailable bool, message string) (bool, string) {
	if !running || NormalizeRoutingMode(routingMode) != RoutingModeAllTraffic || !healthKnown || sourceAvailable {
		return false, ""
	}
	if message == "" {
		message = vpnSourceUnavailableMessage
	}
	return true, message
}

func (a *App) vpnSourceCanAttemptForMonitor(generation uint64, tag string, now time.Time) (bool, bool) {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation {
		return false, false
	}
	return !now.Before(a.vpnSourceHealth[tag].OpenUntil), true
}

func (a *App) clearManualVPNSourceForMonitor(generation uint64, tag string) bool {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation {
		return false
	}
	if a.vpnSourceManual == tag {
		a.vpnSourceManual = ""
	}
	return true
}

func (a *App) switchVPNSourceForMonitor(ctx context.Context, generation uint64, tag string) bool {
	if !a.vpnSourceMonitorCurrent(ctx, generation) || !a.switchOutboundSelectorContext(ctx, "auto-select", tag) {
		return false
	}
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if ctx.Err() != nil || a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation {
		return false
	}
	a.vpnSourceActive = tag
	a.vpnSourceLastSwitch = time.Now()
	return true
}

func (a *App) recordVPNSourceHealth(tag string, healthy bool, now time.Time) vpnSourceHealthState {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	if a.vpnSourceHealth == nil {
		a.vpnSourceHealth = make(map[string]vpnSourceHealthState)
	}
	state := nextVPNSourceHealthState(a.vpnSourceHealth[tag], healthy, now)
	a.vpnSourceHealth[tag] = state
	return state
}

func (a *App) vpnSourceCanAttempt(tag string, now time.Time) bool {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	return !now.Before(a.vpnSourceHealth[tag].OpenUntil)
}

func (a *App) activateVPNSource(tag string, manual bool) {
	a.vpnSourceMonitorMu.Lock()
	if manual || a.vpnSourceActive != tag {
		// A user-selected source must wait for its own next monitor observation;
		// an old candidate sample is not proof of this new active selection.
		a.vpnSourceObservations = make(map[string]vpnSourceObservation)
	}
	a.vpnSourceActive = tag
	a.vpnSourceLastSwitch = time.Now()
	if manual {
		a.vpnSourceManual = tag
	}
	a.vpnSourceMonitorMu.Unlock()
}

func (a *App) clearManualVPNSource(tag string) {
	a.vpnSourceMonitorMu.Lock()
	if a.vpnSourceManual == tag {
		a.vpnSourceManual = ""
	}
	a.vpnSourceMonitorMu.Unlock()
}

func (a *App) activeVPNSource() string {
	a.vpnSourceMonitorMu.Lock()
	defer a.vpnSourceMonitorMu.Unlock()
	return a.vpnSourceActive
}

func (a *App) SelectVPNSource(id string) map[string]interface{} {
	tag := "vpn-source-" + normalizeVPNSourceID(id)
	found := false
	for _, candidate := range a.configuredVPNSourceTags() {
		if candidate == tag {
			found = true
			break
		}
	}
	if !found {
		return map[string]interface{}{"success": false, "error": "VPN source is unavailable"}
	}
	if !a.switchOutboundSelector("auto-select", tag) {
		return map[string]interface{}{"success": false, "error": "failed to switch VPN source"}
	}
	a.activateVPNSource(tag, true)
	return map[string]interface{}{"success": true, "source": id}
}
