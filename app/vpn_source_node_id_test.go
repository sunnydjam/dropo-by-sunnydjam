package main

import (
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

func nodeIDSelectionScenario(t *testing.T) (*App, *atomic.Value, VPNSource) {
	t.Helper()
	app := newInitializedSettingsScenarioApp(t)
	body := &atomic.Value{}
	body.Store(testVPNSourceOld + "\n" + testVPNSourceNew)
	app.configBuilder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body.Load().(string))), Header: make(http.Header)}, nil
	})}
	source, err := newVPNSource("source-one", "Subscription", "https://subscription.example.test/list")
	if err != nil {
		t.Fatal(err)
	}
	if err := app.configBuilder.BuildConfigForProfileSources(app.storage.GetActiveProfileID(), []VPNSource{source}, nil); err != nil {
		t.Fatal(err)
	}
	profile, _ := app.storage.GetActiveProfile()
	return app, body, profile.VPNSources[0]
}

func TestVPNSourceNodeByIDSurvivesReorderBeforeAndDuringTransaction(t *testing.T) {
	for _, beforeCall := range []bool{false, true} {
		t.Run(map[bool]string{false: "during-refresh", true: "before-call"}[beforeCall], func(t *testing.T) {
			app, body, source := nodeIDSelectionScenario(t)
			chosenID := source.NodeIDs[1]
			body.Store(testVPNSourceNew + "\n" + testVPNSourceOld)
			if beforeCall {
				if err := app.configBuilder.BuildConfigForProfileSources(app.storage.GetActiveProfileID(), []VPNSource{source}, nil); err != nil {
					t.Fatal(err)
				}
			}
			requireAPISuccess(t, app.SetVPNSourceNodeByID(source.ID, chosenID))
			profile, _ := app.storage.GetActiveProfile()
			selected := profile.VPNSources[0]
			if selected.SelectedNode != 0 || selected.SelectedNodeID != chosenID || selected.NodeIDs[0] != chosenID {
				t.Fatal("stable selection followed the old index after provider reorder")
			}
		})
	}
}

func TestVPNSourceNodeByIDDisappearingDuringReconnectRestoresOldProfile(t *testing.T) {
	app, body, source := nodeIDSelectionScenario(t)
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	setVPNSourceTestRunning(app, true)
	stopCalls, startCalls := 0, 0
	result := app.setVPNSourceNodeByID(source.ID, source.NodeIDs[1], vpnSourceReconnectOps{
		stop: func() map[string]interface{} {
			stopCalls++
			setVPNSourceTestRunning(app, false)
			body.Store(testVPNSourceOld)
			return map[string]interface{}{"success": true}
		},
		start: func() map[string]interface{} {
			startCalls++
			profile, _ := app.storage.GetActiveProfile()
			if !reflect.DeepEqual(*profile, snapshot) {
				t.Error("restart saw a different server/configuration instead of the rolled-back profile")
			}
			setVPNSourceTestRunning(app, true)
			return map[string]interface{}{"success": true}
		},
	})
	if result["success"] != false || result["rolledBack"] != true || result["connectionRestored"] != true || stopCalls != 1 || startCalls != 1 {
		t.Fatalf("disappearing manual choice was not safely rejected/recovered: %+v", result)
	}
	after, _ := app.storage.GetActiveProfile()
	if !reflect.DeepEqual(*after, snapshot) || !app.isVPNRunning() {
		t.Fatal("disappearing choice changed the saved profile or failed to restore the session")
	}
}

func TestVPNSourceNodeByIDRejectsMissingNodeWithoutMutation(t *testing.T) {
	app, body, source := nodeIDSelectionScenario(t)
	missingID := source.NodeIDs[1]
	body.Store(testVPNSourceOld)
	if err := app.configBuilder.BuildConfigForProfileSources(app.storage.GetActiveProfileID(), []VPNSource{source}, nil); err != nil {
		t.Fatal(err)
	}
	before, _ := app.storage.GetActiveProfile()
	snapshot, _ := cloneVPNSourceProfile(before)
	for _, pair := range [][2]string{{source.ID, missingID}, {source.ID, "invalid"}, {"missing", source.NodeIDs[0]}} {
		if app.SetVPNSourceNodeByID(pair[0], pair[1])["success"] == true {
			t.Fatal("missing/invalid server identity was accepted")
		}
	}
	after, _ := app.storage.GetActiveProfile()
	afterSnapshot, _ := cloneVPNSourceProfile(after)
	if !reflect.DeepEqual(afterSnapshot, snapshot) {
		t.Fatal("rejected server choice changed the profile")
	}
}
