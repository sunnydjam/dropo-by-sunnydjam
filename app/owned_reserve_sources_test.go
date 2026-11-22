package main

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

const ownedReserveFixture = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"

func TestOwnedPairMigrationPreservesPersonalPriorityAndDisabledState(t *testing.T) {
	personal := VPNSource{ID: "personal", Name: "Personal", URI: testVPNSourceOld, SelectedNodeID: "chosen", FavoriteNodeIDs: []string{"favorite"}}
	profile := ProfileData{VPNSources: []VPNSource{personal, {ID: "old-free", PublicCatalogID: ownedprofile.Free, Name: "My Free", URI: ownedReserveFixture, Disabled: true}}, VPNSourceSelectionMode: "latency"}
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Free, ownedReserveFixture); err != nil {
		t.Fatal(err)
	}
	if len(profile.VPNSources) != 3 || !reflect.DeepEqual(profile.VPNSources[0], personal) || profile.VPNSources[1].ID != "old-free" || !profile.VPNSources[1].Disabled || !profile.VPNSources[2].Disabled || profile.VPNSourceSelectionMode != "latency" {
		t.Fatal("migration changed user's sources, disabled state or selection policy")
	}
	if profile.VPNSources[2].PublicCatalogID != ownedprofile.FreeReserve || profile.VPNSources[2].ID == "old-free" {
		t.Fatal("reserve not independent")
	}
	reserveID := profile.VPNSources[2].ID
	profile.VPNSources[1], profile.VPNSources[2] = profile.VPNSources[2], profile.VPNSources[1]
	refreshed := strings.ReplaceAll(ownedReserveFixture, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Free, refreshed); err != nil {
		t.Fatal(err)
	}
	if profile.VPNSources[1].ID != reserveID || !profile.VPNSources[1].Disabled || profile.VPNSourceSelectionMode != "latency" {
		t.Fatal("refresh erased explicit reserve ordering or disabled preference")
	}
	safe := settingsWithoutOwnedSecrets(&SettingsFile{Profiles: []ProfileData{profile}})
	data, _ := json.Marshal(safe)
	if strings.Contains(string(data), "aaaaaaaa-bbbb") || strings.Contains(string(data), "91.229.239.99") {
		t.Fatal("reserve credential leaked to ordinary settings")
	}
	profile.VPNSources = removeOwnedVPNFamily(profile.VPNSources, ownedprofile.FreeReserve)
	if len(profile.VPNSources) != 1 || !reflect.DeepEqual(profile.VPNSources[0], personal) {
		t.Fatal("family removal touched personal source or left resurrectable reference")
	}
}

func TestOwnedPairDefaultPriorityExpiryAndAtomicValidation(t *testing.T) {
	profile := ProfileData{}
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Free, ownedReserveFixture); err != nil {
		t.Fatal(err)
	}
	boost := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=1000")
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Boost, boost); err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{ownedprofile.Boost, ownedprofile.BoostReserve, ownedprofile.Free, ownedprofile.FreeReserve} {
		if profile.VPNSources[i].PublicCatalogID != id {
			t.Fatal("owned source priority changed")
		}
	}
	if !ownedSourceExpired(profile.VPNSources[0]) || !ownedSourceExpired(profile.VPNSources[1]) || ownedSourceExpired(profile.VPNSources[2]) || ownedSourceExpired(profile.VPNSources[3]) {
		t.Fatal("reserve changed entitlement expiry")
	}
	if profile.VPNSourceSelectionMode != "latency" {
		t.Fatal("fresh family must preserve automatic selection")
	}
	before := append([]VPNSource(nil), profile.VPNSources...)
	if err := upsertOwnedVPNPair(&profile, ownedprofile.FreeReserve, profile.VPNSources[3].URI); err == nil || !reflect.DeepEqual(before, profile.VPNSources) {
		t.Fatal("reserve injection partially modified list")
	}
}

func TestOwnedRestoreSnapshotRejectsDeletedOrRotatedFamily(t *testing.T) {
	profile := ProfileData{}
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Free, ownedReserveFixture); err != nil {
		t.Fatal(err)
	}
	before := append([]VPNSource(nil), profile.VPNSources...)
	profile.VPNSources[0].Disabled = true
	profile.VPNSources[0].Name = "Changed label"
	profile.VPNSources[0], profile.VPNSources[1] = profile.VPNSources[1], profile.VPNSources[0]
	if !ownedVPNFamilyUnchanged(before, profile.VPNSources, ownedprofile.Free) {
		t.Fatal("metadata change invalidated credential snapshot")
	}
	if ownedVPNFamilyUnchanged(before, nil, ownedprofile.Free) {
		t.Fatal("deleted family could be resurrected")
	}
	profile.VPNSources[0].URI = strings.ReplaceAll(profile.VPNSources[0].URI, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	if ownedVPNFamilyUnchanged(before, profile.VPNSources, ownedprofile.Free) {
		t.Fatal("stale key could overwrite rotated family")
	}
}

func TestOwnedLegacyReserveMigrationDoesNotReorderExistingProducts(t *testing.T) {
	boost := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	for _, freeFirst := range []bool{true, false} {
		for _, target := range []string{ownedprofile.Free, ownedprofile.Boost} {
			free := VPNSource{ID: "old-free", PublicCatalogID: ownedprofile.Free, URI: ownedReserveFixture, Disabled: true}
			paid := VPNSource{ID: "old-boost", PublicCatalogID: ownedprofile.Boost, URI: boost}
			personal := VPNSource{ID: "personal", URI: testVPNSourceOld, Name: "Personal"}
			before := []VPNSource{free, personal, paid}
			if !freeFirst {
				before = []VPNSource{paid, personal, free}
			}
			profile := ProfileData{VPNSources: append([]VPNSource(nil), before...), VPNSourceSelectionMode: "priority"}
			key := ownedReserveFixture
			if target == ownedprofile.Boost {
				key = boost
			}
			if err := upsertOwnedVPNPair(&profile, target, key); err != nil {
				t.Fatal(err)
			}
			var retained []VPNSource
			for i, s := range profile.VPNSources {
				if ownedprofile.IsReserve(s.PublicCatalogID) {
					if i == 0 || profile.VPNSources[i-1].PublicCatalogID != target || s.Disabled != profile.VPNSources[i-1].Disabled {
						t.Fatal("reserve is not adjacent to its original primary")
					}
				} else {
					retained = append(retained, s)
				}
			}
			if !reflect.DeepEqual(retained, before) {
				t.Fatal("reserve migration reordered or modified existing products/personal source")
			}
		}
	}
}

func TestOwnedPairWindowsLifecycleAndIndependentSelector(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	if result := app.AddManagedVPNSource(ownedprofile.Free, "ignored", ownedReserveFixture, true); result["success"] != true {
		t.Fatalf("managed pair add failed: %v", result)
	}
	profile, _ := storage.GetActiveProfile()
	if len(profile.VPNSources) != 2 {
		t.Fatal("missing independent managed ingress")
	}
	for _, s := range profile.VPNSources {
		if s.NodeCount != 1 {
			t.Fatal("reserve is not one authoritative source node")
		}
	}
	config, _ := storage.GetProfileConfig(profile.ID)
	found := false
	for _, raw := range config["outbounds"].([]interface{}) {
		out := raw.(map[string]interface{})
		if out["tag"] == "auto-select" {
			found = true
			if reflect.ValueOf(out["outbounds"]).Len() != 2 {
				t.Fatal("reserve missing from selector")
			}
		}
	}
	if !found {
		t.Fatal("source selector missing")
	}
	primary := profile.VPNSources[0].ID
	if result := app.SetVPNSourceEnabled(primary, false); result["success"] != true {
		t.Fatalf("disable failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if !profile.VPNSources[0].Disabled || !profile.VPNSources[1].Disabled {
		t.Fatal("disabled primary left reserve active")
	}
	if result := app.SetVPNSourceEnabled(primary, true); result["success"] != true {
		t.Fatalf("enable failed: %v", result)
	}
	if result := app.RemoveVPNSource(primary); result["success"] != true {
		t.Fatalf("family remove failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if len(profile.VPNSources) != 0 {
		t.Fatal("family removal left a source reference")
	}
}

func TestOwnedRestoreGuardsUIReferenceAndCredentialRotation(t *testing.T) {
	boostFixture := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	requireAPISuccess(t, app.AddManagedVPNSource(ownedprofile.Boost, "ignored", boostFixture, true))
	observed, _ := storage.GetActiveProfile()
	ref := observed.VPNSources[0]
	requireAPISuccess(t, app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, ref.ID, ref.NodeIDs[ref.SelectedNode]))
	requireAPISuccess(t, app.RemoveVPNSource(ref.ID))
	if app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, ref.ID, ref.NodeIDs[ref.SelectedNode])["success"] == true {
		t.Fatal("UI snapshot recreated deleted family")
	}
	after, _ := storage.GetActiveProfile()
	if len(after.VPNSources) != 0 {
		t.Fatal("restore mutated deleted family")
	}
	for _, replacement := range []string{
		strings.ReplaceAll(boostFixture, "expiry=4102444800", "expiry=4202444800"),
		strings.ReplaceAll(boostFixture, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
	} {
		requireAPISuccess(t, app.AddManagedVPNSource(ownedprofile.Boost, "ignored", replacement, true))
		live, _ := storage.GetActiveProfile()
		reference := live.VPNSources[0]
		if app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, reference.ID, reference.NodeIDs[reference.SelectedNode])["success"] == true {
			t.Fatal("stale vault overwrote live credential/expiry")
		}
		after, _ := storage.GetActiveProfile()
		if !reflect.DeepEqual(after.VPNSources, live.VPNSources) {
			t.Fatal("failed restore changed live sources")
		}
	}
	live, _ := storage.GetActiveProfile()
	safe := settingsWithoutOwnedSecrets(&SettingsFile{Profiles: []ProfileData{*live}}).Profiles[0]
	// Persisted reference after restart has no key or node fingerprint.
	if err := storage.UpdateProfileVPNSources(safe.ID, safe.VPNSources, safe.WireGuardConfigs); err != nil {
		t.Fatal(err)
	}
	requireAPISuccess(t, app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, safe.VPNSources[0].ID, ""))
	if app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, "", "")["success"] == true {
		t.Fatal("empty reference accepted")
	}
	if _, ok := bridgeCallableMethods["RestoreManagedVPNSource"]; !ok {
		t.Fatal("restore missing from bridge")
	}
}

func TestOwnedOrphanReserveKeepsExistingOrder(t *testing.T) {
	_, reserve, err := ownedprofile.Pair(ownedprofile.Free, ownedReserveFixture)
	if err != nil {
		t.Fatal(err)
	}
	before := []VPNSource{
		{ID: "reserve", PublicCatalogID: ownedprofile.FreeReserve, URI: reserve, Disabled: true},
		{ID: "personal", URI: testVPNSourceOld},
		{ID: "boost", PublicCatalogID: ownedprofile.Boost},
	}
	profile := ProfileData{VPNSources: append([]VPNSource(nil), before...)}
	if err := upsertOwnedVPNPair(&profile, ownedprofile.Free, ownedReserveFixture); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(profile.VPNSources[:3], before) {
		t.Fatal("orphan reserve restoration reordered existing sources")
	}
}

func TestEnrollingBoostKeepsPreferredFreeRelay(t *testing.T) {
	p := ProfileData{}
	if err := upsertOwnedVPNPair(&p, ownedprofile.Free, ownedReserveFixture); err != nil {
		t.Fatal(err)
	}
	p.VPNSources[0], p.VPNSources[1] = p.VPNSources[1], p.VPNSources[0]
	p.VPNSourceSelectionMode = "priority"
	boost := strings.ReplaceAll(strings.ReplaceAll(ownedReserveFixture, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=4102444800")
	if err := upsertOwnedVPNPair(&p, ownedprofile.Boost, boost); err != nil {
		t.Fatal(err)
	}
	views := publicVPNSources(p.VPNSources)
	want := []string{ownedprofile.FreeReserve, ownedprofile.Free, ownedprofile.Boost, ownedprofile.BoostReserve}
	if len(views) != len(want) {
		t.Fatalf("got %d source rows", len(views))
	}
	for i, id := range want {
		if views[i]["public_catalog_id"] != id {
			t.Fatalf("row %d should be %s", i, id)
		}
	}
}

func TestWindowsOrphanMigrationRequiresVaultRestore(t *testing.T) {
	p := ProfileData{VPNSources: []VPNSource{{ID: "old", Name: "legacy", PublicCatalogID: ownedprofile.BoostReserve, URI: ownedReserveFixture, Disabled: true}}}
	normalizeProfileVPNSources(&p)
	if len(p.VPNSources) != 1 {
		t.Fatal("lost vault restore reference")
	}
	source := p.VPNSources[0]
	if source.ID != "old" || !source.Disabled || source.PublicCatalogID != ownedprofile.Boost || source.URI != "" {
		t.Fatal("orphaned reserve was promoted to a credential or lost its preference")
	}
}

func TestWindowsLatviaMigrationAndEntitlement(t *testing.T) {
	boost := strings.NewReplacer("%2Ffree", "%2Fboost", "expiry=0", "expiry=4102444800").Replace(ownedReserveFixture)
	p := ProfileData{VPNSourceSelectionMode: "priority"}
	for _, product := range []struct{ id, key string }{{ownedprofile.Free, ownedReserveFixture}, {ownedprofile.Boost, boost}} {
		if err := upsertOwnedVPNPair(&p, product.id, product.key); err != nil {
			t.Fatal(err)
		}
	}
	p.VPNSources[0], p.VPNSources[3] = p.VPNSources[3], p.VPNSources[0]
	personal := VPNSource{ID: "import", Kind: VPNSourceDirect, URI: testVPNSourceOld, Name: "Private"}
	p.VPNSources = append([]VPNSource{{ID: "old-fi", PublicCatalogID: ownedprofile.Free + "-fi-tcp"}, personal}, p.VPNSources...)
	p.SingboxConfig = map[string]interface{}{"stale": true}
	normalizeProfileVPNSources(&p)
	if len(p.VPNSources) != 3 || p.VPNSources[0].PublicCatalogID != ownedprofile.Free || p.VPNSources[1].ID != personal.ID || p.VPNSources[2].PublicCatalogID != ownedprofile.Boost || p.SingboxConfig != nil {
		t.Fatal("migration lost order, personal source or reused a stale graph")
	}
	first := p.VPNSources[2].ID
	p.VPNSources[2].Disabled = true
	rotated := strings.ReplaceAll(boost, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	if err := upsertWindowsOwnedSources(&p, ownedprofile.Boost, rotated); err != nil || p.VPNSources[2].ID != first || !p.VPNSources[2].Disabled {
		t.Fatal("rotation changed manual or disabled preference")
	}
	expired := p.VPNSources[2]
	expired.URI = strings.ReplaceAll(rotated, "4102444800", "1")
	if _, err := windowsRegionalURI(expired); err == nil || publicVPNSources([]VPNSource{expired})[0]["reference_only"] != true {
		t.Fatal("expired Boost available")
	}
}

func TestWindowsOwnedReservesRemainInRuntimeSelectorWithCachedServiceProbe(t *testing.T) {
	boost := strings.Replace(ownedReserveFixture, "%2Ffree", "%2Fboost", 1)
	boost = strings.Replace(boost, "expiry=0", "expiry="+strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10), 1)
	for _, tier := range []struct{ id, key string }{
		{ownedprofile.Free, ownedReserveFixture},
		{ownedprofile.Boost, boost},
	} {
		for _, mode := range []RoutingMode{RoutingModeBlockedOnly, RoutingModeAllTraffic} {
			t.Run(tier.id+"/"+string(mode), func(t *testing.T) {
				storage, builder := publicVPNTestBuilder(t, "")
				app := &App{storage: storage, configBuilder: builder, initialized: true}
				app.initializedReady.Store(true)
				requireAPISuccess(t, app.SetRoutingMode(string(mode)))
				requireAPISuccess(t, app.AddManagedVPNSource(tier.id, "Managed", tier.key, true))

				profile, err := storage.GetActiveProfile()
				if err != nil {
					t.Fatal(err)
				}
				if len(profile.VPNSources) != 2 || profile.VPNSources[1].PublicCatalogID != tier.id+ownedprofile.MainSuffix {
					t.Fatal("expected regional and restored main ingress")
				}
				want := []string{"vpn-source-" + profile.VPNSources[0].ID, "vpn-source-" + profile.VPNSources[1].ID}
				app.rememberRouteProbeResults([]routeProbeServiceResult{
					{Tag: "openai", Success: true, MethodKind: "vpn", MethodTag: want[0]},
				})
				path, err := app.getActiveConfigPath()
				if err != nil {
					t.Fatal(err)
				}
				if shouldUseSelectiveWindowsSession(storage.GetAppSettings()) {
					path, err = app.writeDeepWindowsProxyFallbackConfig(path)
					if err != nil {
						t.Fatal(err)
					}
				}
				config, err := readJSONConfig(path)
				if err != nil {
					t.Fatal(err)
				}
				selector := getOutbound(config, "auto-select")
				if got := interfaceStringSlice(selector["outbounds"]); !reflect.DeepEqual(got, want) || selector["type"] != "selector" || selector["default"] != want[0] {
					t.Fatalf("runtime selector lost independent transports: %v", got)
				}
				protocol := "hysteria2"
				if tier.id == ownedprofile.Boost {
					protocol = "socks"
				}
				for i := range want {
					if i == 1 {
						protocol = "socks"
					}
					if getOutbound(config, want[i])["type"] != protocol {
						t.Fatalf("unexpected runtime transport at position %d", i)
					}
					if _, ok := app.vpnSourceProbeBinding(want[i]); !ok {
						t.Fatalf("monitor cannot switch to candidate at position %d", i)
					}
				}
				if tier.id == ownedprofile.Boost {
					bridge, err := storage.GetProfileXrayConfig(profile.ID)
					if err != nil {
						t.Fatal(err)
					}
					stream, _ := getOutbound(bridge, "xray-out-0")["streamSettings"].(map[string]any)
					if stream["network"] != "tcp" {
						t.Fatal("Finland REALITY missing")
					}
					fast := getOutbound(bridge, "xray-out-0-fi-fast")
					if fast == nil || getOutbound(bridge, "fi-quic-"+profile.VPNSources[0].ID) == nil {
						t.Fatal("fast Finnish route is missing")
					}
					balancers := bridge["routing"].(map[string]any)["balancers"].([]any)
					bal := balancers[0].(map[string]any)
					if bal["fallbackTag"] != "xray-out-0" || !reflect.DeepEqual(interfaceStringSlice(bal["selector"]), []string{"xray-out-0-fi-fast"}) {
						t.Fatal("Finnish route lost its verified fallback")
					}
					if tags := interfaceStringSlice(bridge["observatory"].(map[string]any)["subjectSelector"]); !reflect.DeepEqual(tags, []string{"xray-out-0-fi-fast"}) {
						t.Fatal("health probe did not use the complete fast path")
					}
					hosts := collectXrayEndpointHosts(bridge)
					if !slices.Contains(hosts, "62.72.20.9") || !slices.Contains(hosts, ownedprofile.ReserveIPv4) || slices.Contains(hosts, "77.42.65.119") {
						t.Fatal("only the two physical ingress addresses may bypass TUN")
					}
					if getOutbound(bridge, "fi-carrier-"+profile.VPNSources[0].ID) == nil {
						t.Fatal("Finland HTTPS carrier missing")
					}
				}
			})
		}
	}
}

// Reproduce the on-disk family shape used before regional tiers.
func upsertOwnedVPNPair(profile *ProfileData, provider, raw string) error {
	reserveID, reserve, err := ownedprofile.Pair(provider, raw)
	if err != nil {
		return fmt.Errorf("Некорректный профиль Dropo")
	}
	sources := append([]VPNSource(nil), profile.VPNSources...)
	wasEmpty := len(sources) == 0
	seen := map[string]bool{}
	for _, s := range sources {
		if s.PublicCatalogID == provider || s.PublicCatalogID == reserveID {
			if seen[s.PublicCatalogID] {
				return fmt.Errorf("Дублирующийся профиль Dropo")
			}
			seen[s.PublicCatalogID] = true
		}
	}
	primaryIndex := -1
	for _, item := range []struct{ id, uri string }{{provider, raw}, {reserveID, reserve}} {
		index := -1
		for i, s := range sources {
			if s.PublicCatalogID == item.id {
				index = i
				break
			}
		}
		var source VPNSource
		if index >= 0 && sources[index].URI == item.uri {
			source = sources[index]
		} else {
			source, err = newVPNSource(nextVPNSourceID(sources), ownedprofile.Name(item.id), item.uri)
			if err != nil {
				return fmt.Errorf("Некорректный профиль Dropo")
			}
			source.PublicCatalogID = item.id
			if index >= 0 {
				source.ID, source.Disabled, source.Name = sources[index].ID, sources[index].Disabled, sources[index].Name
			}
		}
		if index >= 0 {
			sources[index] = source
		} else if item.id == reserveID {
			source.Disabled = sources[primaryIndex].Disabled
			index = primaryIndex + 1
			sources = append(sources, VPNSource{})
			copy(sources[index+1:], sources[index:])
			sources[index] = source
		} else {
			// An orphan reserve still represents the user's product preference.
			for _, sibling := range sources {
				if sibling.PublicCatalogID == reserveID {
					source.Disabled = sibling.Disabled
					break
				}
			}
			index = len(sources)
			sources = append(sources, source)
		}
		if item.id == provider {
			primaryIndex = index
		}
	}
	var positions []int
	var managed []VPNSource
	for i, s := range sources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			positions = append(positions, i)
			managed = append(managed, s)
		}
	}
	// Only a newly enrolled product gets the default product priority. Adding
	// a missing reserve to an existing primary must preserve its saved order.
	if !seen[provider] && !seen[reserveID] && profile.VPNSourceSelectionMode != "priority" {
		sort.SliceStable(managed, func(i, j int) bool {
			return ownedprofile.Priority(managed[i].PublicCatalogID) < ownedprofile.Priority(managed[j].PublicCatalogID)
		})
		for i, p := range positions {
			sources[p] = managed[i]
		}
	}
	profile.VPNSources = sources
	if wasEmpty && profile.VPNSourceSelectionMode == "" {
		profile.VPNSourceSelectionMode = "latency"
	}
	return nil
}
