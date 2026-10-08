package dropocore

import (
	"context"
	"sync"
	"time"
)

// RefreshAndroidSourcesForNextSession never changes the active immutable
// engine plan. Downloaded nodes are staged in private storage and applied only
// after disconnect or before a new engine starts. Manual node IDs are retained.
func RefreshAndroidSourcesForNextSession(ctx context.Context, generation int64) {
	mu.Lock()
	if !current.Connected || generation == 0 || current.sourceSession != generation || !current.Config.AutoUpdateSub {
		mu.Unlock()
		return
	}
	sources := append([]androidVPNSource(nil), current.VPNSources...)
	interval := time.Duration(current.Config.SubUpdateInterval) * time.Hour
	if interval < time.Hour {
		interval = time.Hour
	}
	mu.Unlock()
	refreshCtx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	type refreshed struct {
		nodes             []proxyConfig
		updatedAt         string
		attempted, failed bool
	}
	results := make([]refreshed, len(sources))
	var workers sync.WaitGroup
	limit := make(chan struct{}, 4)
	for i, source := range sources {
		if source.Disabled || isDirectProxyLink(source.URI) {
			continue
		}
		updatedAt := source.UpdatedAt
		if source.PendingUpdatedAt != "" {
			updatedAt = source.PendingUpdatedAt
		}
		if updated, err := time.Parse(time.RFC3339, updatedAt); err == nil && time.Since(updated) < interval {
			continue
		}
		select {
		case <-refreshCtx.Done():
			workers.Wait()
			return
		case limit <- struct{}{}:
		}
		workers.Add(1)
		go func(i int, source androidVPNSource) {
			defer workers.Done()
			defer func() { <-limit }()
			nodes, err := parseAndroidSourceContext(refreshCtx, source.URI)
			results[i] = refreshed{nodes: nodes, updatedAt: currentTimeRFC3339(), attempted: true, failed: err != nil || len(nodes) == 0}
		}(i, source)
	}
	workers.Wait()
	if refreshCtx.Err() != nil {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if ctx.Err() != nil || !current.Connected || current.sourceSession != generation || !current.Config.AutoUpdateSub {
		return
	}
	previous := current.VPNSources
	current.VPNSources = append([]androidVPNSource(nil), previous...)
	changed := false
	for i, source := range sources {
		result := results[i]
		if !result.attempted {
			continue
		}
		for n := range current.VPNSources {
			live := &current.VPNSources[n]
			if live.ID != source.ID || live.URI != source.URI || live.SelectedNodeID != source.SelectedNodeID {
				continue
			}
			changed = true
			if result.failed {
				live.LastRefreshError = "Не удалось обновить подписку. Используются сохранённые серверы."
			} else {
				live.PendingNodes, live.PendingUpdatedAt, live.LastRefreshError = result.nodes, result.updatedAt, ""
			}
		}
	}
	if !changed {
		return
	}
	if err := saveLocked(); err != nil {
		current.VPNSources = previous
		return
	}
	emitLocked("vpn-sources-changed", map[string]interface{}{})
}

func applyPendingAndroidSourceRefreshLocked() {
	changed := false
	for i := range current.VPNSources {
		source := &current.VPNSources[i]
		if len(source.PendingNodes) == 0 {
			continue
		}
		source.Nodes, source.UpdatedAt = source.PendingNodes, source.PendingUpdatedAt
		source.PendingNodes, source.PendingUpdatedAt = nil, ""
		changed = true
	}
	if changed {
		current.sourcesRevision++
		syncAndroidSubscriptionLocked()
		clearCachedConfigLocked()
	}
}
