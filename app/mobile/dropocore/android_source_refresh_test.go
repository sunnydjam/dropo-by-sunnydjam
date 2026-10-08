package dropocore

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func refreshedSourceSession(t *testing.T) (int64, proxyConfig) {
	t.Helper()
	resetSourceTest(t)
	node := proxyConfig{Type: "vless", Server: "chosen.example.com", ServerPort: 443, UUID: "chosen", Name: "Chosen"}
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{node}, nil }
	sourceSuccess(t, "AddVPNSource", "VPN", "https://subscription.example.com/private")
	sourceSuccess(t, "SetVPNSourceNode", "source-1", 0)
	current.VPNSources[0].UpdatedAt = time.Now().Add(-48 * time.Hour).Format(time.RFC3339)
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("build failed")
	}
	SetConnected(true)
	var plan struct {
		Generation int64 `json:"generation"`
	}
	_ = json.Unmarshal([]byte(BeginAndroidSourceSession()), &plan)
	if plan.Generation == 0 {
		t.Fatal("session not prepared")
	}
	return plan.Generation, node
}

func TestAndroidAutomaticRefreshStagesUntilDisconnectAndRetainsManualNode(t *testing.T) {
	generation, selected := refreshedSourceSession(t)
	newNode := proxyConfig{Type: "vless", Server: "new.example.com", ServerPort: 443, UUID: "new", Name: "New"}
	selectedID, candidate := current.VPNSources[0].SelectedNodeID, current.preparedSources[0]
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{newNode, selected}, nil }
	RefreshAndroidSourcesForNextSession(context.Background(), generation)
	if len(current.VPNSources[0].Nodes) != 1 || current.VPNSources[0].Nodes[0].Server != selected.Server || len(current.VPNSources[0].PendingNodes) != 2 {
		t.Fatal("background refresh changed live source rather than staging it")
	}
	if current.VPNSources[0].SelectedNodeID != selectedID || current.preparedSources[0] != candidate {
		t.Fatal("refresh replaced manual node or live plan")
	}
	SetConnected(false)
	if len(current.VPNSources[0].PendingNodes) != 0 || androidSelectedNode(current.VPNSources[0]) != 1 {
		t.Fatal("staged update did not apply after disconnect with stable manual identity")
	}
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("updated pool could not build")
	}
	if current.preparedSources[0].NodeID != selectedID {
		t.Fatal("new session chose provider's first node instead of manual node")
	}
}

func TestAndroidAutomaticRefreshCannotCommitAfterStopOrIgnoreInterval(t *testing.T) {
	generation, node := refreshedSourceSession(t)
	started, release := make(chan struct{}), make(chan struct{})
	androidSourceParser = func(string) ([]proxyConfig, error) { close(started); <-release; return []proxyConfig{node}, nil }
	done := make(chan struct{})
	go func() { RefreshAndroidSourcesForNextSession(context.Background(), generation); close(done) }()
	<-started
	CancelPendingSourceWork()
	close(release)
	<-done
	if len(current.VPNSources[0].PendingNodes) != 0 {
		t.Fatal("post-Stop refresh committed")
	}
	var plan struct {
		Generation int64 `json:"generation"`
	}
	_ = json.Unmarshal([]byte(BeginAndroidSourceSession()), &plan)
	current.VPNSources[0].UpdatedAt = currentTimeRFC3339()
	androidSourceParser = func(string) ([]proxyConfig, error) { t.Fatal("refreshed before interval elapsed"); return nil, nil }
	RefreshAndroidSourcesForNextSession(context.Background(), plan.Generation)
	current.VPNSources[0].UpdatedAt = ""
	current.Config.AutoUpdateSub = false
	RefreshAndroidSourcesForNextSession(context.Background(), plan.Generation)
}

func TestAndroidPendingRefreshSurvivesProcessDeathWithoutReplacingManualNode(t *testing.T) {
	generation, selected := refreshedSourceSession(t)
	newNode := proxyConfig{Type: "vless", Server: "new.example.com", ServerPort: 443, UUID: "new"}
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{newNode, selected}, nil }
	RefreshAndroidSourcesForNextSession(context.Background(), generation)
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	if current.Connected || len(current.VPNSources[0].PendingNodes) != 0 || androidSelectedNode(current.VPNSources[0]) != 1 {
		t.Fatal("restart lost staged update or silently replaced manual node")
	}
}

func TestAndroidRouteModeWriteFailureRollsBackModeAndCache(t *testing.T) {
	resetSourceTest(t)
	current.Config.RoutingMode = "blocked_only"
	current.CachedSingBoxConfig, current.CachedConfigSignature = "retained-config", "retained-signature"
	if err := os.Mkdir(filepath.Join(current.BasePath, stateFileName), 0700); err != nil {
		t.Fatal(err)
	}
	response := Call("SetRoutingMode", `["all_traffic"]`)
	if decodeSuccess(response) || !strings.Contains(response, "Не удалось сохранить") {
		t.Fatal("routing mode returned success after storage failure")
	}
	if current.Config.RoutingMode != "blocked_only" || current.CachedSingBoxConfig != "retained-config" || current.CachedConfigSignature != "retained-signature" {
		t.Fatal("write failure changed mode or destroyed retained config")
	}
}

func TestAndroidTrafficUsageIsNotInventedFromSessionDuration(t *testing.T) {
	resetSourceTest(t)
	SetConnected(true)
	current.StartedAt = time.Now().Add(-time.Hour).Format(time.RFC3339)
	stats := trafficStatsLocked()
	if stats["trafficAvailable"] != false {
		t.Fatal("unwired byte counters reported available")
	}
	for _, key := range []string{"current", "last", "total"} {
		block := stats[key].(map[string]interface{})
		if block["uploaded"] != int64(0) || block["downloaded"] != int64(0) || block["uploadedStr"] != "Нет данных" {
			t.Fatal("elapsed time fabricated traffic usage")
		}
	}
	if stats["current"].(map[string]interface{})["duration"].(int64) < 3500 {
		t.Fatal("real duration was lost")
	}
}
