package dropoandroid

import (
	"slices"

	"github.com/gofrs/uuid/v5"
	"github.com/sagernet/sing-box/common/trafficcontrol"
)

const (
	maxSourceFlowSnapshot = 4096
	maxSourceFlowCloses   = 512
)

// Only the current instance's public traffic API is used. The selector still
// preserves healthy existing connections during initial latency selection.
type sourceFlowTable interface {
	ConnectionsLen() int
	Connections() []*trafficcontrol.TrackerMetadata
	Connection(uuid.UUID) trafficcontrol.Tracker
}

// confirmed is populated only after two failed active-source checks. Require
// the following full batch to still report that exact node failed and a
// different prepared source healthy; a transient recovery must not kill flows.
func confirmedOutageSourceTag(confirmed sourceCandidate, candidates []sourceCandidate, results []sourceObservation, selectedID string) string {
	if confirmed.ID == "" || confirmed.Tag == "" || selectedID == "" || selectedID == confirmed.ID {
		return ""
	}
	var activeFailed, replacementHealthy bool
	for _, candidate := range candidates {
		for _, result := range results {
			if result.SourceID != candidate.ID || result.NodeID != candidate.NodeID {
				continue
			}
			if candidate == confirmed && result.State == "failed" {
				activeFailed = true
			}
			if candidate.ID == selectedID && candidate.Tag != confirmed.Tag && result.State == "ok" && result.LatencyMS > 0 {
				replacementHealthy = true
			}
		}
	}
	if activeFailed && replacementHealthy {
		return confirmed.Tag
	}
	return ""
}

func commitSourceAndCleanup(current func() bool, commit func() bool, flows sourceFlowTable, failedTag string) bool {
	if !current() || !commit() {
		return false
	}
	if failedTag != "" {
		closeFailedSourceFlows(flows, failedTag, current)
	}
	return true
}

func flowUsedSource(metadata *trafficcontrol.TrackerMetadata, tag string) bool {
	return metadata != nil && metadata.ID != uuid.Nil && tag != "" && tag != "direct" && tag != "proxy" &&
		len(metadata.Chain) <= 32 && slices.Contains(metadata.Chain, tag)
}

func closeFailedSourceFlows(flows sourceFlowTable, failedTag string, current func() bool) int {
	if flows == nil || !current() || flows.ConnectionsLen() > maxSourceFlowSnapshot {
		return 0
	}
	// The upstream API returns a snapshot. Refuse an oversized table before
	// requesting it, and cap again for connections opened during that request.
	snapshot := flows.Connections()
	if len(snapshot) > maxSourceFlowSnapshot {
		snapshot = snapshot[:maxSourceFlowSnapshot]
	}
	seen := make(map[uuid.UUID]bool)
	closed := 0
	for _, metadata := range snapshot {
		if !current() || closed == maxSourceFlowCloses {
			break
		}
		if !flowUsedSource(metadata, failedTag) || seen[metadata.ID] {
			continue
		}
		seen[metadata.ID] = true
		tracker := flows.Connection(metadata.ID)
		// A snapshot entry may already have finished. Recheck the live tracker
		// and exact chain before closing; direct and other sources stay intact.
		if tracker == nil || !flowUsedSource(tracker.Metadata(), failedTag) || tracker.Metadata().ID != metadata.ID || !current() {
			continue
		}
		_ = tracker.Close()
		closed++
	}
	return closed
}
