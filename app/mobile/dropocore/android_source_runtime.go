package dropocore

import (
	"context"
	"dropocore/sourcehistory"
	"encoding/json"
	"sync/atomic"
	"time"
)

// A prepared candidate always represents one independent source and exactly
// its authoritative node. No credentials or remote endpoints cross this API.
type androidSourceCandidate struct {
	Preferred bool   `json:"preferred,omitempty"`
	ID        string `json:"id"`
	Tag       string `json:"tag"`
	NodeID    string `json:"nodeId"`
	OwnerID   string `json:"ownerId,omitempty"`
}

func androidLogicalSourceStatusLocked(id string) (bool, androidSourceResponse) {
	response := androidSourceResponseLocked(id)
	if !current.Connected {
		return false, response
	}
	if current.activeSourceID == id {
		return true, response
	}
	for _, candidate := range current.preparedSources {
		if candidate.OwnerID != id || candidate.ID == id {
			continue
		}
		sample := androidSourceResponseLocked(candidate.ID)
		sample.SourceID, sample.NodeID = id, ""
		if candidate.ID == current.activeSourceID {
			return true, sample
		}
		if response.State != "ok" && sample.State == "ok" {
			response = sample
		}
	}
	return false, response
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
	current.adaptiveActive = nil
	current.activeSourceID = ""
	current.sourceResponses = nil
	if androidBuildCancel != nil {
		androidBuildCancel()
		androidBuildCancel = nil
	}
}

func BeginAndroidSourceSession() string {
	return BeginAndroidSourceSessionWithActive("")
}

// The TUN is available for health checks before the user-visible session is connected.
func androidSourceEngineActiveLocked() bool {
	return !current.sourceWorkCancelled && (current.Connected || current.ServiceState == "starting")
}

func BeginAndroidSourceSessionWithActive(activeID string) string {
	mu.Lock()
	defer mu.Unlock()
	if !androidSourceEngineActiveLocked() || len(current.preparedSources) == 0 {
		return androidSourceError("VPN-источники ещё не готовы к проверке.")
	}
	current.sourceSession = androidSourceGeneration.Add(1)
	current.adaptiveActive = nil
	current.activeSourceID = current.preparedSources[0].ID
	current.sourceResponses = make(map[string]androidSourceResponse, len(current.preparedSources))
	for _, candidate := range current.preparedSources {
		if candidate.ID == activeID {
			current.activeSourceID = activeID
		}
		current.sourceResponses[candidate.ID] = androidSourceResponse{State: "pending", SourceID: candidate.ID,
			NodeID: candidate.NodeID, SessionGeneration: current.sourceSession}
	}
	return encode(map[string]interface{}{"success": true, "generation": current.sourceSession,
		"autoSelect": current.VPNSourceAutoSelect, "candidates": current.preparedSources, "activeId": current.activeSourceID})
}

func ActiveAndroidSource() (id, tag string) {
	mu.Lock()
	defer mu.Unlock()
	for _, candidate := range current.preparedSources {
		if candidate.ID == current.activeSourceID {
			return candidate.ID, candidate.Tag
		}
	}
	return "", ""
}

func EndAndroidSourceSession(generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if current.sourceSession != generation {
		return
	}
	androidVPNCheck.client = nil
	androidVPNCheck.session = nil
	androidVPNCheck.generation = 0
	current.sourceSession = 0
	current.adaptiveActive = nil
	current.activeSourceID = ""
	current.sourceResponses = nil
}

func AndroidSourceSessionCurrent(generation int64) bool {
	mu.Lock()
	defer mu.Unlock()
	return generation > 0 && current.sourceSession == generation && androidSourceEngineActiveLocked()
}

func InvalidateAndroidSourceObservations(generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if generation == 0 || current.sourceSession != generation || !androidSourceEngineActiveLocked() {
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
	if json.Unmarshal([]byte(observationsJSON), &observations) != nil || len(observations) > maxAndroidRuntimeSourceCandidates {
		return false
	}
	mu.Lock()
	defer mu.Unlock()
	if !androidSourceEngineActiveLocked() || generation <= 0 || generation != current.sourceSession {
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

// Validate cached IDs against currently prepared nodes, including entitlement.
func PreferredAndroidNetworkSource(network string, generation int64) string {
	mu.Lock()
	defer mu.Unlock()
	if generation <= 0 || current.sourceSession != generation {
		return ""
	}
	e := current.SourceHistory.Last(network)
	for _, c := range current.preparedSources {
		if c.ID == e.Source && c.NodeID == e.Node {
			return c.ID
		}
	}
	return ""
}
func RememberAndroidNetworkSource(network string, generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if network == "" || generation <= 0 || current.sourceSession != generation {
		return
	}
	r := current.sourceResponses[current.activeSourceID]
	if r.State != "ok" || r.NodeID == "" {
		return
	}
	e := sourcehistory.Entry{Network: network, Source: current.activeSourceID, Node: r.NodeID}
	if current.SourceHistory.Last(network) != e {
		current.SourceHistory = current.SourceHistory.With(e)
		_ = saveLocked()
	}
}
