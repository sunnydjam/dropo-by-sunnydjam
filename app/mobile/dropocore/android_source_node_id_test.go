package dropocore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAndroidSourceNodeByIDAfterStopAppliesPendingReorder(t *testing.T) {
	resetSourceTest(t)
	a := proxyConfig{Type: "vless", Server: "first.example", ServerPort: 443, UUID: "first", Security: "tls"}
	b := proxyConfig{Type: "vless", Server: "chosen.example", ServerPort: 443, UUID: "chosen", Security: "tls"}
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{a, b}, nil }
	sourceSuccess(t, "AddVPNSource", "Subscription", "https://example.com/list")
	chosenID := androidNodeID(b) // UI captures this before confirmation/Stop.
	SetConnected(true)
	mu.Lock()
	current.VPNSources[0].PendingNodes = []proxyConfig{b, a}
	current.VPNSources[0].PendingUpdatedAt = currentTimeRFC3339()
	mu.Unlock()
	if sourceCall(t, "SetVPNSourceNodeByID", "source-1", chosenID)["success"] == true {
		t.Fatal("routing selection mutated during a live VPN session")
	}
	SetConnected(false)
	sourceSuccess(t, "SetVPNSourceNodeByID", "source-1", chosenID)
	mu.Lock()
	if current.VPNSources[0].SelectedNodeID != chosenID || androidSelectedNode(current.VPNSources[0]) != 0 {
		mu.Unlock()
		t.Fatal("pending provider reorder selected a sibling at the old UI index")
	}
	base := current.BasePath
	current = defaultState()
	mu.Unlock()
	EnsureStarted(base, "test")
	if current.VPNSources[0].SelectedNodeID != chosenID || androidSelectedNode(current.VPNSources[0]) != 0 {
		t.Fatal("stable server selection was not persisted")
	}
}

func TestAndroidSourceNodeByIDRejectsDisappearedPendingServer(t *testing.T) {
	resetSourceTest(t)
	a := proxyConfig{Type: "vless", Server: "first.example", ServerPort: 443, UUID: "first", Security: "tls"}
	b := proxyConfig{Type: "vless", Server: "gone.example", ServerPort: 443, UUID: "gone", Security: "tls"}
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{a, b}, nil }
	sourceSuccess(t, "AddVPNSource", "Subscription", "https://example.com/list")
	SetConnected(true)
	mu.Lock()
	current.VPNSources[0].PendingNodes = []proxyConfig{a}
	mu.Unlock()
	SetConnected(false)
	before, _ := json.Marshal(current.VPNSources)
	revision := current.sourcesRevision
	for _, args := range [][]interface{}{{"source-1", androidNodeID(b)}, {"source-1", "invalid"}, {"source-1", false}, {"source-1", androidNodeID(a), "extra"}, {"missing", androidNodeID(a)}} {
		if sourceCall(t, "SetVPNSourceNodeByID", args...)["success"] == true {
			t.Fatal("missing/invalid stable server choice was accepted")
		}
	}
	after, _ := json.Marshal(current.VPNSources)
	if string(after) != string(before) || current.sourcesRevision != revision {
		t.Fatal("rejected server selection changed the source or selected a sibling")
	}
}

func TestAndroidSourceNodeByIDRollsBackSaveFailure(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Source", sourceTestKey)
	before, _ := json.Marshal(current.VPNSources)
	revision := current.sourcesRevision
	current.BasePath = t.TempDir()
	if err := os.Mkdir(filepath.Join(current.BasePath, stateFileName), 0700); err != nil {
		t.Fatal(err)
	}
	if sourceCall(t, "SetVPNSourceNodeByID", "source-1", androidNodeID(current.VPNSources[0].Nodes[0]))["success"] == true {
		t.Fatal("failed persistence reported success")
	}
	after, _ := json.Marshal(current.VPNSources)
	if string(after) != string(before) || current.sourcesRevision != revision {
		t.Fatal("failed persistence changed server selection")
	}
}
