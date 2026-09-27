package main

import (
	"context"
	"sort"
	"sync"
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
	type sample struct {
		tag   string
		delay int
	}
	jobs := make(chan string)
	results := make(chan sample, len(tags))
	var workers sync.WaitGroup
	for i := 0; i < min(vpnSourceProbeWorkers, len(tags)); i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for tag := range jobs {
				if probeCtx.Err() != nil {
					return
				}
				binding, valid := a.vpnSourceProbeBinding(tag)
				if !valid {
					continue
				}
				delay, err := a.testProxyDelayContext(probeCtx, tag)
				if probeCtx.Err() != nil {
					return // A cancelled sample is not evidence of source failure.
				}
				healthy := err == nil && delay > 0
				if !a.recordVPNSourceObservation(probeCtx, generation, tag, binding, delay, healthy, time.Now()) {
					continue
				}
				a.recordVPNSourceHealthForMonitor(generation, tag, healthy, time.Now())
				if healthy {
					results <- sample{tag, delay}
				}
			}
		}()
	}
dispatch:
	for _, tag := range tags {
		select {
		case <-probeCtx.Done():
			break dispatch
		case jobs <- tag:
		}
	}
	close(jobs)
	workers.Wait()
	close(results)
	if !a.vpnSourceMonitorCurrent(ctx, generation) {
		return
	}
	delays := make(map[string]int)
	for result := range results {
		delays[result.tag] = result.delay
	}
	ranked := rankVPNSourceLatencies(tags, delays)
	a.vpnSourceMonitorMu.Lock()
	if a.vpnSourceMonitorCancel == nil || a.vpnSourceMonitorGeneration != generation || a.vpnSourceManual != "" {
		a.vpnSourceMonitorMu.Unlock()
		return
	}
	a.vpnSourceRankedTags = ranked
	a.vpnSourceMonitorMu.Unlock()
	switchCtx, stopSwitch := context.WithTimeout(ctx, 5*time.Second)
	defer stopSwitch()
	for _, tag := range ranked {
		if switchCtx.Err() != nil {
			break
		}
		if delays[tag] > 0 && a.switchVPNSourceForMonitor(switchCtx, generation, tag) {
			a.setVPNSourceAvailabilityForMonitor(generation, true, "")
			a.writeLog("[VPNSources] selected lowest measured HTTP latency between independent sources; keeping healthy session stable")
			return
		}
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
