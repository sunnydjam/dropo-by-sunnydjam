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
	if !a.automaticVPNSourceSelection() {
		a.selectFirstHealthyVPNSource(ctx, generation)
		return
	}
	tags := a.configuredVPNSourceTags()
	if len(tags) == 0 || !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	// The safe bootstrap selector is already usable. Bound the entire background
	// comparison and its concurrency, even when a user imports many sources.
	probeCtx, cancel := context.WithTimeout(ctx, vpnSourceSelectionBudget)
	defer cancel()
	network := vpnSourceNetworkKey()
	if profile, err := a.storage.GetActiveProfile(); err == nil {
		last := profile.SourceHistory.Last(network)
		i := slices.Index(tags, last.Source)
		if i > 0 {
			if binding, ok := a.vpnSourceProbeBinding(tags[i]); ok && binding.NodeID == last.Node {
				copy(tags[1:i+1], tags[:i])
				tags[0] = last.Source
			}
		}
	}
	delays := map[string]int{}
	winner := ""
	sourcehistory.Race(probeCtx, tags, vpnSourceProbeWorkers, func(pctx context.Context, tag string) int {
		binding, valid := a.vpnSourceProbeBinding(tag)
		if !valid {
			return 0
		}
		delay, target, err := a.testProxyDelayWithTargetContext(pctx, tag)
		healthy := err == nil && delay > 0
		if !a.recordVPNSourceObservation(pctx, generation, tag, binding, delay, healthy, time.Now(), target) {
			return 0
		}
		a.recordVPNSourceHealthForMonitor(generation, tag, healthy, time.Now())
		if !healthy {
			return 0
		}
		return delay
	}, func(tag string, delay int) {
		if delay <= 0 {
			return
		}
		delays[tag] = delay
		if winner == "" && a.switchConfirmedSource(ctx, generation, tag, true) {
			winner = tag
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
		}
	})
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	ranked := rankVPNSourceLatencies(tags, delays)
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
