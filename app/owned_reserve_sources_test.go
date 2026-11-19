package main

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"reflect"
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
	if len(profile.VPNSources) != 3 {
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
			if reflect.ValueOf(out["outbounds"]).Len() != 3 {
				t.Fatal("reserve missing from selector")
			}
		}
	}
	if !found {
		t.Fatal("source selector missing")
	}
	primary, reserve := profile.VPNSources[0].ID, profile.VPNSources[1].ID
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
	if result := app.RemoveVPNSource(reserve); result["success"] != true {
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
	requireAPISuccess(t, app.RestoreManagedVPNSource(ownedprofile.Boost, boostFixture, safe.VPNSources[1].ID, ""))
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

func TestWindowsLatviaMigrationAndEntitlement(t *testing.T) {
	boost := strings.NewReplacer("%2Ffree", "%2Fboost", "expiry=0", "expiry=4102444800").Replace(ownedReserveFixture)
	p := ProfileData{VPNSourceSelectionMode: "priority"}
	for _, product := range []struct{ id, key string }{{ownedprofile.Free, ownedReserveFixture}, {ownedprofile.Boost, boost}} {
		if err := upsertOwnedVPNPair(&p, product.id, product.key); err != nil {
			t.Fatal(err)
		}
	}
	p.VPNSources[0], p.VPNSources[3] = p.VPNSources[3], p.VPNSources[0]
	original := append([]VPNSource(nil), p.VPNSources...)
	for _, product := range []struct{ id, key string }{{ownedprofile.Free, ownedReserveFixture}, {ownedprofile.Boost, boost}} {
		if err := upsertWindowsOwnedSources(&p, product.id, product.key); err != nil {
			t.Fatal(err)
		}
	}
	if len(p.VPNSources) != 6 || !reflect.DeepEqual(original, p.VPNSources[:4]) {
		t.Fatal("migration changed original four priorities")
	}
	for _, i := range []int{4, 5} {
		source := p.VPNSources[i]
		raw, err := windowsLatviaURI(source)
		if err != nil {
			t.Fatal(err)
		}
		node, err := (&SubscriptionFetcher{}).ParseSingleLink(raw)
		if err != nil || node.Type != "hysteria2" || strings.Contains(raw, "11111111-2222-3333-4444-555555555555") {
			t.Fatal("invalid transport or credential scope")
		}
		safe := settingsWithoutOwnedSecrets(&SettingsFile{Profiles: []ProfileData{p}})
		bytes, _ := json.Marshal(safe)
		if strings.Contains(string(bytes), "11111111-2222-3333-4444-555555555555") || safe.Profiles[0].VPNSources[i].URI != "" {
			t.Fatal("managed credential persisted")
		}
	}
	p.VPNSources[0], p.VPNSources[5] = p.VPNSources[5], p.VPNSources[0]
	id := p.VPNSources[0].ID
	p.VPNSources[0].Disabled = true
	rotated := strings.ReplaceAll(boost, "11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
	if err := upsertWindowsOwnedSources(&p, ownedprofile.Boost, rotated); err != nil {
		t.Fatal(err)
	}
	if p.VPNSources[0].ID != id || !p.VPNSources[0].Disabled || p.VPNSources[0].URI != rotated {
		t.Fatal("rotation lost manual preference")
	}
	expired := strings.ReplaceAll(boost, "4102444800", "1")
	expiredSource := p.VPNSources[0]
	expiredSource.URI = expired
	if _, err := windowsLatviaURI(expiredSource); err == nil || len(publicVPNSources([]VPNSource{expiredSource})) != 0 {
		t.Fatal("expired fast entitlement remains available")
	}
	if err := upsertWindowsOwnedSources(&p, ownedprofile.Boost, expired); err != nil {
		t.Fatal(err)
	}
	if len(p.VPNSources) != 5 {
		t.Fatal("expiry affected other sources or retained fast Boost")
	}
	var orphan []VPNSource
	for _, source := range p.VPNSources {
		if isLatviaProvider(source.PublicCatalogID) {
			orphan = append(orphan, source)
		}
	}
	if len(orphan) != 1 {
		t.Fatal("remaining Free route missing")
	}
	normalizePublicVPNSourceMetadata(orphan)
	if !isLatviaProvider(orphan[0].PublicCatalogID) || orphan[0].URI != "" {
		t.Fatal("orphan retained a usable credential")
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
				want := []string{
					"vpn-source-" + profile.VPNSources[0].ID,
					"vpn-source-" + profile.VPNSources[1].ID,

					"vpn-source-" + profile.VPNSources[2].ID,
				}
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
				for i, protocol := range []string{"socks", "socks", "hysteria2"} {
					if getOutbound(config, want[i])["type"] != protocol {
						t.Fatalf("unexpected runtime transport at position %d", i)
					}
					if _, ok := app.vpnSourceProbeBinding(want[i]); !ok {
						t.Fatalf("monitor cannot switch to candidate at position %d", i)
					}
				}
				bridge, err := storage.GetProfileXrayConfig(profile.ID)
				if err != nil {
					t.Fatal(err)
				}
				for _, tag := range []string{"xray-out-0", "xray-out-1"} {
					outbound := getOutbound(bridge, tag)
					transport, _ := outbound["streamSettings"].(map[string]interface{})
					if transport["network"] != "xhttp" {
						t.Fatal("XHTTP ingress lost its Xray transport")
					}
				}
			})
		}
	}
}
