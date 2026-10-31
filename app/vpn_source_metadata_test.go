package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func metadataScenario(t *testing.T) (*App, VPNSource) {
	t.Helper()
	app := newInitializedSettingsScenarioApp(t)
	source, err := newVPNSource("source-one", "Личная подписка", testVPNSourceOld)
	if err != nil {
		t.Fatal(err)
	}
	node, err := (&SubscriptionFetcher{}).ParseSingleLink(testVPNSourceOld)
	if err != nil {
		t.Fatal(err)
	}
	markVPNSourceUpdated(&source, []ProxyConfig{node}, nil)
	if err := app.storage.UpdateProfileVPNSources(app.storage.GetActiveProfileID(), []VPNSource{source}, nil); err != nil {
		t.Fatal(err)
	}
	return app, source
}

func TestVPNSourceMetadataEditsKeepLiveConnectionAndPersist(t *testing.T) {
	app, source := metadataScenario(t)
	setVPNSourceTestRunning(app, true)
	before, _ := app.storage.GetActiveProfile()
	beforeData, _ := json.Marshal(before)
	// Metadata must not need the network/config builder even while connected.
	app.configBuilder = nil
	requireAPISuccess(t, app.RenameVPNSource(source.ID, "  Для работы  "))
	requireAPISuccess(t, app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[0], true))
	requireAPISuccess(t, app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[0], true))
	after, _ := app.storage.GetActiveProfile()
	if !app.isVPNRunning() || after.VPNSources[0].Name != "Для работы" || !reflect.DeepEqual(after.VPNSources[0].FavoriteNodeIDs, source.NodeIDs) {
		t.Fatal("metadata did not persist without disconnecting")
	}
	// Every field except the two explicit display fields must remain identical.
	comparison, _ := cloneVPNSourceProfile(after)
	comparison.VPNSources[0].Name = source.Name
	comparison.VPNSources[0].FavoriteNodeIDs = before.VPNSources[0].FavoriteNodeIDs
	comparisonData, _ := json.Marshal(comparison)
	if string(comparisonData) != string(beforeData) {
		t.Fatal("metadata edit changed routing/config/source selection")
	}
	var saved SettingsFile
	data, err := os.ReadFile(app.storage.settingsPath)
	if err != nil || json.Unmarshal(data, &saved) != nil {
		t.Fatal("saved settings unavailable")
	}
	if saved.Profiles[0].VPNSources[0].Name != "Для работы" || len(saved.Profiles[0].VPNSources[0].FavoriteNodeIDs) != 1 {
		t.Fatal("metadata was not written to settings")
	}
	view, _ := json.Marshal(publicVPNSources(after.VPNSources))
	if !strings.Contains(string(view), `"node_ids"`) || !strings.Contains(string(view), `"favorite_node_ids"`) {
		t.Fatal("public view missing stable metadata")
	}
	for _, secret := range []string{"vless://", "old.example.test", "11111111-1111", `"cached_nodes"`, `"uri"`} {
		if strings.Contains(string(view), secret) {
			t.Fatal("public view exposed source credentials")
		}
	}
}

func TestVPNSourceMetadataRejectsInvalidValuesAndSaveFailure(t *testing.T) {
	app, source := metadataScenario(t)
	for _, name := range []string{"", strings.Repeat("я", 81), "line\nbreak", "a\x00b", "https://secret.example", "a\u2028b"} {
		if app.RenameVPNSource(source.ID, name)["success"] == true {
			t.Fatalf("accepted invalid display name %q", name)
		}
	}
	for _, id := range []string{"", "https://secret.example", strings.Repeat("0", 24)} {
		if app.SetVPNSourceNodeFavorite(source.ID, id, true)["success"] == true {
			t.Fatal("accepted malformed/foreign node identity")
		}
	}
	if app.RenameVPNSource("SOURCE-ONE", "Wrong")["success"] == true {
		t.Fatal("normalized an invalid source id into another source")
	}
	before, _ := app.storage.GetActiveProfile()
	beforeData, _ := json.Marshal(before)
	app.storage.settingsPath = filepath.Join(t.TempDir(), "directory")
	if err := os.Mkdir(app.storage.settingsPath, 0700); err != nil {
		t.Fatal(err)
	}
	if app.RenameVPNSource(source.ID, "Not saved")["success"] == true || app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[0], true)["success"] == true {
		t.Fatal("write failure reported success")
	}
	after, _ := app.storage.GetActiveProfile()
	afterData, _ := json.Marshal(after)
	if string(afterData) != string(beforeData) {
		t.Fatal("failed save changed live source metadata")
	}
}

func TestVPNSourceRefreshPreservesConcurrentMetadataAndStableFavorite(t *testing.T) {
	app, source := metadataScenario(t)
	stale := []VPNSource{source}
	requireAPISuccess(t, app.RenameVPNSource(source.ID, "Saved while refreshing"))
	requireAPISuccess(t, app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[0], true))
	node, _ := (&SubscriptionFetcher{}).ParseSingleLink(testVPNSourceOld)
	node.Name = "Provider changed display label"
	markVPNSourceUpdated(&stale[0], []ProxyConfig{node}, nil)
	if err := app.storage.UpdateProfileVPNSources(app.storage.GetActiveProfileID(), stale, nil); err != nil {
		t.Fatal(err)
	}
	updated, _ := app.storage.GetActiveProfile()
	if updated.VPNSources[0].Name != "Saved while refreshing" || !reflect.DeepEqual(updated.VPNSources[0].FavoriteNodeIDs, source.NodeIDs) {
		t.Fatal("stale subscription refresh overwrote current metadata")
	}
	// Temporarily absent nodes retain their bounded favorite ID; a node from a
	// replacement subscription with the same source ID must not inherit it.
	markVPNSourceUpdated(&stale[0], nil, nil)
	if err := app.storage.UpdateProfileVPNSources(app.storage.GetActiveProfileID(), stale, nil); err != nil {
		t.Fatal(err)
	}
	updated, _ = app.storage.GetActiveProfile()
	if len(updated.VPNSources[0].FavoriteNodeIDs) != 1 {
		t.Fatal("temporarily missing favorite was discarded")
	}
	replacement := []VPNSource{{ID: source.ID, URI: testVPNSourceNew, Name: "Replacement"}}
	preserveVPNSourceMetadata(replacement, updated.VPNSources)
	if len(replacement[0].FavoriteNodeIDs) != 0 || replacement[0].Name != "Replacement" {
		t.Fatal("metadata leaked between independent source identities")
	}
}

func TestVPNSourceFavoritesBoundAndConcurrentEdits(t *testing.T) {
	app, source := metadataScenario(t)
	for n := 1; n <= maxVPNSourceFavorites; n++ {
		source.NodeIDs = append(source.NodeIDs, fmt.Sprintf("%024x", n))
	}
	if err := app.storage.UpdateProfileVPNSources(app.storage.GetActiveProfileID(), []VPNSource{source}, nil); err != nil {
		t.Fatal(err)
	}
	var tasks sync.WaitGroup
	for n := 0; n < maxVPNSourceFavorites; n++ {
		tasks.Add(1)
		go func(id string) {
			defer tasks.Done()
			if app.SetVPNSourceNodeFavorite(source.ID, id, true)["success"] != true {
				t.Error("concurrent favorite failed")
			}
		}(source.NodeIDs[n])
	}
	tasks.Wait()
	if app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[maxVPNSourceFavorites], true)["success"] == true {
		t.Fatal("favorite bound exceeded")
	}
	after, _ := app.storage.GetActiveProfile()
	if len(after.VPNSources[0].FavoriteNodeIDs) != maxVPNSourceFavorites {
		t.Fatal("concurrent edit was lost")
	}
	requireAPISuccess(t, app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[0], false))
	requireAPISuccess(t, app.SetVPNSourceNodeFavorite(source.ID, source.NodeIDs[maxVPNSourceFavorites], true))
}
