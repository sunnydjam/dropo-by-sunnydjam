package main

import (
	"context"
	"dropocore/sourcehistory"
	"slices"
	"sort"
	"time"
)

const vpnSourceSelectionBudget = 15 * time.Second
const vpnSourceProbeWorkers = 3
const managedVPNSourceProbeWorkers = 6

func (a *App) automaticVPNSourceSelection() bool {
	if a.storage == nil {
		return false
	}
	profile, err := a.storage.GetActiveProfile()
	return err == nil && profile.VPNSourceSelectionMode != "priority"
}

// Only independent source selector tags enter the ranking. Sibling nodes never
// enter this list. Unknown/failed samples remain at the end in saved order.
func rankVPNSourceLatencies(tags []string, delays map[string]int) []string {
	ranked := append([]string(nil), tags...)
	sort.SliceStable(ranked, func(i, j int) bool {
		left, right := delays[ranked[i]], delays[ranked[j]]
		return left > 0 && (right <= 0 || left < right)
	})
	return ranked
}

func (a *App) sessionVPNSourceTags() []string {
	tags := a.configuredVPNSourceTags()
	a.vpnSourceMonitorMu.Lock()
	order := append([]string(nil), a.vpnSourceRankedTags...)
	a.vpnSourceMonitorMu.Unlock()
	positions := make(map[string]int, len(order))
	for i, tag := range order {
		positions[tag] = i
	}
	sort.SliceStable(tags, func(i, j int) bool {
		left, hasLeft := positions[tags[i]]
		right, hasRight := positions[tags[j]]
		return hasLeft && (!hasRight || left < right)
	})
	return tags
}

func (a *App) selectInitialVPNSource(ctx context.Context, generation uint64) {
	groups := a.configuredVPNSourceTagGroups()
	if slices.ContainsFunc(groups, func(group []string) bool { return len(group) > 1 }) {
		a.selectManagedSourcesInitially(ctx, generation, groups)
		return
	}
	if !a.automaticVPNSourceSelection() {
		a.selectFirstHealthyVPNSource(ctx, generation)
		return
	}
	if len(groups) == 0 || !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	// The safe bootstrap selector is already usable. Bound the entire background
	// comparison and its concurrency, even when a user imports many sources.
	probeCtx, cancel := context.WithTimeout(ctx, vpnSourceSelectionBudget)
	defer cancel()
	network := vpnSourceNetworkKey()
	if profile, err := a.storage.GetActiveProfile(); err == nil {
		last := profile.SourceHistory.Last(network)
		if binding, ok := a.vpnSourceProbeBinding(last.Source); ok && binding.NodeID == last.Node {
			i := slices.IndexFunc(groups, func(group []string) bool { return slices.Contains(group, last.Source) })
			if i > 0 {
				group := groups[i]
				copy(groups[1:i+1], groups[:i])
				groups[0] = group
			}
		}
	}
	type response struct {
		tag   string
		delay int
	}
	delays := map[string]int{}
	winner := ""
	sourcehistory.Race(probeCtx, groups, vpnSourceProbeWorkers, func(pctx context.Context, group []string) response {
		for _, tag := range group {
			if delay := a.initialVPNSourceDelay(pctx, generation, tag); delay > 0 {
				return response{tag, delay}
			}
			if pctx.Err() != nil {
				break
			}
		}
		return response{}
	}, func(_ []string, result response) {
		if result.delay <= 0 {
			return
		}
		delays[result.tag] = result.delay
		if winner == "" && a.switchConfirmedSource(ctx, generation, result.tag, true) {
			winner = result.tag
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
		}
	})
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	ranked := rankVPNSourceLatencies(a.configuredVPNSourceTags(), delays)
	a.vpnSourceMonitorMu.Lock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation || a.vpnSourceManual != "" {
		a.vpnSourceMonitorMu.Unlock()
		return
	}
	a.vpnSourceRankedTags = ranked
	a.vpnSourceMonitorMu.Unlock()
	if winner != "" {
		return
	}
	// Do not turn an incomplete comparison into a confirmed network failure.
	if probeCtx.Err() == nil {
		a.vpnSourceMonitorMu.Lock()
		if a.vpnSourceMonitorCancel != nil && a.vpnSourceMonitorGeneration == generation && a.vpnSourceManual == "" {
			a.vpnSourceHealthKnown = true
			a.vpnSourceAvailable = false
			a.vpnSourceHealthError = vpnSourceUnavailableMessage
		}
		a.vpnSourceMonitorMu.Unlock()
	}
}

func (a *App) selectManagedSourcesInitially(ctx context.Context, generation uint64, groups [][]string) {
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	var tags []string
	for _, group := range groups {
		tags = append(tags, group...)
	}
	probeCtx, cancel := context.WithTimeout(ctx, vpnSourceSelectionBudget)
	defer cancel()
	delays := make(map[string]int, len(tags))
	sourcehistory.Race(probeCtx, tags, managedVPNSourceProbeWorkers, func(probeCtx context.Context, tag string) int {
		return a.initialVPNSourceDelay(probeCtx, generation, tag)
	}, func(tag string, delay int) { delays[tag] = delay })

	var ranked []string
	if a.automaticVPNSourceSelection() {
		ranked = rankVPNSourceLatencies(tags, delays)
	} else {
		for _, group := range groups {
			ranked = append(ranked, rankVPNSourceLatencies(group, delays)...)
		}
	}
	a.vpnSourceMonitorMu.Lock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation || a.vpnSourceManual != "" {
		a.vpnSourceMonitorMu.Unlock()
		return
	}
	a.vpnSourceRankedTags = ranked
	a.vpnSourceMonitorMu.Unlock()
	for _, tag := range ranked {
		if delays[tag] > 0 && a.switchConfirmedSource(ctx, generation, tag, true) {
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
			return
		}
	}
	a.setVPNSourceAvailabilityForMonitor(generation, false, vpnSourceUnavailableMessage)
}

func (a *App) initialVPNSourceDelay(ctx context.Context, generation uint64, tag string) int {
	binding, ok := a.vpnSourceProbeBinding(tag)
	if !ok {
		return 0
	}
	delay, target, err := a.testProxyDelayWithTargetContext(ctx, tag)
	healthy := err == nil && delay > 0
	now := time.Now()
	if !a.recordVPNSourceObservation(ctx, generation, tag, binding, delay, healthy, now, target) {
		return 0
	}
	a.recordVPNSourceHealthForMonitor(generation, tag, healthy, now)
	if !healthy {
		return 0
	}
	return delay
}
