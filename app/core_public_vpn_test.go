package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

const managedFreeVPNTestURL = "https://free.example.com/sub/test-fixture"

type publicVPNTestTransport func(*http.Request) (*http.Response, error)

func (fn publicVPNTestTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func TestPublicVPNIsOptInAndConsentIsRequired(t *testing.T) {
	profile := ProfileData{}
	normalizeProfileVPNSources(&profile)
	if len(profile.VPNSources) != 0 {
		t.Fatal("public source was silently enabled for an empty profile")
	}
	provider := publicVPNProviders()[0]
	if err := addManagedVPNSource(&profile, provider.ID, provider.Name, managedFreeVPNTestURL, false); err == nil || len(profile.VPNSources) != 0 {
		t.Fatal("public feed requires explicit consent")
	}
	if err := addManagedVPNSource(&profile, "unknown", "Unknown", managedFreeVPNTestURL, true); err == nil {
		t.Fatal("unknown catalog entry accepted")
	}
	if err := addManagedVPNSource(&profile, provider.ID, provider.Name, managedFreeVPNTestURL, true); err != nil {
		t.Fatal(err)
	}
	if profile.VPNSources[0].URI != managedFreeVPNTestURL || profile.VPNSources[0].Disabled || profile.VPNSources[0].PublicCatalogID != managedFreeVPNProviderID {
		t.Fatal("explicitly added source was not configured")
	}
	if err := addManagedVPNSource(&profile, provider.ID, provider.Name, managedFreeVPNTestURL, true); err == nil || len(profile.VPNSources) != 1 {
		t.Fatal("duplicate public source accepted")
	}
}

func TestPublicVPNKeepsManualOrderIncludingLegacyCacheBuster(t *testing.T) {
	provider := retiredPublicVPNProvider()
	profile := ProfileData{VPNSources: []VPNSource{
		{ID: "free", URI: provider.URL + "?ts=123"},
		{ID: "personal-2", URI: "https://example.com/private-two", Disabled: true},
		{ID: "personal-1", URI: "https://example.com/private-one"},
	}}
	normalizeProfileVPNSources(&profile)
	got := []string{profile.VPNSources[0].ID, profile.VPNSources[1].ID, profile.VPNSources[2].ID}
	if !reflect.DeepEqual(got, []string{"free", "personal-2", "personal-1"}) {
		t.Fatalf("source order = %v", got)
	}
	if profile.SubscriptionURL != provider.URL {
		t.Fatal("summary does not follow the user's primary source")
	}
	if profile.VPNSources[0].URI != provider.URL || profile.VPNSources[0].PublicCatalogID != provider.ID {
		t.Fatal("legacy public URL not recognized")
	}
	profile.VPNSources[1].PublicCatalogID = provider.ID
	normalizeProfileVPNSources(&profile)
	if profile.VPNSources[1].PublicCatalogID != "" {
		t.Fatal("catalog identity must be derived from the actual source URL")
	}
}

func TestPublicVPNProviderDoesNotMatchLookalikeOrCredentialURLs(t *testing.T) {
	provider := retiredPublicVPNProvider()
	for _, uri := range []string{
		strings.Replace(provider.URL, "githubusercontent.com", "githubusercontent.com.evil.example", 1),
		strings.Replace(provider.URL, "https://", "http://", 1),
		strings.Replace(provider.URL, "https://", "https://user:pass@", 1),
		provider.URL + "?token=private",
		"https://example.com/sub/private",
	} {
		if _, ok := publicVPNProviderForURI(uri); ok {
			t.Fatal("unrecognized URI was labelled as public catalog source")
		}
	}
}

func TestPublicVPNFiltersUnsupportedAndLocalNodesWithoutChangingOrder(t *testing.T) {
	nodes := []ProxyConfig{
		{Type: "vless", Server: "127.0.0.1", ServerPort: 443},
		{Type: "vless", Server: "::ffff:192.168.1.1", ServerPort: 443},
		{Type: "vless", Server: "router.local", ServerPort: 443},
		{Type: "vless", Server: "example.com", ServerPort: 0},
		{Type: "vless", Server: "example.com", ServerPort: 443, Network: "kcp"},
		{Type: "vless", Server: "first.example.com", ServerPort: 443, Network: "xhttp", Name: "First"},
		{Type: "vless", Server: "second.example.com", ServerPort: 443, Name: "Second"},
		{Type: "vless", Server: "second.example.com", ServerPort: 443, Name: "Duplicate renamed"},
	}
	got := usablePublicVPNNodes(nodes)
	if len(got) != 2 || got[0].Name != "First" || got[1].Name != "Second" {
		t.Fatalf("usable public nodes = %+v", got)
	}
}

func publicVPNTestBuilder(t *testing.T, body string) (*Storage, *ConfigBuilderForStorage) {
	t.Helper()
	storage := NewStorage(t.TempDir())
	if err := storage.Init(); err != nil {
		t.Fatal(err)
	}
	builder := NewConfigBuilderForStorage(storage)
	builder.SetRoutingMode(storage.GetAppSettings().RoutingMode)
	builder.fetcher.client = &http.Client{Transport: publicVPNTestTransport(func(req *http.Request) (*http.Response, error) {
		if req.URL.String() != managedFreeVPNTestURL {
			return nil, fmt.Errorf("unexpected request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	return storage, builder
}

func TestPublicVPNBuildKeepsPersonalXHTTPFirstAndOneNodePerSource(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t,
		"vless://free-unsupported@free.example.com:443?type=kcp#unsupported\n"+
			"vless://free-one@free.example.com:443?security=tls#first\n"+
			"vless://free-two@free2.example.com:443?security=tls#second")
	personal, _ := newVPNSource("personal", "Personal", "vless://personal@personal.example.com:443?type=xhttp&security=tls#personal")
	profile := ProfileData{VPNSources: []VPNSource{personal}}
	if err := addManagedVPNSource(&profile, managedFreeVPNProviderID, "Dropo Free", managedFreeVPNTestURL, true); err != nil {
		t.Fatal(err)
	}
	if err := builder.BuildConfigForProfileSources(storage.GetActiveProfileID(), profile.VPNSources, nil); err != nil {
		t.Fatal(err)
	}
	saved, _ := storage.GetActiveProfile()
	if saved.VPNSources[0].ID != "personal" || saved.VPNSources[1].NodeCount != 2 {
		t.Fatalf("unexpected sources: personal=%s free node count=%d", saved.VPNSources[0].ID, saved.VPNSources[1].NodeCount)
	}
	config, _ := storage.GetProfileConfig(saved.ID)
	for _, value := range config["outbounds"].([]interface{}) {
		outbound := value.(map[string]interface{})
		if outbound["tag"] != "auto-select" {
			continue
		}
		if outbound["default"] != "vpn-source-personal" {
			t.Fatal("bootstrap selected public native node before personal XHTTP node")
		}
		if reflect.ValueOf(outbound["outbounds"]).Len() != 2 {
			t.Fatal("sibling nodes became independent automatic fallback levels")
		}
		return
	}
	t.Fatal("source selector is missing")
}

func TestPublicVPNOnlyProfileWorksAndCanRemoveLastSource(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	result := app.AddManagedVPNSource(managedFreeVPNProviderID, "Dropo Free", managedFreeVPNTestURL, true)
	if result["success"] != true {
		t.Fatalf("add failed: %v", result)
	}
	profile, _ := storage.GetActiveProfile()
	if profile.SubscriptionURL == "" || profile.ProxyCount != 1 {
		t.Fatal("free-only profile cannot provide VPN")
	}
	if result = app.RemoveVPNSource(profile.VPNSources[0].ID); result["success"] != true {
		t.Fatalf("remove failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if len(profile.VPNSources) != 0 || profile.SubscriptionURL != "" || profile.ProxyCount != 0 {
		t.Fatal("removing last source resurrected it via legacy subscription migration")
	}
}

func TestPublicVPNOfflineRefreshShowsCacheWithoutClaimingFreshness(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
	profile := ProfileData{}
	_ = addManagedVPNSource(&profile, managedFreeVPNProviderID, "Dropo Free", managedFreeVPNTestURL, true)
	if err := builder.BuildConfigForProfileSources(storage.GetActiveProfileID(), profile.VPNSources, nil); err != nil {
		t.Fatal(err)
	}
	profilePtr, _ := storage.GetActiveProfile()
	profilePtr.VPNSources[0].LastUpdated = "2026-09-01 12:00:00"
	builder.fetcher.client.Transport = publicVPNTestTransport(func(*http.Request) (*http.Response, error) {
		return nil, fmt.Errorf("offline")
	})
	if err := builder.BuildConfigForProfileSources(profilePtr.ID, profilePtr.VPNSources, nil); err != nil {
		t.Fatal(err)
	}
	saved, _ := storage.GetActiveProfile()
	source := saved.VPNSources[0]
	if !source.UsingCache || source.LastError == "" || source.LastUpdated != "2026-09-01 12:00:00" {
		t.Fatal("cached list presented as successfully refreshed")
	}
}

func TestPublicVPNCanBeDisabledAndMoveAbovePersonal(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t, "vless://test@free.example.com:443?security=tls#Free")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	if result := app.AddManagedVPNSource(managedFreeVPNProviderID, "Dropo Free", managedFreeVPNTestURL, true); result["success"] != true {
		t.Fatalf("add failed: %v", result)
	}
	profile, _ := storage.GetActiveProfile()
	freeID := profile.VPNSources[0].ID
	if result := app.SetVPNSourceEnabled(freeID, false); result["success"] != true {
		t.Fatalf("disable failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if len(profile.VPNSources) != 1 || !profile.VPNSources[0].Disabled || profile.SubscriptionURL != "" {
		t.Fatal("disabled public source still participates in VPN")
	}
	if result := app.SetVPNSourceEnabled(freeID, true); result["success"] != true {
		t.Fatalf("enable failed: %v", result)
	}
	if result := app.AddVPNSource("Personal", "vless://test@personal.example.com:443?security=tls"); result["success"] != true {
		t.Fatalf("add personal failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if profile.VPNSources[0].ID != freeID || profile.VPNSources[1].PublicCatalogID != "" {
		t.Fatal("adding a source unexpectedly changed existing priorities")
	}
	if result := app.MoveVPNSource(freeID, 1); result["success"] != true {
		t.Fatalf("move public below personal: %v", result)
	}
	if result := app.MoveVPNSource(freeID, 0); result["success"] != true {
		t.Fatalf("move public above personal: %v", result)
	}
	if err := storage.Load(); err != nil {
		t.Fatal(err)
	}
	profile, _ = storage.GetActiveProfile()
	if profile.VPNSources[0].ID != freeID {
		t.Fatal("reload discarded the user's public-first priority")
	}
	if profile.VPNSourceSelectionMode != "priority" {
		t.Fatal("explicit source reorder did not persist manual priority")
	}
	if got := app.configuredVPNSourceTags(); !reflect.DeepEqual(got, []string{"vpn-source-" + freeID, "vpn-source-" + profile.VPNSources[1].ID}) {
		t.Fatalf("monitor priority = %v", got)
	}
	if result := app.EnableVPNSourceAutoSelect(); result["success"] != true {
		t.Fatalf("enable automatic latency selection: %v", result)
	}
	if err := storage.Load(); err != nil {
		t.Fatal(err)
	}
	profile, _ = storage.GetActiveProfile()
	if profile.VPNSourceSelectionMode != "latency" || profile.VPNSources[0].ID != freeID {
		t.Fatal("automatic selection must persist without rewriting saved source order")
	}
}

func TestVPNSourceNodeChangeUsesIdentityFromDisplayedList(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t,
		"vless://one@one.example.com:443?security=tls#One\nvless://two@two.example.com:443?security=tls#Two")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	if result := app.AddManagedVPNSource(managedFreeVPNProviderID, "Dropo Free", managedFreeVPNTestURL, true); result["success"] != true {
		t.Fatalf("add failed: %v", result)
	}
	profile, _ := storage.GetActiveProfile()
	builder.fetcher.client.Transport = publicVPNTestTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(
			"vless://two@two.example.com:443?security=tls#Two-renamed\nvless://one@one.example.com:443?security=tls#One"))}, nil
	})
	if result := app.SetVPNSourceNode(profile.VPNSources[0].ID, 1); result["success"] != true {
		t.Fatalf("choose failed: %v", result)
	}
	profile, _ = storage.GetActiveProfile()
	if profile.VPNSources[0].SelectedNode != 0 || profile.VPNSources[0].NodeNames[0] != "Two-renamed" {
		t.Fatal("refreshed ordering changed the server explicitly chosen by the user")
	}
}

func TestVPNSourceSelectionSurvivesChangedLatencyLabels(t *testing.T) {
	fetcher := &SubscriptionFetcher{}
	one, _ := fetcher.ParseSingleLink("vless://one@one.example.com:443?security=tls#30ms")
	two, _ := fetcher.ParseSingleLink("vless://two@two.example.com:443?security=tls#40ms")
	source := VPNSource{SelectedNode: 1}
	markVPNSourceUpdated(&source, []ProxyConfig{one, two}, nil)
	twoRenamed, _ := fetcher.ParseSingleLink("vless://two@two.example.com:443?security=tls#99ms")
	markVPNSourceUpdated(&source, []ProxyConfig{twoRenamed, one}, nil)
	if source.SelectedNode != 0 || source.NodeNames[0] != "99ms" {
		t.Fatal("manual server selection lost after feed labels changed")
	}
}

func TestPublicVPNBridgeRequiresAuthentication(t *testing.T) {
	for _, method := range []string{"GetPublicVPNProviders", "AddPublicVPNSource", "AddManagedVPNSource"} {
		if _, exists := bridgeCallableMethods[method]; !exists {
			t.Fatalf("%s not exposed through guarded bridge", method)
		}
		req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1/api/call",
			strings.NewReader(fmt.Sprintf(`{"method":%q,"args":[]}`, method)))
		recorder := httptest.NewRecorder()
		newBridgeMux(&App{}, "test-token").ServeHTTP(recorder, req)
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s accepted an unauthenticated request: %d", method, recorder.Code)
		}
	}
}

func TestManagedFreeCatalogDoesNotExposeURIOrRecreateRetiredProvider(t *testing.T) {
	data, err := json.Marshal((&App{}).GetPublicVPNProviders())
	if err != nil || strings.Contains(string(data), "subscriptionUrl") || strings.Contains(string(data), "https://") || strings.Contains(string(data), "vpn-checker") {
		t.Fatal("offer leaked a URL or offered the retired aggregator")
	}
	for _, id := range []string{managedFreeVPNProviderID, retiredPublicVPNProvider().ID} {
		if result := (&App{}).AddPublicVPNSource(id, true); result["success"] != false {
			t.Fatal("old public API recreated a source")
		}
	}
}

func TestManagedFreeSourceValidationAndNormalizationDoNotConvertPersonalSources(t *testing.T) {
	for _, uri := range []string{"", "http://free.example.com/sub", "https://user:pass@free.example.com/sub", "vless://key@server.example.com:443", "https://free.example.com/sub#token"} {
		profile := ProfileData{}
		if err := addManagedVPNSource(&profile, managedFreeVPNProviderID, "Dropo Free", uri, true); err == nil || len(profile.VPNSources) != 0 {
			t.Fatal("invalid managed subscription accepted")
		}
	}
	profile := ProfileData{VPNSourceSelectionMode: "priority", VPNSources: []VPNSource{{ID: "personal", Name: "Own", URI: managedFreeVPNTestURL}}}
	normalizeProfileVPNSources(&profile)
	if profile.VPNSources[0].PublicCatalogID != "" {
		t.Fatal("personal URI auto-converted to managed provider")
	}
	profile.VPNSources[0].URI = "https://personal.example.com/sub/test-fixture"
	if err := addManagedVPNSource(&profile, managedFreeVPNProviderID, "Ignored", managedFreeVPNTestURL, true); err != nil {
		t.Fatal(err)
	}
	normalizeProfileVPNSources(&profile)
	if profile.VPNSourceSelectionMode != "priority" || profile.VPNSources[0].ID != "personal" || profile.VPNSources[1].PublicCatalogID != managedFreeVPNProviderID || profile.VPNSources[1].Name != "Dropo Free" {
		t.Fatal("managed addition changed manual priority or lost explicit metadata")
	}
}

func TestManagedFreeURLRejectsLocalDestinationsWithoutNetworkIO(t *testing.T) {

	for _, uri := range []string{
		"https://localhost/sub", "https://LOCALHOST./sub", "https://vpn.local/sub", "https://vpn.internal/sub", "https://vpn.lan/sub", "https://vpn/sub",
		"https://127.0.0.1/sub", "https://10.0.0.1/sub", "https://172.16.0.1/sub", "https://192.168.1.1/sub", "https://100.64.0.1/sub", "https://169.254.1.1/sub",
		"https://[::]/sub", "https://[::1]/sub", "https://[fd00::1]/sub", "https://[fe80::1]/sub", "https://[::ffff:127.0.0.1]/sub", "https://[::ffff:192.168.1.1]/sub",
	} {
		if validateManagedFreeVPNURL(uri) == nil {
			t.Fatal("local managed subscription accepted")
		}
	}
	for _, uri := range []string{"https://APP.EXAMPLE.COM./sub/test-fixture?token=fixture", "https://8.8.8.8/sub", "https://[2001:4860:4860::8888]/sub"} {
		if validateManagedFreeVPNURL(uri) != nil {
			t.Fatal("valid public managed subscription rejected")
		}
	}
}

func TestManagedFreeFetchFailuresNeverExposeURIOrChangePersonalErrors(t *testing.T) {
	_, builder := publicVPNTestBuilder(t, "")
	const failureDetail = "test-fixture-private-fetch-error"
	builder.fetcher.client.Transport = publicVPNTestTransport(func(*http.Request) (*http.Response, error) {
		return nil, fmt.Errorf(failureDetail)
	})
	source := VPNSource{URI: managedFreeVPNTestURL, PublicCatalogID: managedFreeVPNProviderID}
	if _, err := builder.fetchVPNSourceNodes(source); err == nil || strings.Contains(err.Error(), managedFreeVPNTestURL) || strings.Contains(err.Error(), failureDetail) {
		t.Fatal("managed fetch failure exposed private details")
	}
	source.LastError = "Get " + managedFreeVPNTestURL + ": " + failureDetail
	view, _ := json.Marshal(publicVPNSources([]VPNSource{source}))
	if strings.Contains(string(view), managedFreeVPNTestURL) || strings.Contains(string(view), failureDetail) {
		t.Fatal("managed source view exposed private fetch details")
	}
	source.PublicCatalogID = ""
	if _, err := builder.fetchVPNSourceNodes(source); err == nil || !strings.Contains(err.Error(), failureDetail) {
		t.Fatal("personal source errors unexpectedly changed")
	}
}
