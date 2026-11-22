package dropocore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestAndroidSourceMetadataConnectedAndPersistedWithoutTrafficChanges(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	SetConnected(true)
	mu.Lock()
	nodeID := androidNodeID(current.VPNSources[0].Nodes[0])
	current.CachedSingBoxConfig = "unchanged runtime configuration"
	current.CachedConfigSignature = "unchanged config signature"
	revision, session, selected := current.sourcesRevision, current.sourceSession, current.VPNSources[0].SelectedNodeID
	mu.Unlock()
	androidSourceParser = func(string) ([]proxyConfig, error) {
		t.Error("metadata edit attempted network parsing")
		return nil, fmt.Errorf("unexpected network call")
	}
	sourceSuccess(t, "RenameVPNSource", "source-1", "  Для работы  ")
	sourceSuccess(t, "SetVPNSourceNodeFavorite", "source-1", nodeID, true)
	sourceSuccess(t, "SetVPNSourceNodeFavorite", "source-1", nodeID, true)
	mu.Lock()
	if !current.Connected || current.CachedSingBoxConfig != "unchanged runtime configuration" || current.CachedConfigSignature != "unchanged config signature" || current.sourcesRevision != revision || current.sourceSession != session || current.VPNSources[0].SelectedNodeID != selected {
		mu.Unlock()
		t.Fatal("display metadata changed the active traffic state")
	}
	if current.VPNSources[0].Name != "Для работы" || !reflect.DeepEqual(current.VPNSources[0].FavoriteNodeIDs, []string{nodeID}) {
		mu.Unlock()
		t.Fatal("display metadata not applied/idempotent")
	}
	base := current.BasePath
	mu.Unlock()
	view := Call("GetVPNSources", "[]")
	for _, secret := range []string{"vless://", "example.com", "00000000-0000", `"uri"`, `"nodes"`} {
		if strings.Contains(view, secret) {
			t.Fatal("public metadata leaked credentials")
		}
	}
	if !strings.Contains(view, `"node_ids":["`+nodeID+`"]`) || !strings.Contains(view, `"favorite_node_ids":["`+nodeID+`"]`) {
		t.Fatal("public stable IDs are missing")
	}
	mu.Lock()
	current = defaultState()
	mu.Unlock()
	EnsureStarted(base, "test")
	mu.Lock()
	defer mu.Unlock()
	if current.VPNSources[0].Name != "Для работы" || !reflect.DeepEqual(current.VPNSources[0].FavoriteNodeIDs, []string{nodeID}) {
		t.Fatal("metadata lost after process restart")
	}
}

func TestAndroidSourceMetadataValidationAndSaveRollback(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	for _, name := range []interface{}{"", strings.Repeat("я", 81), "a\nb", "a\x00b", "a\u2028b", "https://private.example", false} {
		if sourceCall(t, "RenameVPNSource", "source-1", name)["success"] == true {
			t.Fatal("invalid name accepted")
		}
	}
	for _, args := range [][]interface{}{
		{"source-1", "https://secret.example", true},
		{"source-1", strings.Repeat("0", 64), true},
		{"source-1", androidNodeID(current.VPNSources[0].Nodes[0]), "true"},
		{"missing", androidNodeID(current.VPNSources[0].Nodes[0]), true},
	} {
		if sourceCall(t, "SetVPNSourceNodeFavorite", args...)["success"] == true {
			t.Fatal("invalid/foreign favorite accepted")
		}
	}
	mu.Lock()
	current.LastError = "existing connection health indication"
	before, _ := json.Marshal(current.VPNSources)
	revision := current.sourcesRevision
	nodeID := androidNodeID(current.VPNSources[0].Nodes[0])
	current.BasePath = t.TempDir()
	if err := os.Mkdir(filepath.Join(current.BasePath, stateFileName), 0700); err != nil {
		mu.Unlock()
		t.Fatal(err)
	}
	mu.Unlock()
	for _, result := range []map[string]interface{}{
		sourceCall(t, "RenameVPNSource", "source-1", "Not saved"),
		sourceCall(t, "SetVPNSourceNodeFavorite", "source-1", nodeID, true),
	} {
		if result["success"] == true {
			t.Fatal("failed write reported success")
		}
	}
	mu.Lock()
	defer mu.Unlock()
	after, _ := json.Marshal(current.VPNSources)
	if string(after) != string(before) || current.sourcesRevision != revision || current.LastError != "existing connection health indication" {
		t.Fatal("persistence failure changed source metadata/traffic revision")
	}
}

func TestAndroidSourceMetadataSurvivesConcurrentSubscriptionRefresh(t *testing.T) {
	resetSourceTest(t)
	a := proxyConfig{Type: "vless", Server: "first.example", ServerPort: 443, UUID: "first", Name: "First", Security: "tls"}
	b := proxyConfig{Type: "vless", Server: "second.example", ServerPort: 443, UUID: "second", Name: "Second", Security: "tls"}
	androidSourceParser = func(string) ([]proxyConfig, error) { return []proxyConfig{a, b}, nil }
	sourceSuccess(t, "AddVPNSource", "Subscription", "https://example.com/private-key")
	sourceSuccess(t, "SetVPNSourceNode", "source-1", 1)
	started, release := make(chan struct{}), make(chan struct{})
	androidSourceParser = func(string) ([]proxyConfig, error) {
		close(started)
		<-release
		b.Name, b.Tag = "Renamed provider label", "new label"
		return []proxyConfig{b, a}, nil
	}
	done := make(chan string, 1)
	go func() { done <- Call("RefreshVPNSources", "[]") }()
	<-started
	nodeID := androidNodeID(a)
	sourceSuccess(t, "RenameVPNSource", "source-1", "Saved during download")
	sourceSuccess(t, "SetVPNSourceNodeFavorite", "source-1", nodeID, true)
	close(release)
	select {
	case result := <-done:
		if !decodeSuccess(result) {
			t.Fatal("metadata edit cancelled a safe refresh")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("refresh did not finish")
	}
	mu.Lock()
	defer mu.Unlock()
	source := current.VPNSources[0]
	if source.Name != "Saved during download" || !reflect.DeepEqual(source.FavoriteNodeIDs, []string{nodeID}) || androidSelectedNode(source) != 0 {
		t.Fatal("refresh lost display metadata or changed chosen server identity")
	}
	// A staged refresh can temporarily remove and later restore a favorite.
	current.VPNSources[0].PendingNodes = []proxyConfig{b}
	applyPendingAndroidSourceRefreshLocked()
	if !reflect.DeepEqual(current.VPNSources[0].FavoriteNodeIDs, []string{nodeID}) {
		t.Fatal("pending refresh lost absent favorite")
	}
	current.VPNSources[0].PendingNodes = []proxyConfig{a, b}
	applyPendingAndroidSourceRefreshLocked()
	if androidNodeID(current.VPNSources[0].Nodes[0]) != current.VPNSources[0].FavoriteNodeIDs[0] {
		t.Fatal("returning server no longer matches favorite")
	}
}

func TestAndroidSourceFavoriteBoundAndConcurrentEdits(t *testing.T) {
	resetSourceTest(t)
	nodes := make([]proxyConfig, maxAndroidSourceFavorites+1)
	for i := range nodes {
		nodes[i] = proxyConfig{Type: "vless", Server: fmt.Sprintf("n%d.example", i), ServerPort: 443, UUID: "test", Security: "tls"}
	}
	androidSourceParser = func(string) ([]proxyConfig, error) { return nodes, nil }
	sourceSuccess(t, "AddVPNSource", "Subscription", "https://example.com/private")
	var tasks sync.WaitGroup
	for n := 0; n < maxAndroidSourceFavorites; n++ {
		tasks.Add(1)
		go func(node proxyConfig) {
			defer tasks.Done()
			args, _ := json.Marshal([]interface{}{"source-1", androidNodeID(node), true})
			if !decodeSuccess(Call("SetVPNSourceNodeFavorite", string(args))) {
				t.Error("concurrent favorite failed")
			}
		}(nodes[n])
	}
	tasks.Wait()
	if sourceCall(t, "SetVPNSourceNodeFavorite", "source-1", androidNodeID(nodes[maxAndroidSourceFavorites]), true)["success"] == true {
		t.Fatal("favorite limit exceeded")
	}
	mu.Lock()
	if len(current.VPNSources[0].FavoriteNodeIDs) != maxAndroidSourceFavorites {
		mu.Unlock()
		t.Fatal("concurrent favorite was lost")
	}
	mu.Unlock()
	sourceSuccess(t, "SetVPNSourceNodeFavorite", "source-1", androidNodeID(nodes[0]), false)
	sourceSuccess(t, "SetVPNSourceNodeFavorite", "source-1", androidNodeID(nodes[maxAndroidSourceFavorites]), true)
}
