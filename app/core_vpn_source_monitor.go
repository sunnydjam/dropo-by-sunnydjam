package main

import (
	"context"
	"fmt"
	"time"
)

const vpnSourceHealthInterval = 30 * time.Second

const (
	vpnSourceStartupReadyTimeout = 5 * time.Second
	vpnSourceFailureThreshold    = 2
	vpnSourceRecoveryThreshold   = 3
	vpnSourceCircuitOpen         = 2 * time.Minute
	vpnSourceSwitchCooldown      = 20 * time.Second
)

type vpnSourceHealthState struct {
	ConsecutiveFailures  int
	ConsecutiveSuccesses int
	OpenUntil            time.Time
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
			a.writeLog(fmt.Sprintf("[VPNSources] active source=%s; fallback order contains %d source(s)", tag, len(tags)))
			return tag
		}
		a.writeLog(fmt.Sprintf("[VPNSources] source %s failed its selected-node health check; trying next source", tag))
	}
	a.writeLog("[VPNSources] no selected source node passed health check; service routing will use its direct/local fallback policy")
	return ""
}

func (a *App) vpnSourceHealthy(ctx context.Context, generation uint64, tag string) (bool, bool) {
	for attempt := 0; attempt < 2; attempt++ {
		if !a.vpnSourceMonitorCurrent(ctx, generation) {
			return false, false
		}
		result := a.TestProxyDelay(tag)
		if !a.vpnSourceMonitorCurrent(ctx, generation) {
			return false, false
		}
		if success, _ := result["success"].(bool); success {
			if delay, _ := result["delay"].(int); delay > 0 {
				return true, true
			}
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
	a.vpnSourceManual = ""
	a.vpnSourceLastSwitch = time.Time{}
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
			a.writeLog(fmt.Sprintf("[VPNSources] failed over from %s to %s; no sibling node was selected", active, tag))
			return
		}
	}
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
