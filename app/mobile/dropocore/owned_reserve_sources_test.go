package dropocore

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const ownedReserveFixture = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"

func resetOwnedReserveTest(t *testing.T) {
	resetSourceTest(t)
	installAndroidXHTTPTestValidator(t, testAndroidXHTTPValidator{})
}

func TestAndroidOwnedPairMigrationKeepsChoicesAndIndependentCandidates(t *testing.T) {
	resetOwnedReserveTest(t)
	nodes, err := parseAndroidSource(ownedReserveFixture)
	if err != nil {
		t.Fatal(err)
	}
	current.VPNSources = []androidVPNSource{{ID: "old-owned", PublicCatalogID: ownedprofile.Free, Name: "My Free", URI: ownedReserveFixture, Nodes: nodes, Disabled: true}}
	current.VPNSourceAutoSelect = true
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	if len(current.VPNSources) != 2 || !current.VPNSources[0].Disabled || !current.VPNSources[1].Disabled || current.VPNSources[0].ID != "old-owned" || !current.VPNSourceAutoSelect {
		t.Fatal("migration changed choice or disabled product")
	}
	sourceSuccess(t, "SetVPNSourceEnabled", "old-owned", true)
	if current.VPNSources[0].Disabled || current.VPNSources[1].Disabled {
		t.Fatal("explicit product enable did not enable the family")
	}
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("cannot prepare managed failover")
	}
	wantIDs := []string{ownedprofile.Free + "-lv-quic", ownedprofile.Free + ownedprofile.MainSuffix, ownedprofile.Free + ownedprofile.ExtraSuffix}
	if len(current.preparedSources) != len(wantIDs) {
		t.Fatalf("expected two independent sources, got %d", len(current.preparedSources))
	}
	for i, candidate := range current.preparedSources {
		if candidate.ID != wantIDs[i] || candidate.Tag != "vpn-"+candidate.ID {
			t.Fatalf("incorrect failover order at %d: %#v", i, candidate)
		}
	}
	for _, s := range current.VPNSources {
		if len(s.Nodes) != 1 {
			t.Fatal("reserve became a sibling node")
		}
	}
	SetConnected(true)
	var plan struct {
		Generation int64 `json:"generation"`
	}
	json.Unmarshal([]byte(BeginAndroidSourceSession()), &plan)
	reserve := current.preparedSources[0]
	selector := &testSourceSelector{}
	if !CommitAndroidSourceProbeBatch(plan.Generation, sourceObservationJSON(reserve.ID, reserve.NodeID, plan.Generation, "ok", 40), reserve.ID, selector) {
		t.Fatal("healthy reserve did not commit")
	}
	view := sourceCall(t, "GetVPNSources")["sources"].([]interface{})
	if len(view) != 1 || view[0].(map[string]interface{})["id"] != "old-owned" || view[0].(map[string]interface{})["active"] != true || view[0].(map[string]interface{})["active_ingress"] != ownedprofile.Hysteria {
		t.Fatal("an active reserve must still display as the main profile")
	}
	CancelPendingSourceWork()
	if CommitAndroidSourceProbeBatch(plan.Generation, sourceObservationJSON(reserve.ID, reserve.NodeID, plan.Generation, "ok", 40), reserve.ID, selector) {
		t.Fatal("stale reserve committed after Stop")
	}
}

func TestAndroidOwnedPairRefreshDeletionAndRedaction(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddVPNSource", "Personal", sourceTestKey)
	personal := current.VPNSources[0]
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	primaryID, reserveID := current.VPNSources[1].ID, current.VPNSources[2].ID
	sourceSuccess(t, "SetVPNSourceEnabled", primaryID, false)
	if sourceCall(t, "MoveVPNSource", reserveID, 1)["success"] == true {
		t.Fatal("an internal reserve was reorderable")
	}
	sourceSuccess(t, "MoveVPNSource", primaryID, 0)
	sourceSuccess(t, "EnableVPNSourceAutoSelect", true)
	personal = current.VPNSources[2]
	refreshed := strings.ReplaceAll(ownedReserveFixture, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", refreshed, true)
	if current.VPNSources[0].ID != primaryID || current.VPNSources[1].ID != reserveID || !current.VPNSources[0].Disabled || !current.VPNSources[1].Disabled || !current.VPNSourceAutoSelect || !reflect.DeepEqual(current.VPNSources[2], personal) {
		t.Fatal("refresh overwrote group ordering, disabled state or personal data")
	}
	before := current.sourcesRevision
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", refreshed, true)
	if current.sourcesRevision != before {
		t.Fatal("unchanged restore rewrote source preferences")
	}
	redacted, _ := json.Marshal(stateWithoutOwnedSecrets(current))
	if strings.Contains(string(redacted), "aaaaaaaa-bbbb") || strings.Contains(string(redacted), "91.229.239.99") {
		t.Fatal("reserve credential persisted outside vault")
	}
	sourceSuccess(t, "RemoveVPNSource", reserveID)
	if len(current.VPNSources) != 1 || !reflect.DeepEqual(current.VPNSources[0], personal) {
		t.Fatal("family deletion left a resurrectable owned reference or touched personal source")
	}
}

func TestAndroidOwnedPairsPriorityAndReservedCapacity(t *testing.T) {
	resetOwnedReserveTest(t)
	for i := 0; i < 14; i++ {
		current.VPNSources = append(current.VPNSources, androidVPNSource{ID: fmt.Sprintf("personal-%d", i), Name: "Personal", URI: sourceTestKey})
	}
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	boost := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Boost, "ignored", boost, true)
	if len(current.VPNSources) != 18 || androidLogicalSourceCount(current.VPNSources) != 16 {
		t.Fatal("reserved capacity displaced user sources")
	}
	want := []string{ownedprofile.Boost, ownedprofile.BoostReserve, ownedprofile.Free, ownedprofile.FreeReserve}
	for i, id := range want {
		if current.VPNSources[14+i].PublicCatalogID != id {
			t.Fatal("owned fallback order changed")
		}
	}
	if sourceCall(t, "AddVPNSource", "Overflow", sourceTestKey)["success"] == true {
		t.Fatal("reserve capacity expanded personal source limit")
	}
	if sourceCall(t, "AddManagedVPNSource", ownedprofile.FreeReserve, "Reserve", current.VPNSources[17].URI, true)["success"] == true {
		t.Fatal("externally supplied reserve accepted without primary")
	}
	// The maximum-size probe batch must be allowed to select candidate 18.
	current.Connected = true
	current.sourceSession = 77
	var observations []androidSourceResponse
	current.preparedSources = nil
	current.sourceResponses = map[string]androidSourceResponse{}
	for i, s := range current.VPNSources {
		node := fmt.Sprintf("node-%d", i)
		current.preparedSources = append(current.preparedSources, androidSourceCandidate{ID: s.ID, Tag: "candidate-" + s.ID, NodeID: node})
		observations = append(observations, androidSourceResponse{SourceID: s.ID, NodeID: node, State: "ok", LatencyMS: 40, CheckedAt: time.Now().UTC().Format(time.RFC3339Nano), SessionGeneration: 77})
	}
	data, _ := json.Marshal(observations)
	selector := &testSourceSelector{}
	if !CommitAndroidSourceProbeBatch(77, string(data), current.VPNSources[17].ID, selector) {
		t.Fatal("valid full 18-candidate batch was rejected")
	}
	observations = append(observations, observations[0])
	data, _ = json.Marshal(observations)
	if CommitAndroidSourceProbeBatch(77, string(data), current.VPNSources[17].ID, selector) {
		t.Fatal("oversized candidate batch was accepted")
	}
}

func TestAndroidOwnedPairFailureIsAtomic(t *testing.T) {
	resetOwnedReserveTest(t)
	for i := 0; i < 16; i++ {
		current.VPNSources = append(current.VPNSources, androidVPNSource{ID: fmt.Sprintf("personal-%d", i), URI: sourceTestKey})
	}
	before := append([]androidVPNSource(nil), current.VPNSources...)
	if sourceCall(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)["success"] == true || !reflect.DeepEqual(before, current.VPNSources) {
		t.Fatal("full user list partially changed by managed pair")
	}
	current.VPNSources = nil
	if err := os.Mkdir(filepath.Join(current.BasePath, stateFileName), 0700); err != nil {
		t.Fatal(err)
	}
	if sourceCall(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)["success"] == true || len(current.VPNSources) != 0 {
		t.Fatal("failed persistence left a partial pair")
	}
}

func TestAndroidSixteenSourceLegacyMigrationUsesReservedSlot(t *testing.T) {
	resetOwnedReserveTest(t)
	nodes, err := parseAndroidSource(ownedReserveFixture)
	if err != nil {
		t.Fatal(err)
	}
	current.VPNSources = []androidVPNSource{{ID: "legacy-free", PublicCatalogID: ownedprofile.Free, URI: ownedReserveFixture, Nodes: nodes, Disabled: true}}
	for i := 0; i < 15; i++ {
		current.VPNSources = append(current.VPNSources, androidVPNSource{ID: fmt.Sprintf("personal-%d", i), URI: sourceTestKey})
	}
	before := append([]androidVPNSource(nil), current.VPNSources[1:]...)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	if len(current.VPNSources) != 17 || !current.VPNSources[1].Disabled || !reflect.DeepEqual(before, current.VPNSources[2:]) {
		t.Fatal("legacy full list lost personal entries or bypassed disabled Free")
	}
}

func TestAndroidOwnedLegacyReserveMigrationPreservesExistingOrder(t *testing.T) {
	resetOwnedReserveTest(t)
	boost := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	freeNodes, err := parseAndroidSource(ownedReserveFixture)
	if err != nil {
		t.Fatal(err)
	}
	boostNodes, err := parseAndroidSource(boost)
	if err != nil {
		t.Fatal(err)
	}
	for _, freeFirst := range []bool{true, false} {
		for _, target := range []string{ownedprofile.Free, ownedprofile.Boost} {
			free := androidVPNSource{ID: "old-free", PublicCatalogID: ownedprofile.Free, URI: ownedReserveFixture, Nodes: freeNodes, Disabled: true}
			paid := androidVPNSource{ID: "old-boost", PublicCatalogID: ownedprofile.Boost, URI: boost, Nodes: boostNodes}
			personal := androidVPNSource{ID: "personal", URI: sourceTestKey, Name: "Personal"}
			before := []androidVPNSource{free, personal, paid}
			if !freeFirst {
				before = []androidVPNSource{paid, personal, free}
			}
			current.VPNSources = append([]androidVPNSource(nil), before...)
			current.VPNSourceAutoSelect = false
			key := ownedReserveFixture
			if target == ownedprofile.Boost {
				key = boost
			}
			sourceSuccess(t, "AddManagedVPNSource", target, "ignored", key, true)
			var retained []androidVPNSource
			for i, s := range current.VPNSources {
				if ownedprofile.IsReserve(s.PublicCatalogID) {
					if i == 0 || current.VPNSources[i-1].PublicCatalogID != target || s.Disabled != current.VPNSources[i-1].Disabled {
						t.Fatal("reserve is not adjacent to original primary")
					}
				} else {
					retained = append(retained, s)
				}
			}
			if !reflect.DeepEqual(retained, before) || current.VPNSourceAutoSelect {
				t.Fatal("migration changed existing product order or metadata")
			}
		}
	}
}

func TestAndroidOwnedRestoreCannotResurrectConcurrentDeletion(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	started, release := make(chan struct{}), make(chan struct{})
	calls := 0
	androidSourceParser = func(string) ([]proxyConfig, error) {
		calls++
		if calls == 1 {
			close(started)
			<-release
		}
		return []proxyConfig{{Type: "vless", Server: "203.0.113.10", ServerPort: 443}}, nil
	}
	result := make(chan string, 1)
	refreshed := strings.ReplaceAll(ownedReserveFixture, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	go func() { result <- addOwnedAndroidSource(ownedprofile.Free, refreshed, true) }()
	<-started
	sourceSuccess(t, "RemoveVPNSource", current.VPNSources[0].ID)
	close(release)
	if decodeSuccess(<-result) || len(current.VPNSources) != 0 {
		t.Fatal("in-flight profile resurrected a deleted family")
	}
}

func TestAndroidOwnedRestoreRequiresCurrentUIReference(t *testing.T) {
	boostFixture := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Boost, "ignored", boostFixture, true)
	ref := current.VPNSources[0]
	nodeID := androidNodeID(ref.Nodes[0])
	sourceSuccess(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, ref.ID, nodeID)
	sourceSuccess(t, "RemoveVPNSource", ref.ID)
	if sourceCall(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, ref.ID, nodeID)["success"] == true || len(current.VPNSources) != 0 {
		t.Fatal("UI snapshot recreated removed family")
	}
	for _, replacement := range []string{
		strings.ReplaceAll(boostFixture, "expiry=4102444800", "expiry=4202444800"),
		strings.ReplaceAll(boostFixture, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
	} {
		sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Boost, "ignored", replacement, true)
		before := append([]androidVPNSource(nil), current.VPNSources...)
		reference := current.VPNSources[0]
		if sourceCall(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, reference.ID, androidNodeID(reference.Nodes[0]))["success"] == true || !reflect.DeepEqual(before, current.VPNSources) {
			t.Fatal("stale vault overwrote live credential/expiry")
		}
	}
	current = stateWithoutOwnedSecrets(current)
	sourceSuccess(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, current.VPNSources[1].ID, "")
	if sourceCall(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, "", "")["success"] == true {
		t.Fatal("empty reference accepted")
	}
	sourceSuccess(t, "AddVPNSource", "Personal", sourceTestKey)
	personal := current.VPNSources[len(current.VPNSources)-1]
	if sourceCall(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, personal.ID, androidNodeID(personal.Nodes[0]))["success"] == true {
		t.Fatal("foreign reference accepted")
	}
	if sourceCall(t, "RestoreManagedVPNSource", ownedprofile.Boost, boostFixture, current.VPNSources[0].ID, "wrong-node")["success"] == true {
		t.Fatal("replaced node accepted")
	}
}

func TestAndroidOwnedOrphanReserveKeepsExistingOrder(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "ignored", ownedReserveFixture, true)
	reserve := current.VPNSources[1]
	before := []androidVPNSource{reserve, {ID: "personal", URI: sourceTestKey}, {ID: "boost", PublicCatalogID: ownedprofile.Boost}}
	current.VPNSources = append([]androidVPNSource(nil), before...)
	sourceSuccess(t, "RestoreManagedVPNSource", ownedprofile.Free, ownedReserveFixture, reserve.ID, androidNodeID(reserve.Nodes[0]))
	if !reflect.DeepEqual(current.VPNSources[:3], before) {
		t.Fatal("orphan reserve restoration reordered existing sources")
	}
}

func TestAndroidManagedIngressChoiceSurvivesRestoreAndPreservesEntitlement(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddVPNSource", "Personal", sourceTestKey)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "", ownedReserveFixture, true)
	if sourceCall(t, "SetManagedIngress", "source-1", "latvia")["success"] == true {
		t.Fatal("personal source acquired managed transport")
	}
	if sourceCall(t, "SetManagedIngress", ownedprofile.Free, "finland")["success"] == true {
		t.Fatal("Free acquired a Finnish transport")
	}
	sourceSuccess(t, "SetManagedIngress", ownedprofile.Free, ownedprofile.XHTTP)
	current = stateWithoutOwnedSecrets(current)
	sourceSuccess(t, "RestoreManagedVPNSource", ownedprofile.Free, ownedReserveFixture, ownedprofile.Free, "")
	if !decodeSuccess(BuildSingBoxConfig()) || len(current.preparedSources) != 2 || current.preparedSources[0].ID != ownedprofile.Free+ownedprofile.MainSuffix || current.preparedSources[1].OwnerID == ownedprofile.Free {
		t.Fatal("restored manual choice did not pin regional XHTTP before the personal subscription")
	}
	sourceSuccess(t, "SetManagedIngress", ownedprofile.Free, "")
	if !decodeSuccess(BuildSingBoxConfig()) || len(current.preparedSources) != 4 || current.preparedSources[0].ID != ownedprofile.Free+"-lv-quic" || current.preparedSources[1].ID != ownedprofile.Free+ownedprofile.MainSuffix || current.preparedSources[2].ID != ownedprofile.Free+ownedprofile.ExtraSuffix {
		t.Fatal("returning to automatic did not restore the Free transport order")
	}
}
