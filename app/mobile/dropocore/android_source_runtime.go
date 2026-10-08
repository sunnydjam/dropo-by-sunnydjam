package dropocore

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"time"
)

// A prepared candidate always represents one independent source and exactly
// its authoritative node. No credentials or remote endpoints cross this API.
type androidSourceCandidate struct {
	ID     string `json:"id"`
	Tag    string `json:"tag"`
	NodeID string `json:"nodeId"`
}

type androidSourceResponse struct {
	State             string `json:"state"`
	LatencyMS         int    `json:"latencyMs,omitempty"`
	CheckedAt         string `json:"checkedAt,omitempty"`
	SourceID          string `json:"sourceId,omitempty"`
	NodeID            string `json:"nodeId,omitempty"`
	Target            string `json:"target,omitempty"`
	SessionGeneration int64  `json:"sessionGeneration,omitempty"`
}

var androidSourceGeneration atomic.Int64
var androidBuildCancel context.CancelFunc

// AndroidSourceSelector performs only an in-memory, non-blocking selector
// change. Holding the state lock across it fences Stop and observation commits.
type AndroidSourceSelector interface {
	SelectSourceTag(tag string) bool
}

// CancelPendingSourceWork invalidates unfinished builds immediately. Kotlin
// also fences creation of the engine/TUN while provider HTTP calls unwind.
func CancelPendingSourceWork() {
	mu.Lock()
	defer mu.Unlock()
	current.sourcesRevision++
	current.sourceWorkCancelled = true
	current.sourceSession = 0
	current.activeSourceID = ""
	current.sourceResponses = nil
	if androidBuildCancel != nil {
		androidBuildCancel()
		androidBuildCancel = nil
	}
}

func BeginAndroidSourceSession() string {
	mu.Lock()
	defer mu.Unlock()
	if !current.Connected || len(current.preparedSources) == 0 {
		return androidSourceError("VPN-источники ещё не готовы к проверке.")
	}
	current.sourceSession = androidSourceGeneration.Add(1)
	current.activeSourceID = current.preparedSources[0].ID
	current.sourceResponses = make(map[string]androidSourceResponse, len(current.preparedSources))
	for _, candidate := range current.preparedSources {
		current.sourceResponses[candidate.ID] = androidSourceResponse{State: "pending", SourceID: candidate.ID,
			NodeID: candidate.NodeID, SessionGeneration: current.sourceSession}
	}
	return encode(map[string]interface{}{"success": true, "generation": current.sourceSession,
		"autoSelect": current.VPNSourceAutoSelect, "candidates": current.preparedSources})
}

func EndAndroidSourceSession(generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if current.sourceSession != generation {
		return
	}
	current.sourceSession = 0
	current.activeSourceID = ""
	current.sourceResponses = nil
}

func AndroidSourceSessionCurrent(generation int64) bool {
	mu.Lock()
	defer mu.Unlock()
	return generation > 0 && current.sourceSession == generation && current.Connected
}

func InvalidateAndroidSourceObservations(generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if generation == 0 || current.sourceSession != generation || !current.Connected {
		return
	}
	for _, candidate := range current.preparedSources {
		current.sourceResponses[candidate.ID] = androidSourceResponse{State: "pending", SourceID: candidate.ID,
			NodeID: candidate.NodeID, SessionGeneration: generation}
	}
}

// CommitAndroidSourceProbeBatch is atomic with disconnect. Results from a
// superseded session, a different node or an unprepared source cannot commit.
func CommitAndroidSourceProbeBatch(generation int64, observationsJSON, selectedID string, selector AndroidSourceSelector) bool {
	var observations []androidSourceResponse
	if json.Unmarshal([]byte(observationsJSON), &observations) != nil || len(observations) > maxAndroidVPNSources {
		return false
	}
	mu.Lock()
	defer mu.Unlock()
	if !current.Connected || generation <= 0 || generation != current.sourceSession {
		return false
	}
	candidates := make(map[string]androidSourceCandidate, len(current.preparedSources))
	for _, candidate := range current.preparedSources {
		candidates[candidate.ID] = candidate
	}
	seen := make(map[string]bool, len(observations))
	selectedHealthy := false
	now := time.Now()
	for _, result := range observations {
		candidate, ok := candidates[result.SourceID]
		checked, err := time.Parse(time.RFC3339Nano, result.CheckedAt)
		if !ok || seen[result.SourceID] || result.NodeID != candidate.NodeID ||
			result.SessionGeneration != generation || (result.State != "ok" && result.State != "failed") ||
			err != nil || checked.After(now.Add(time.Second)) || now.Sub(checked) > 90*time.Second ||
			(result.State == "ok" && (result.LatencyMS < 1 || result.LatencyMS > 15000)) {
			return false
		}
		seen[result.SourceID] = true
		if selectedID == result.SourceID && result.State == "ok" {
			selectedHealthy = true
		}
	}
	if selectedID != "" {
		candidate, ok := candidates[selectedID]
		if !ok || !selectedHealthy || selector == nil || !selector.SelectSourceTag(candidate.Tag) {
			return false
		}
		current.activeSourceID = selectedID
	}
	for _, result := range observations {
		if result.State != "ok" {
			result.LatencyMS = 0
		}
		current.sourceResponses[result.SourceID] = result
	}
	emitLocked("vpn-sources-changed", map[string]interface{}{})
	return true
}

func androidSourceResponseLocked(id string) androidSourceResponse {
	result := androidSourceResponse{State: "unavailable"}
	if !current.Connected || current.sourceSession == 0 {
		return result
	}
	result, exists := current.sourceResponses[id]
	if !exists || result.SessionGeneration != current.sourceSession {
		return androidSourceResponse{State: "unavailable"}
	}
	if result.CheckedAt != "" {
		checked, err := time.Parse(time.RFC3339Nano, result.CheckedAt)
		if err != nil || time.Since(checked) > 90*time.Second {
			result.State, result.LatencyMS = "stale", 0
		}
	}
	return result
}
