package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

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
	if err := addPublicVPNSource(&profile, provider.ID, false); err == nil || len(profile.VPNSources) != 0 {
		t.Fatal("public feed requires explicit consent")
	}
	if err := addPublicVPNSource(&profile, "unknown", true); err == nil {
		t.Fatal("unknown catalog entry accepted")
	}
	if err := addPublicVPNSource(&profile, provider.ID, true); err != nil {
		t.Fatal(err)
	}
	if profile.VPNSources[0].URI != provider.URL || profile.VPNSources[0].Disabled {
		t.Fatal("explicitly added source was not configured")
	}
	if err := addPublicVPNSource(&profile, provider.ID, true); err == nil || len(profile.VPNSources) != 1 {
		t.Fatal("duplicate public source accepted")
	}
}

func TestPublicVPNKeepsManualOrderIncludingLegacyCacheBuster(t *testing.T) {
	provider := publicVPNProviders()[0]
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
	provider := publicVPNProviders()[0]
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
		if req.URL.String() != publicVPNProviders()[0].URL {
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
	if err := addPublicVPNSource(&profile, publicVPNProviders()[0].ID, true); err != nil {
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
	result := app.AddPublicVPNSource(publicVPNProviders()[0].ID, true)
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
	_ = addPublicVPNSource(&profile, publicVPNProviders()[0].ID, true)
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
	if result := app.AddPublicVPNSource(publicVPNProviders()[0].ID, true); result["success"] != true {
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
	if got := app.configuredVPNSourceTags(); !reflect.DeepEqual(got, []string{"vpn-source-" + freeID, "vpn-source-" + profile.VPNSources[1].ID}) {
		t.Fatalf("monitor priority = %v", got)
	}
}

func TestVPNSourceNodeChangeUsesIdentityFromDisplayedList(t *testing.T) {
	storage, builder := publicVPNTestBuilder(t,
		"vless://one@one.example.com:443?security=tls#One\nvless://two@two.example.com:443?security=tls#Two")
	app := &App{storage: storage, configBuilder: builder, initialized: true}
	app.initializedReady.Store(true)
	if result := app.AddPublicVPNSource(publicVPNProviders()[0].ID, true); result["success"] != true {
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
	for _, method := range []string{"GetPublicVPNProviders", "AddPublicVPNSource"} {
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

func TestPublicVPNFeedLiveParsing(t *testing.T) {
	if os.Getenv("DROPO_TEST_PUBLIC_FEED") != "1" {
		t.Skip("opt-in public data fetch; never starts a VPN engine")
	}
	nodes, err := NewSubscriptionFetcher().FetchAndParse(publicVPNProviders()[0].URL)
	if err != nil {
		t.Fatal(err)
	}
	usable := usablePublicVPNNodes(nodes)
	if len(usable) == 0 {
		t.Fatal("public feed contains no usable nodes")
	}
	t.Logf("Parsed %d nodes, retained %d supported unique public endpoints (reachability NOT tested)", len(nodes), len(usable))
}
