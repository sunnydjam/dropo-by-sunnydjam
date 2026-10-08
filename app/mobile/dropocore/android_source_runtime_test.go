package dropocore

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type testSourceSelector struct {
	selected []string
	reject   bool
}

func (s *testSourceSelector) SelectSourceTag(tag string) bool {
	if s.reject {
		return false
	}
	s.selected = append(s.selected, tag)
	return true
}

func preparedSourceSession(t *testing.T) int64 {
	t.Helper()
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "One", sourceTestKey)
	sourceSuccess(t, "AddVPNSource", "Two", strings.Replace(sourceTestKey, "example.com", "second.example.com", 1))
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("pool build failed")
	}
	SetConnected(true)
	var plan struct {
		Generation int64 `json:"generation"`
	}
	if err := json.Unmarshal([]byte(BeginAndroidSourceSession()), &plan); err != nil || plan.Generation < 1 {
		t.Fatal("session not started")
	}
	return plan.Generation
}

func sourceObservationJSON(id, nodeID string, generation int64, state string, latency int) string {
	data, _ := json.Marshal([]androidSourceResponse{{State: state, SourceID: id, NodeID: nodeID,
		SessionGeneration: generation, LatencyMS: latency, CheckedAt: time.Now().UTC().Format(time.RFC3339Nano)}})
	return string(data)
}

func TestAndroidIndependentSourcePlanBootstrapsSavedNodes(t *testing.T) {
	resetSourceTest(t)
	first := proxyConfig{Type: "vless", Server: "first.example.com", ServerPort: 443, UUID: "one", Name: "One"}
	sibling := proxyConfig{Type: "vless", Server: "forbidden-sibling.example.com", ServerPort: 443, UUID: "two", Name: "Sibling"}
	second := proxyConfig{Type: "vless", Server: "second.example.com", ServerPort: 443, UUID: "three", Name: "Second"}
	androidSourceParser = func(uri string) ([]proxyConfig, error) {
		if strings.Contains(uri, "first") {
			return []proxyConfig{first, sibling}, nil
		}
		return []proxyConfig{second}, nil
	}
	sourceSuccess(t, "AddVPNSource", "One", "https://first.example.com/sub")
	sourceSuccess(t, "AddVPNSource", "Two", "https://second.example.com/sub")
	androidSourceParser = func(string) ([]proxyConfig, error) {
		t.Fatal("connection gate downloaded saved subscription")
		return nil, nil
	}
	response := BuildSingBoxConfig()
	if !decodeSuccess(response) || strings.Contains(response, "forbidden-sibling") || !strings.Contains(response, "second.example.com") || strings.Contains(response, "urltest") {
		t.Fatalf("invalid independent pool plan: %s", response)
	}
	if len(current.preparedSources) != 2 || current.preparedSources[0].ID != "source-1" || current.preparedSources[1].ID != "source-2" {
		t.Fatalf("candidate order changed: %#v", current.preparedSources)
	}
}

func TestAndroidSourceSelectionAndObservationsAreSessionScoped(t *testing.T) {
	generation := preparedSourceSession(t)
	candidate := current.preparedSources[1]
	selector := &testSourceSelector{}
	observation := sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "ok", 35)
	if !CommitAndroidSourceProbeBatch(generation, observation, candidate.ID, selector) || len(selector.selected) != 1 {
		t.Fatal("valid measured source did not commit")
	}
	view := sourceCall(t, "GetVPNSources")
	sources := view["sources"].([]interface{})
	if sources[0].(map[string]interface{})["active"] == true || sources[1].(map[string]interface{})["active"] != true {
		t.Fatal("active view followed priority rather than actual selector")
	}
	if current.activeSourceID != candidate.ID || androidSourceResponseLocked(candidate.ID).LatencyMS != 35 {
		t.Fatal("missing active telemetry")
	}
	CancelPendingSourceWork()
	if CommitAndroidSourceProbeBatch(generation, observation, candidate.ID, selector) || len(selector.selected) != 1 {
		t.Fatal("cancelled worker mutated selector")
	}
	if androidSourceResponseLocked(candidate.ID).State != "unavailable" {
		t.Fatal("stale telemetry survived cancellation")
	}
	var newPlan struct {
		Generation int64 `json:"generation"`
	}
	_ = json.Unmarshal([]byte(BeginAndroidSourceSession()), &newPlan)
	if newPlan.Generation == generation {
		t.Fatal("generation reused")
	}
	if CommitAndroidSourceProbeBatch(generation, observation, candidate.ID, selector) {
		t.Fatal("prior-session result committed to new session")
	}
	SetConnected(false)
	if AndroidSourceSessionCurrent(newPlan.Generation) {
		t.Fatal("disconnected session remains current")
	}
}

func TestAndroidSourceDoesNotCommitPartialOrWrongNodeHealth(t *testing.T) {
	generation := preparedSourceSession(t)
	candidate := current.preparedSources[1]
	selector := &testSourceSelector{}
	for _, observation := range []string{
		sourceObservationJSON(candidate.ID, "wrong-node", generation, "ok", 1),
		sourceObservationJSON("unknown-source", candidate.NodeID, generation, "ok", 1),
		sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "pending", 1),
		sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "ok", 0),
		sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "failed", 1),
	} {
		if CommitAndroidSourceProbeBatch(generation, observation, candidate.ID, selector) {
			t.Fatal("unhealthy or mismatched candidate committed")
		}
	}
	if len(selector.selected) != 0 || current.activeSourceID != "source-1" {
		t.Fatal("invalid observations changed active source")
	}
	failed := sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "failed", 42)
	if !CommitAndroidSourceProbeBatch(generation, failed, "", selector) || androidSourceResponseLocked(candidate.ID).LatencyMS != 0 {
		t.Fatal("failed probe produced fabricated latency")
	}
	valid := sourceObservationJSON(candidate.ID, candidate.NodeID, generation, "ok", 42)
	selector.reject = true
	if CommitAndroidSourceProbeBatch(generation, valid, candidate.ID, selector) || current.activeSourceID != "source-1" {
		t.Fatal("failed selector change reported active")
	}
}

func TestAndroidSourceAutoChoicePersistsAndManualOrderDisablesIt(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "One", sourceTestKey)
	sourceSuccess(t, "MoveVPNSource", "source-1", 0)
	if current.VPNSourceAutoSelect {
		t.Fatal("manual move did not disable automatic choice")
	}
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	if current.VPNSourceAutoSelect {
		t.Fatal("manual preference not persisted")
	}
	sourceSuccess(t, "EnableVPNSourceAutoSelect")
	SetConnected(true)
	if decodeSuccess(Call("EnableVPNSourceAutoSelect", "[]")) {
		t.Fatal("source mode changed during live session")
	}
	if !current.VPNSourceAutoSelect {
		t.Fatal("rejected mutation changed preference")
	}
}

func TestAndroidCancelledBuildCannotRegisterAfterStop(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "One", sourceTestKey)
	CancelPendingSourceWork()
	if decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("a build registered after Stop and prepared an engine")
	}
	if len(current.preparedSources) != 0 {
		t.Fatal("cancelled build committed a plan")
	}
	sourceSuccess(t, "AndroidEngineStarting")
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("new fenced session did not rearm the build")
	}
}
