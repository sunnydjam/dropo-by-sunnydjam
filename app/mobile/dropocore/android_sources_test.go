package dropocore

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const sourceTestKey = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#demo"

func resetSourceTest(t *testing.T) {
	t.Helper()
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()
	original := androidSourceParser
	t.Cleanup(func() { androidSourceParser = original })
}

func sourceCall(t *testing.T, method string, args ...interface{}) map[string]interface{} {
	t.Helper()
	data, _ := json.Marshal(args)
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(Call(method, string(data))), &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func sourceSuccess(t *testing.T, method string, args ...interface{}) {
	t.Helper()
	if result := sourceCall(t, method, args...); result["success"] != true {
		t.Fatalf("%s: %v", method, result)
	}
}

func TestAndroidSourcePoolMigrationAndRoutingPreference(t *testing.T) {
	resetSourceTest(t)
	if current.Config.RoutingMode != "all_traffic" {
		t.Fatal("fresh Android install must default to all traffic")
	}
	current.Subscription = sourceTestKey
	current.Config.RoutingMode = "blocked_only"
	if err := saveLocked(); err != nil {
		t.Fatal(err)
	}
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	if len(current.VPNSources) != 1 || current.VPNSources[0].URI != sourceTestKey {
		t.Fatal("legacy subscription was not migrated")
	}
	if current.Config.RoutingMode != "blocked_only" {
		t.Fatal("saved route choice was overwritten")
	}
	EnsureStarted(base, "test")
	if len(current.VPNSources) != 1 {
		t.Fatal("migration duplicated source")
	}
}

func TestAndroidSourcePoolRecoversAfterProcessDeath(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	SetConnected(true)
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	if current.Connected || androidSourcesBusyLocked() {
		t.Fatal("persisted connection kept source editor locked after process death")
	}
	SetConnected(true)
	EnsureStarted(base, "test")
	if !current.Connected {
		t.Fatal("idempotent initialization reset a live session")
	}
	if sourceCall(t, "RemoveVPNSource", "source-1")["success"] == true {
		t.Fatal("source mutated during live session")
	}
}

func TestAndroidSourcePoolCRUDAndPrivateViews(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	sourceSuccess(t, "AddVPNSource", "Второй", strings.ReplaceAll(sourceTestKey, "example.com", "second.example.com"))
	if result := sourceCall(t, "AddVPNSource", "Копия", sourceTestKey); result["success"] == true {
		t.Fatal("accepted duplicate")
	}
	sourceSuccess(t, "MoveVPNSource", "source-2", 0)
	if !strings.Contains(current.Subscription, "second.example.com") {
		t.Fatal("move did not select primary")
	}
	sourceSuccess(t, "SetVPNSourceEnabled", "source-2", false)
	if current.Subscription != sourceTestKey {
		t.Fatal("disabled primary still selected")
	}
	view := Call("GetVPNSources", "[]")
	for _, secret := range []string{"vless://", "00000000-0000", "second.example.com", `"uri"`, `"nodes"`} {
		if strings.Contains(view, secret) {
			t.Fatalf("source view exposed %q", secret)
		}
	}
	sourceSuccess(t, "RemoveVPNSource", "source-1")
	if current.Subscription != "" {
		t.Fatal("disabled source selected after remove")
	}
	base := current.BasePath
	current = defaultState()
	EnsureStarted(base, "test")
	if len(current.VPNSources) != 1 || !current.VPNSources[0].Disabled {
		t.Fatal("pool not persisted")
	}
}

func TestAndroidManualNodeSurvivesReorderAndNeverSelectsSibling(t *testing.T) {
	resetSourceTest(t)
	a := proxyConfig{Type: "vless", Server: "first.example.com", ServerPort: 443, UUID: "first", Name: "First", Tag: "first"}
	b := proxyConfig{Type: "vless", Server: "chosen.example.com", ServerPort: 443, UUID: "chosen", Name: "Chosen", Tag: "chosen"}
	nodes := []proxyConfig{a, b}
	androidSourceParser = func(string) ([]proxyConfig, error) { return nodes, nil }
	sourceSuccess(t, "AddVPNSource", "Подписка", "https://example.com/private-token")
	sourceSuccess(t, "SetVPNSourceNode", "source-1", 1)
	nodes = []proxyConfig{b, a}
	nodes[0].Name, nodes[0].Tag = "New name", "new-tag"
	sourceSuccess(t, "RefreshVPNSources")
	if androidSelectedNode(current.VPNSources[0]) != 0 {
		t.Fatal("selected server identity lost on reorder/rename")
	}
	response := BuildSingBoxConfig()
	if !decodeSuccess(response) || !strings.Contains(response, "chosen.example.com") || strings.Contains(response, "first.example.com") || strings.Contains(response, "urltest") {
		t.Fatal("configuration must contain only selected server")
	}
	nodes = []proxyConfig{a}
	sourceSuccess(t, "RefreshVPNSources")
	if androidSelectedNode(current.VPNSources[0]) != -1 {
		t.Fatal("missing selected node silently replaced")
	}
	if decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("missing manual node must fail without using sibling")
	}
}

func TestAndroidSourceMutationRollsBackPersistenceFailure(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	before := current.Subscription
	current.BasePath = t.TempDir()
	if err := os.Mkdir(filepath.Join(current.BasePath, stateFileName), 0700); err != nil {
		t.Fatal(err)
	}
	if result := sourceCall(t, "RemoveVPNSource", "source-1"); result["success"] == true {
		t.Fatal("reported success after write failure")
	}
	if current.Subscription != before || len(current.VPNSources) != 1 {
		t.Fatal("write failure changed live pool")
	}
}

func TestAndroidSlowSourceDoesNotBlockStatusOrCommitAcrossSession(t *testing.T) {
	resetSourceTest(t)
	started, release := make(chan struct{}), make(chan struct{})
	androidSourceParser = func(string) ([]proxyConfig, error) {
		close(started)
		<-release
		return []proxyConfig{{Type: "vless", Server: "example.com", ServerPort: 443}}, nil
	}
	done := make(chan string, 1)
	go func() { done <- Call("AddVPNSource", `["Slow","https://example.com/secret"]`) }()
	<-started
	status := make(chan string, 1)
	go func() { status <- Status() }()
	select {
	case <-status:
	case <-time.After(time.Second):
		close(release)
		<-done
		t.Fatal("status blocked by subscription download")
	}
	Call("AndroidEngineStarting", "[]")
	SetConnected(false)
	close(release)
	if decodeSuccess(<-done) || len(current.VPNSources) != 0 {
		t.Fatal("stale source result committed across session")
	}
}

func TestAndroidPublicSourceConsentAndFiltering(t *testing.T) {
	resetSourceTest(t)
	calls := 0
	androidSourceParser = func(string) ([]proxyConfig, error) {
		calls++
		return []proxyConfig{
			{Type: "vless", Server: "127.0.0.1", ServerPort: 443},
			{Type: "vless", Server: "10.0.0.1", ServerPort: 443},
			{Type: "vless", Server: "host.local", ServerPort: 443},
			{Type: "vless", Server: "2001:4860:4860::8888", ServerPort: 443},
		}, nil
	}
	if sourceCall(t, "AddPublicVPNSource", androidPublicSourceID, false)["success"] == true || calls != 0 {
		t.Fatal("public source fetched without consent")
	}
	sourceSuccess(t, "AddPublicVPNSource", androidPublicSourceID, true)
	if len(current.VPNSources[0].Nodes) != 1 {
		t.Fatal("public private endpoints not filtered")
	}
	if sourceCall(t, "AddPublicVPNSource", androidPublicSourceID, true)["success"] == true {
		t.Fatal("duplicate public source accepted")
	}
}

func TestAndroidSourceRefreshFailureIsAtomic(t *testing.T) {
	resetSourceTest(t)
	sourceSuccess(t, "AddVPNSource", "Первый", sourceTestKey)
	sourceSuccess(t, "AddVPNSource", "Второй", strings.ReplaceAll(sourceTestKey, "example.com", "second.example.com"))
	before, _ := json.Marshal(current.VPNSources)
	androidSourceParser = func(string) ([]proxyConfig, error) { return nil, fmt.Errorf("provider unavailable") }
	if sourceCall(t, "RefreshVPNSources")["success"] == true {
		t.Fatal("failed refresh reported success")
	}
	after, _ := json.Marshal(current.VPNSources)
	if string(before) != string(after) {
		t.Fatal("failed refresh mutated source pool")
	}
}
