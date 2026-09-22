package dropocore

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestAndroidCoreLifecycle(t *testing.T) {
	mu.Lock()
	current = defaultState()
	mu.Unlock()

	if ok := decodeSuccess(EnsureStarted(t.TempDir(), "2.1.3")); !ok {
		t.Fatal("EnsureStarted success = false")
	}
	if ok := decodeSuccess(SetConnected(true)); !ok {
		t.Fatal("SetConnected(true) success = false")
	}

	var status map[string]interface{}
	if err := json.Unmarshal([]byte(Status()), &status); err != nil {
		t.Fatal(err)
	}
	if status["connected"] != true {
		t.Fatalf("connected = %v, want true", status["connected"])
	}
	if status["networkMode"] != "android_vpn" {
		t.Fatalf("networkMode = %v, want android_vpn", status["networkMode"])
	}
}

func TestAndroidCoreSubscriptionCall(t *testing.T) {
	mu.Lock()
	current = defaultState()
	mu.Unlock()

	args := `["vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#demo"]`
	var check map[string]interface{}
	if err := json.Unmarshal([]byte(Call("TestVPNConnection", args)), &check); err != nil {
		t.Fatal(err)
	}
	if check["success"] != true || check["count"] != float64(1) || check["isDirectLink"] != true {
		t.Fatalf("direct VPN key check = %#v, want one verified proxy", check)
	}
	if _, exists := check["proxies"]; exists {
		t.Fatalf("direct VPN key check exposed proxy details: %#v", check)
	}
	if ok := decodeSuccess(Call("SetVPNSubscription", args)); !ok {
		t.Fatal("SetVPNSubscription success = false")
	}

	var sub map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetCurrentSubscription", "[]")), &sub); err != nil {
		t.Fatal(err)
	}
	if sub["hasSubscription"] != true {
		t.Fatalf("hasSubscription = %v, want true", sub["hasSubscription"])
	}
	if sub["proxyCount"].(float64) != 1 {
		t.Fatalf("proxyCount = %v, want 1", sub["proxyCount"])
	}
	if ok := decodeSuccess(Call("RemoveVPNSubscription", "[]")); !ok {
		t.Fatal("RemoveVPNSubscription success = false")
	}
	if err := json.Unmarshal([]byte(Call("GetCurrentSubscription", "[]")), &sub); err != nil {
		t.Fatal(err)
	}
	if sub["hasSubscription"] != false || sub["proxyCount"] != float64(0) {
		t.Fatalf("removed subscription = %#v, want empty with zero verified proxies", sub)
	}
	mu.Lock()
	verifiedAfterRemove := current.testedSubscriptionValid
	mu.Unlock()
	if verifiedAfterRemove {
		t.Fatal("removing the subscription retained stale test verification")
	}
}

func TestAndroidVPNConnectionDownloadsHTTPSSubscriptionWithoutHoldingStateLock(t *testing.T) {
	mu.Lock()
	current = defaultState()
	mu.Unlock()

	requestStarted := make(chan struct{})
	releaseRequest := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseRequest) }) }
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		close(requestStarted)
		<-releaseRequest
		_, _ = w.Write([]byte(strings.Join([]string{
			"vless://00000000-0000-0000-0000-000000000001@one.example.com:443?security=tls#one",
			"trojan://private-password@two.example.com:443?security=tls#two",
		}, "\n")))
	}))
	defer server.Close()
	defer release()

	serverClient := server.Client()
	previousFactory := androidSubscriptionTestFetcherFactory
	androidSubscriptionTestFetcherFactory = func() *subscriptionFetcher {
		fetcher := newSubscriptionFetcher()
		fetcher.client.Transport = serverClient.Transport
		fetcher.client.Timeout = 5 * time.Second
		return fetcher
	}
	defer func() { androidSubscriptionTestFetcherFactory = previousFactory }()

	callDone := make(chan string, 1)
	go func() {
		callDone <- Call("TestVPNConnection", `["`+server.URL+`/subscription/private-token"]`)
	}()

	select {
	case <-requestStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("HTTPS subscription request did not start")
	}

	statusDone := make(chan string, 1)
	go func() { statusDone <- Status() }()
	select {
	case response := <-statusDone:
		if !decodeSuccess(response) {
			t.Fatalf("Status() while subscription download is pending = %s", response)
		}
	case <-time.After(time.Second):
		release()
		t.Fatal("TestVPNConnection held the global state lock during HTTPS download")
	}

	release()
	var response map[string]interface{}
	var rawResponse string
	select {
	case raw := <-callDone:
		rawResponse = raw
		if err := json.Unmarshal([]byte(raw), &response); err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("TestVPNConnection did not finish after HTTPS response was released")
	}
	if response["success"] != true || response["count"] != float64(2) || response["isDirectLink"] != false {
		t.Fatalf("HTTPS subscription result = %#v, want two verified proxies", response)
	}
	if _, exists := response["proxies"]; exists {
		t.Fatalf("HTTPS subscription result exposed proxy details: %#v", response)
	}
	for _, secret := range []string{"private-password", "one.example.com", "two.example.com"} {
		if strings.Contains(rawResponse, secret) {
			t.Fatalf("HTTPS subscription result leaked %q: %s", secret, rawResponse)
		}
	}
}

func TestAndroidVerifiedSubscriptionCountPersistsAfterExactSetAndReload(t *testing.T) {
	const secret = "verified-count-private-token"
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Join([]string{
			"vless://00000000-0000-0000-0000-000000000021@one.example.com:443?security=tls#one",
			"trojan://verified-password@two.example.com:443?security=tls#two",
		}, "\n")))
	}))
	defer server.Close()
	installAndroidSubscriptionTestTransport(t, server.Client())

	basePath := t.TempDir()
	input := server.URL + "/subscription/" + secret
	mu.Lock()
	current = defaultState()
	current.BasePath = basePath
	mu.Unlock()

	checkRaw := Call("TestVPNConnection", `["`+input+`"]`)
	var check map[string]interface{}
	if err := json.Unmarshal([]byte(checkRaw), &check); err != nil {
		t.Fatal(err)
	}
	if check["success"] != true || check["count"] != float64(2) {
		t.Fatalf("verified subscription = %#v, want count 2", check)
	}
	if _, exists := check["proxies"]; exists || strings.Contains(checkRaw, "verified-password") {
		t.Fatalf("subscription check exposed proxy credentials: %s", checkRaw)
	}

	var saved map[string]interface{}
	if err := json.Unmarshal([]byte(Call("SetVPNSubscription", `["`+input+`"]`)), &saved); err != nil {
		t.Fatal(err)
	}
	if saved["success"] != true || saved["proxyCount"] != float64(2) {
		t.Fatalf("exact verified subscription was not saved with count 2: %#v", saved)
	}
	assertAndroidSubscriptionCount(t, 2)

	mu.Lock()
	current = defaultState()
	current.BasePath = basePath
	loadErr := loadLocked()
	verificationRestored := current.testedSubscriptionValid
	mu.Unlock()
	if loadErr != nil {
		t.Fatal(loadErr)
	}
	if verificationRestored {
		t.Fatal("transient subscription verification was persisted")
	}
	assertAndroidSubscriptionCount(t, 2)
}

func TestAndroidVerifiedSubscriptionCountDoesNotCarryToDifferentInput(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Join([]string{
			"vless://00000000-0000-0000-0000-000000000031@one.example.com:443?security=tls#one",
			"vless://00000000-0000-0000-0000-000000000032@two.example.com:443?security=tls#two",
			"trojan://mismatch-password@three.example.com:443?security=tls#three",
		}, "\n")))
	}))
	defer server.Close()
	installAndroidSubscriptionTestTransport(t, server.Client())

	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()
	testedInput := server.URL + "/subscription/tested"
	if result := Call("TestVPNConnection", `["`+testedInput+`"]`); !decodeSuccess(result) {
		t.Fatalf("subscription verification failed: %s", result)
	}

	const differentInput = "https://127.0.0.1:1/subscription/different"
	var saved map[string]interface{}
	if err := json.Unmarshal([]byte(Call("SetVPNSubscription", `["`+differentInput+`"]`)), &saved); err != nil {
		t.Fatal(err)
	}
	if saved["success"] != true || saved["proxyCount"] != float64(0) {
		t.Fatalf("different subscription inherited a verified count: %#v", saved)
	}
	assertAndroidSubscriptionCount(t, 0)
}

func TestAndroidVPNConnectionErrorsDoNotLeakSubscriptionInput(t *testing.T) {
	const secret = "private-subscription-secret"
	for _, input := range []string{
		"vless://" + secret,
		"http://example.test/" + secret,
		"https://user:" + secret + "@example.test/subscription",
	} {
		mu.Lock()
		current = defaultState()
		mu.Unlock()

		response := Call("TestVPNConnection", `["`+input+`"]`)
		if decodeSuccess(response) {
			t.Fatalf("invalid subscription input was accepted: %s", subscriptionSummary(input))
		}
		if strings.Contains(response, secret) {
			t.Fatalf("subscription error leaked input: %s", response)
		}
		if logs := Logs(); strings.Contains(logs, secret) {
			t.Fatalf("subscription error log leaked input: %s", logs)
		}
	}
}

func TestAndroidSetSubscriptionUsesLocalValidationOnly(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	if response := Call("SetVPNSubscription", `["http://example.test/private"]`); decodeSuccess(response) {
		t.Fatalf("insecure subscription URL was accepted: %s", response)
	}
	if response := Call("SetVPNSubscription", `["vless://private-key"]`); decodeSuccess(response) {
		t.Fatalf("malformed direct VPN key was accepted: %s", response)
	}

	// This endpoint is intentionally unreachable. SetVPNSubscription only
	// validates the HTTPS URL locally; the explicit TestVPNConnection call owns
	// downloading and parsing the remote subscription.
	const offlineURL = "https://127.0.0.1:1/private-subscription"
	if response := Call("SetVPNSubscription", `["`+offlineURL+`"]`); !decodeSuccess(response) {
		t.Fatalf("locally valid HTTPS subscription was not saved: %s", response)
	}
	mu.Lock()
	defer mu.Unlock()
	if current.Subscription != offlineURL {
		t.Fatalf("saved subscription = %q, want locally validated HTTPS URL", current.Subscription)
	}
	if current.SubscriptionProxyCount != 0 {
		t.Fatalf("unverified HTTPS proxy count = %d, want 0", current.SubscriptionProxyCount)
	}
}

func TestAndroidLoadedSubscriptionCountMigratesLegacyState(t *testing.T) {
	const directSubscription = "vless://00000000-0000-0000-0000-000000000041@direct.example.com:443?security=tls#direct"
	const cachedSubscription = "https://example.test/subscription/cached"
	tests := []struct {
		name         string
		subscription string
		cachedFor    string
		cachedCount  int
		want         int
	}{
		{name: "direct key", subscription: directSubscription, want: 1},
		{name: "matching cached subscription", subscription: cachedSubscription, cachedFor: cachedSubscription, cachedCount: 4, want: 4},
		{name: "unrelated cache", subscription: cachedSubscription, cachedFor: "https://example.test/subscription/other", cachedCount: 9, want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			basePath := t.TempDir()
			mu.Lock()
			current = defaultState()
			current.BasePath = basePath
			current.Subscription = tt.subscription
			current.CachedConfigSubscription = tt.cachedFor
			current.CachedProxyCount = tt.cachedCount
			if err := saveLocked(); err != nil {
				mu.Unlock()
				t.Fatal(err)
			}
			current = defaultState()
			current.BasePath = basePath
			err := loadLocked()
			got := current.SubscriptionProxyCount
			mu.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("migrated proxy count = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestAndroidSubscriptionMutationRollsBackOnPersistenceFailure(t *testing.T) {
	const oldSubscription = "vless://00000000-0000-0000-0000-000000000010@old.example.com:443?security=tls#old"
	const newSubscription = "vless://00000000-0000-0000-0000-000000000011@new.example.com:443?security=tls#new"
	tests := []struct {
		name   string
		method string
		args   string
	}{
		{name: "set", method: "SetVPNSubscription", args: `["` + newSubscription + `"]`},
		{name: "remove", method: "RemoveVPNSubscription", args: `[]`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			basePath := t.TempDir()
			if err := os.Mkdir(filepath.Join(basePath, stateFileName), 0o755); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			current = defaultState()
			current.BasePath = basePath
			current.Subscription = oldSubscription
			current.SubscriptionProxyCount = 11
			current.LastError = "previous error"
			current.Logs = []string{"before mutation"}
			current.CachedSingBoxConfig = `{"cached":true}`
			current.CachedProxyCount = 7
			current.CachedConfigSubscription = oldSubscription
			current.CachedConfigSignature = "cached-signature"
			current.CachedConfigUpdatedAt = "2026-09-21T10:00:00Z"
			mu.Unlock()

			response := Call(tt.method, tt.args)
			if decodeSuccess(response) {
				t.Fatalf("%s reported success after persistence failure: %s", tt.method, response)
			}
			for _, secret := range []string{"old.example.com", "new.example.com", "00000000-0000-0000-0000-000000000010", "00000000-0000-0000-0000-000000000011"} {
				if strings.Contains(response, secret) {
					t.Fatalf("persistence response leaked %q: %s", secret, response)
				}
			}

			mu.Lock()
			defer mu.Unlock()
			if current.Subscription != oldSubscription ||
				current.SubscriptionProxyCount != 11 ||
				current.CachedSingBoxConfig != `{"cached":true}` ||
				current.CachedProxyCount != 7 ||
				current.CachedConfigSubscription != oldSubscription ||
				current.CachedConfigSignature != "cached-signature" ||
				current.CachedConfigUpdatedAt != "2026-09-21T10:00:00Z" {
				t.Fatalf("%s did not roll back subscription cache: %#v", tt.method, current)
			}
			logs := strings.Join(current.Logs, "\n")
			if strings.Contains(logs, "android subscription saved") || strings.Contains(logs, "android subscription removed") {
				t.Fatalf("%s retained a false success log: %s", tt.method, logs)
			}
			if !strings.Contains(current.LastError, "state save failed") || !strings.Contains(logs, "state save failed") {
				t.Fatalf("%s did not retain the truthful persistence error: error=%q logs=%q", tt.method, current.LastError, logs)
			}
		})
	}
}

func TestSubscriptionSummaryDoesNotLeakCredentials(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  string
	}{
		{
			name:  "subscription URL",
			value: "https://api.example.test/sub/secret-token?user=private",
			want:  "https://[redacted]",
		},
		{
			name:  "direct proxy URL",
			value: "vless://secret-user@example.test:443?security=tls#private-name",
			want:  "vless://[redacted]",
		},
		{
			name:  "encoded subscription",
			value: "c2VjcmV0LXN1YnNjcmlwdGlvbi1wYXlsb2Fk",
			want:  "[redacted]",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := subscriptionSummary(tt.value); got != tt.want {
				t.Fatalf("subscriptionSummary() = %q, want %q", got, tt.want)
			}
			for _, secret := range []string{"api.example.test", "example.test", "secret-token", "secret-user", "private", "c2VjcmV0"} {
				if strings.Contains(subscriptionSummary(tt.value), secret) {
					t.Fatalf("subscriptionSummary() leaked %q", secret)
				}
			}
		})
	}
}

func TestProxyListSummaryDoesNotLeakServers(t *testing.T) {
	proxies := []proxyConfig{
		{Type: "vless", Network: "ws", Server: "secret.example.test", ServerPort: 443},
		{Type: "trojan", Server: "192.0.2.10", ServerPort: 8443},
	}
	got := proxyListSummary(proxies)
	if got != "vless/ws, trojan" {
		t.Fatalf("proxyListSummary() = %q", got)
	}
	for _, secret := range []string{"secret.example.test", "192.0.2.10", "443", "8443"} {
		if strings.Contains(got, secret) {
			t.Fatalf("proxyListSummary() leaked %q", secret)
		}
	}
}

func TestBuildSingBoxConfigForDirectVLESS(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	mu.Unlock()

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != true {
		t.Fatalf("success = %v, error = %v", response["success"], response["error"])
	}
	configText, ok := response["config"].(string)
	if !ok || configText == "" {
		t.Fatalf("config missing: %#v", response["config"])
	}

	var config map[string]interface{}
	if err := json.Unmarshal([]byte(configText), &config); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(configText, `"type": "tun"`) {
		t.Fatal("config does not contain tun inbound")
	}
	if !strings.Contains(configText, `"type": "vless"`) {
		t.Fatal("config does not contain vless outbound")
	}
	if !strings.Contains(configText, `"type": "ws"`) {
		t.Fatal("config does not contain websocket transport")
	}
	assertAndroidSubscriptionCount(t, 1)
}

func TestAndroidBlockedOnlyRoutesOnlyBlockedServicesThroughVPN(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	mu.Unlock()

	config := buildConfigForTest(t)
	route := config["route"].(map[string]interface{})
	if final := route["final"]; final != "direct" {
		t.Fatalf("route final = %v, want direct", final)
	}
	if !androidContainsDomainRoute(config, "instagram.com", "proxy") {
		t.Fatal("instagram.com must route through proxy by default")
	}
	if !androidContainsPackageRoute(config, "com.discord", "proxy") {
		t.Fatal("Discord package traffic, including IP-only voice UDP, must route through proxy by default")
	}
	if !androidContainsPackageRoute(config, "org.telegram.messenger", "proxy") {
		t.Fatal("Telegram package traffic, including IP-only endpoints, must route through proxy by default")
	}
	if !androidContainsDNSServer(config, "instagram.com", "dns-remote") {
		t.Fatal("instagram.com must resolve through remote DNS by default")
	}
	if !androidContainsDNSServer(config, "yandex.ru", "dns-direct") {
		t.Fatal("yandex.ru must resolve through direct DNS in blocked-only mode")
	}
	dns := config["dns"].(map[string]interface{})
	if dns["final"] != "dns-direct" {
		t.Fatalf("dns final = %v, want dns-direct", dns["final"])
	}
	defaultResolver := route["default_domain_resolver"].(map[string]interface{})
	if defaultResolver["server"] != "dns-direct" {
		t.Fatalf("default_domain_resolver = %v, want dns-direct", defaultResolver["server"])
	}
	dnsDirect := androidDNSServerByTag(config, "dns-direct")
	if _, ok := dnsDirect["detour"]; ok {
		t.Fatalf("dns-direct must not set detour: %#v", dnsDirect)
	}
	dnsRemote := androidDNSServerByTag(config, "dns-remote")
	if dnsRemote["detour"] != "proxy" {
		t.Fatalf("dns-remote detour = %v, want proxy", dnsRemote["detour"])
	}
	if androidContainsAnyDomainSuffix(config, "2ip.io") {
		t.Fatal("2ip.io must not be part of Android blocked-service rules")
	}
	if androidContainsDomainRoute(config, "steam.com", "proxy") || androidContainsDomainRoute(config, "steamcommunity.com", "proxy") {
		t.Fatal("Steam must keep the blocked-only final direct route on Android")
	}
	for _, raw := range route["rules"].([]interface{}) {
		rule := raw.(map[string]interface{})
		if _, hasCIDRs := rule["ip_cidr"]; hasCIDRs {
			t.Fatalf("Android service CIDR must not be an unscoped route rule: %#v", rule)
		}
	}
	if !androidContainsDomainRegexRoute(config, androidKnownDomainRegex, "direct") {
		t.Fatal("Android blocked-only routes require a terminal known-domain direct boundary")
	}
	for _, domain := range []string{"riotgames.com", "riotcdn.net", "pvp.net", "leagueoflegends.com"} {
		if !androidContainsDomainRoute(config, domain, "direct") || androidContainsDomainRoute(config, domain, "proxy") {
			t.Fatalf("Riot domain %s must stay direct in Android blocked-only mode", domain)
		}
		if !androidContainsDNSServer(config, domain, "dns-direct") {
			t.Fatalf("Riot domain %s must resolve directly in Android blocked-only mode", domain)
		}
	}
}

func TestAndroidRoutePolicyCanForceBlockedServiceDirect(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.RoutePolicies = map[string]string{"meta": "direct"}
	mu.Unlock()

	config := buildConfigForTest(t)
	if !androidContainsDomainRoute(config, "instagram.com", "direct") {
		t.Fatal("instagram.com must route direct when meta policy is direct")
	}
	if androidContainsDomainRoute(config, "instagram.com", "proxy") {
		t.Fatal("instagram.com must not route through proxy when meta policy is direct")
	}
	if !androidContainsDNSServer(config, "instagram.com", "dns-direct") {
		t.Fatal("instagram.com must use direct DNS when meta policy is direct")
	}
}

func TestAndroidLegacyExceptRussiaMigratesToBlockedOnly(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.Config.RoutingMode = "except_russia"
	mu.Unlock()

	config := buildConfigForTest(t)
	route := config["route"].(map[string]interface{})
	if route["final"] != "direct" {
		t.Fatalf("legacy except_russia final = %v, want direct after migration", route["final"])
	}
	if !androidContainsDomainRoute(config, "steam.com", "direct") {
		t.Fatal("migrated blocked_only must keep Steam domains direct on Android")
	}
	if !androidContainsPackageRoute(config, "com.valvesoftware.android.steam.community", "direct") {
		t.Fatal("migrated blocked_only must keep the Steam package direct on Android")
	}
	if !androidContainsDNSServer(config, "steam.com", "dns-direct") {
		t.Fatal("migrated blocked_only must resolve Steam domains directly on Android")
	}
	for _, domain := range []string{"riotgames.com", "riotcdn.net", "pvp.net", "leagueoflegends.com"} {
		if !androidContainsDomainRoute(config, domain, "direct") {
			t.Fatalf("migrated blocked_only must keep Riot domain %s direct on Android", domain)
		}
		if !androidContainsDNSServer(config, domain, "dns-direct") {
			t.Fatalf("migrated blocked_only must resolve Riot domain %s directly on Android", domain)
		}
	}
	for _, packageName := range []string{"com.riotgames.league.wildrift", "com.riotgames.league.teamfighttactics"} {
		if !androidContainsPackageRoute(config, packageName, "direct") {
			t.Fatalf("migrated blocked_only must keep Riot package %s direct on Android", packageName)
		}
	}
}

func TestAndroidDiscordRoutePolicyAlsoControlsIPOnlyVoiceTraffic(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.RoutePolicies = map[string]string{"discord": "direct"}
	mu.Unlock()

	config := buildConfigForTest(t)
	if !androidContainsPackageRoute(config, "com.discord", "direct") {
		t.Fatal("Discord package traffic must route direct when Discord policy is direct")
	}
	if androidContainsPackageRoute(config, "com.discord", "proxy") {
		t.Fatal("Discord package traffic must not route through proxy when Discord policy is direct")
	}
}

func TestAndroidHideRuTrafficRoutesRuDomainsThroughVPN(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.Config.HideRuTraffic = true
	mu.Unlock()

	config := buildConfigForTest(t)
	if !androidContainsDomainRoute(config, "yandex.ru", "proxy") {
		t.Fatal("yandex.ru must route through proxy when HideRuTraffic is enabled")
	}
	if !androidContainsDNSServer(config, "yandex.ru", "dns-remote") {
		t.Fatal("yandex.ru must resolve through remote DNS when HideRuTraffic is enabled")
	}
}

func TestAndroidHideRuTrafficCanUseDedicatedProxy(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#main"
	current.Config.HideRuTraffic = true
	current.Config.RuProxyAddress = "vless://11111111-1111-1111-1111-111111111111@ru.example.com:443?security=tls&type=ws&path=%2Fws&host=ru.example.com&sni=ru.example.com&fp=chrome#ru"
	mu.Unlock()

	config := buildConfigForTest(t)
	if !androidContainsDomainRoute(config, "yandex.ru", "ru-proxy-1") {
		t.Fatal("yandex.ru must route through dedicated RU proxy when configured")
	}
	if !androidContainsOutbound(config, "ru-proxy-1") {
		t.Fatal("dedicated RU proxy outbound is missing")
	}
}

func TestAndroidSaveConfigAffectsLogLevelAndInvalidatesCache(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.CachedSingBoxConfig = `{"old":true}`
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil)
	mu.Unlock()

	if ok := decodeSuccess(Call("SaveAppConfig", `[false,false,true,true,true,"dark","ru","debug",24]`)); !ok {
		t.Fatal("SaveAppConfig success = false")
	}
	mu.Lock()
	if current.CachedSingBoxConfig != "" {
		t.Fatal("cached config must be cleared when effective log level changes")
	}
	mu.Unlock()

	config := buildConfigForTest(t)
	logConfig := config["log"].(map[string]interface{})
	if logConfig["level"] != "error" {
		t.Fatalf("log level = %v, want error when logging is disabled", logConfig["level"])
	}
}

func TestAndroidSaveConfigRejectsInvalidValuesAndLiveLoggingChange(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	original := current.Config
	mu.Unlock()

	invalid := []string{
		`[false,true,true,true,true,"neon","ru","info",24]`,
		`[false,true,true,true,true,"system","en","info",24]`,
		`[false,true,true,true,true,"system","ru","verbose",24]`,
		`[false,true,true,true,true,"system","ru","info",0]`,
	}
	for _, args := range invalid {
		if ok := decodeSuccess(Call("SaveAppConfig", args)); ok {
			t.Fatalf("SaveAppConfig accepted invalid args %s", args)
		}
	}

	mu.Lock()
	if current.Config != original {
		t.Fatalf("invalid settings mutated config: got %#v, want %#v", current.Config, original)
	}
	current.Connected = true
	mu.Unlock()
	if ok := decodeSuccess(Call("SaveAppConfig", `[false,false,true,true,true,"system","ru","info",24]`)); ok {
		t.Fatal("SaveAppConfig changed logging while VPN was connected")
	}
}

func TestAndroidAutoUpdateDisabledReusesMatchingCache(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "https://offline.invalid/sub"
	current.Config.AutoUpdateSub = false
	current.CachedSingBoxConfig = `{"cached":true}`
	current.CachedProxyCount = 2
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil)
	mu.Unlock()

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != true || response["cached"] != true {
		t.Fatalf("response = %#v, want cached success", response)
	}
	if response["config"] != `{"cached":true}` {
		t.Fatalf("config = %v, want cached config", response["config"])
	}
}

func TestAndroidDirectFirstSchemaInvalidatesPriorCachedConfig(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.Config.AutoUpdateSub = false
	current.CachedSingBoxConfig = `{"staleIpOnlyRouting":true}`
	current.CachedProxyCount = 1
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = strings.Replace(
		androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil),
		androidConfigSchema,
		"android-package-routing-v6",
		1,
	)
	mu.Unlock()

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != true || response["cached"] == true {
		t.Fatalf("response = %#v, want a rebuilt direct-first config", response)
	}
	if strings.Contains(response["config"].(string), "staleIpOnlyRouting") {
		t.Fatal("prior Android routing schema was reused")
	}
}

func TestAndroidRuntimeSettingsValidateAndInvalidateCache(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	current.CachedSingBoxConfig = `{"old":true}`
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil)
	mu.Unlock()

	if ok := decodeSuccess(Call("SetRoutingMode", `["invalid"]`)); ok {
		t.Fatal("SetRoutingMode accepted an invalid mode")
	}
	if ok := decodeSuccess(Call("SetRoutingMode", `["all_traffic"]`)); !ok {
		t.Fatal("SetRoutingMode(all_traffic) success = false")
	}
	if ok := decodeSuccess(Call("SetAndroidRoutePolicy", `["meta","direct"]`)); !ok {
		t.Fatal("SetAndroidRoutePolicy(meta, direct) success = false")
	}
	mu.Lock()
	if current.CachedSingBoxConfig != "" {
		t.Fatal("cached config must be cleared after routing mode change")
	}
	mu.Unlock()
	config := buildConfigForTest(t)
	route := config["route"].(map[string]interface{})
	if route["final"] != "proxy" {
		t.Fatalf("all_traffic final = %v, want proxy", route["final"])
	}
	dns := config["dns"].(map[string]interface{})
	if dns["final"] != "dns-remote" {
		t.Fatalf("all_traffic dns final = %v, want dns-remote", dns["final"])
	}
	if androidContainsDomainRoute(config, "steam.com", "direct") ||
		androidContainsPackageRoute(config, "com.valvesoftware.android.steam.community", "direct") ||
		androidContainsDNSServer(config, "steam.com", "dns-direct") {
		t.Fatal("all_traffic must not carve Steam out of the explicit full-VPN policy")
	}
	if androidContainsDomainRoute(config, "instagram.com", "direct") ||
		androidContainsDNSServer(config, "instagram.com", "dns-direct") {
		t.Fatal("all_traffic must override a saved per-service Direct policy")
	}
	if !androidContainsDomainRoute(config, "instagram.com", "proxy") ||
		!androidContainsDNSServer(config, "instagram.com", "dns-remote") {
		t.Fatal("all_traffic must route the saved Direct service and its DNS through VPN")
	}
}

func TestAndroidRuntimeRouteChangesAreRejectedWhileConnected(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Connected = true
	mu.Unlock()

	for method, args := range map[string]string{
		"SetRoutingMode":             `["all_traffic"]`,
		"SetHideRuTraffic":           `[true,""]`,
		"SetAndroidRoutePolicy":      `["meta","direct"]`,
		"SetFreeAccessServiceMethod": `["meta","direct"]`,
	} {
		if ok := decodeSuccess(Call(method, args)); ok {
			t.Fatalf("%s unexpectedly succeeded while connected", method)
		}
	}
}

func TestAndroidVersionCompareAndAssetSelection(t *testing.T) {
	if compareAndroidVersions("2.1.4", "2.1.3") <= 0 {
		t.Fatal("2.1.4 must be newer than 2.1.3")
	}
	if compareAndroidVersions("v2.1.3", "2.1.3") != 0 {
		t.Fatal("v2.1.3 must equal 2.1.3")
	}
	release := androidGitHubRelease{}
	release.Assets = append(release.Assets, struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Size               int64  `json:"size"`
	}{Name: "dropo-Windows.zip", BrowserDownloadURL: "windows", Size: 10})
	release.Assets = append(release.Assets, struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
		Size               int64  `json:"size"`
	}{Name: "dropo-Android-arm64.apk", BrowserDownloadURL: "android", Size: 20})
	name, url, size := androidUpdateAsset(release)
	if name != "dropo-Android-arm64.apk" || url != "android" || size != 20 {
		t.Fatalf("asset = %q %q %d, want Android APK", name, url, size)
	}
}

func TestAndroidGeneratedConfigAcceptedBySingBox(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("local sing-box check uses the bundled Windows binary")
	}
	exe := filepath.Clean(`..\..\..\dependencies\sing-box-v1.13.14\windows-amd64\sing-box-1.13.14-windows-amd64\sing-box.exe`)
	if _, err := os.Stat(exe); err != nil {
		t.Skipf("sing-box binary is not available: %v", err)
	}

	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&type=ws&path=%2Fws&host=example.com&sni=example.com&fp=chrome#demo"
	mu.Unlock()

	config := buildConfigForTest(t)
	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "android-sing-box.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(exe, "check", "-c", path).CombinedOutput()
	if err != nil {
		t.Fatalf("sing-box check failed: %v\n%s", err, output)
	}
}

func TestBuildSingBoxConfigRejectsEmptySubscription(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != false {
		t.Fatalf("success = %v, want false", response["success"])
	}
}

func TestAndroidEngineErrorIsPersistedInStatusAndLogs(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	raw := Call("AndroidEngineError", `["check config failed: bad vless"]`)
	if ok := decodeSuccess(raw); ok {
		t.Fatal("AndroidEngineError success = true, want false")
	}

	var status map[string]interface{}
	if err := json.Unmarshal([]byte(Status()), &status); err != nil {
		t.Fatal(err)
	}
	if status["hasError"] != true {
		t.Fatalf("hasError = %v, want true", status["hasError"])
	}
	if !strings.Contains(status["error"].(string), "bad vless") {
		t.Fatalf("error = %q, want bad vless", status["error"])
	}

	var logs map[string]interface{}
	if err := json.Unmarshal([]byte(Logs()), &logs); err != nil {
		t.Fatal(err)
	}
	text := ""
	for _, item := range logs["logs"].([]interface{}) {
		text += item.(string) + "\n"
	}
	if !strings.Contains(text, "android engine error: check config failed: bad vless") {
		t.Fatalf("logs do not contain engine error:\n%s", text)
	}
}

func TestAndroidServiceStatesAreExposedInStatus(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	if ok := decodeSuccess(Call("AndroidServiceState", `["starting","booting",""]`)); !ok {
		t.Fatal("AndroidServiceState(starting) success = false")
	}

	var status map[string]interface{}
	if err := json.Unmarshal([]byte(Status()), &status); err != nil {
		t.Fatal(err)
	}
	if status["vpnState"] != "starting" {
		t.Fatalf("vpnState = %v, want starting", status["vpnState"])
	}
	if status["connecting"] != true {
		t.Fatalf("connecting = %v, want true", status["connecting"])
	}
	if status["connected"] == true {
		t.Fatal("connected = true while starting")
	}

	if ok := decodeSuccess(Call("AndroidServiceState", `["connected","ready",""]`)); !ok {
		t.Fatal("AndroidServiceState(connected) success = false")
	}
	if err := json.Unmarshal([]byte(Status()), &status); err != nil {
		t.Fatal(err)
	}
	if status["connected"] != true || status["vpnState"] != "connected" {
		t.Fatalf("connected status mismatch: %#v", status)
	}
}

func TestBuildSingBoxConfigFallsBackToMatchingCache(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "ftp://offline.example/sub"
	current.CachedConfigSubscription = current.Subscription
	current.CachedConfigSignature = androidConfigSignature(current.Subscription, current.Config.EnableLogging, current.Config.LogLevel, current.Config.RoutingMode, current.Config.HideRuTraffic, current.Config.RuProxyAddress, nil)
	current.CachedSingBoxConfig = `{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}`
	current.CachedProxyCount = 1
	mu.Unlock()

	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != true {
		t.Fatalf("success = %v, error = %v", response["success"], response["error"])
	}
	if response["cached"] != true {
		t.Fatalf("cached = %v, want true", response["cached"])
	}
	if response["config"] == "" {
		t.Fatal("cached config missing")
	}
}

func TestAndroidDiagnosticsIncludesCacheAndState(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://example"
	current.CachedSingBoxConfig = "{}"
	current.CachedProxyCount = 2
	current.CachedConfigSubscription = current.Subscription
	current.ServiceState = "connected"
	mu.Unlock()

	var diagnostics map[string]interface{}
	if err := json.Unmarshal([]byte(Call("AndroidDiagnostics", "[]")), &diagnostics); err != nil {
		t.Fatal(err)
	}
	text := diagnostics["text"].(string)
	if !strings.Contains(text, "serviceState: connected") {
		t.Fatalf("diagnostics missing service state:\n%s", text)
	}
	if !strings.Contains(text, "cachedConfig: true") {
		t.Fatalf("diagnostics missing cache summary:\n%s", text)
	}
}

func TestAndroidRoutesExposeAutoDirectAndVPNMethods(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	var config map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetFreeAccessConfig", "[]")), &config); err != nil {
		t.Fatal(err)
	}
	options, ok := config["methodOptions"].([]interface{})
	if !ok || len(options) != 3 {
		t.Fatalf("methodOptions = %#v, want auto/direct/vpn options", config["methodOptions"])
	}
	wantOptions := []string{androidRoutePolicyAuto, androidRoutePolicyDirect, androidRoutePolicyVPN}
	for index, want := range wantOptions {
		option := options[index].(map[string]interface{})
		if option["tag"] != want || option["label"] != androidRoutePolicyLabel(want) {
			t.Fatalf("method option %d = %#v, want %q/%q", index, option, want, androidRoutePolicyLabel(want))
		}
	}

	services, ok := config["services"].([]interface{})
	if !ok || len(services) == 0 {
		t.Fatalf("services = %#v", config["services"])
	}
	if got, want := len(services), len(androidServiceCatalog()); got != want {
		t.Fatalf("services count = %d, want %d", got, want)
	}
	for _, raw := range services {
		service := raw.(map[string]interface{})
		if service["selectedMethod"] != androidRoutePolicyAuto {
			t.Fatalf("default selected method for %v = %v, want auto", service["tag"], service["selectedMethod"])
		}
		if service["effectiveMethodLabel"] != androidRoutePolicyLabel(androidRoutePolicyDirect) {
			t.Fatalf("default method label without subscription for %v = %v, want direct", service["tag"], service["effectiveMethodLabel"])
		}
		if service["zapretSupported"] != false {
			t.Fatalf("Android service %v unexpectedly advertises Zapret support", service["tag"])
		}
		if tag := service["tag"].(string); androidPrimaryHomeRouteTags[tag] && service["homeVisible"] != true {
			t.Fatalf("primary Android service %v is not visible on home", tag)
		}
	}
	if ok := decodeSuccess(Call("SetHomeRouteServiceVisible", `["spotify",true]`)); !ok {
		t.Fatal("SetHomeRouteServiceVisible success = false")
	}
	if err := json.Unmarshal([]byte(Call("GetFreeAccessConfig", "[]")), &config); err != nil {
		t.Fatal(err)
	}
	foundPinned := false
	for _, raw := range config["services"].([]interface{}) {
		service := raw.(map[string]interface{})
		if service["tag"] == "spotify" && service["homeVisible"] == true {
			foundPinned = true
		}
	}
	if !foundPinned {
		t.Fatal("pinned Spotify service is not visible on Android home")
	}

	if ok := decodeSuccess(Call("SetAndroidRoutePolicy", `["meta","direct"]`)); !ok {
		t.Fatal("SetAndroidRoutePolicy success = false")
	}
	if err := json.Unmarshal([]byte(Call("GetFreeAccessConfig", "[]")), &config); err != nil {
		t.Fatal(err)
	}
	cache := config["methodCache"].(map[string]interface{})
	if cache["meta"] != androidRoutePolicyDirect {
		t.Fatalf("meta method cache = %v, want direct", cache["meta"])
	}
	if cache["youtube"] != androidRoutePolicyAuto {
		t.Fatalf("youtube method cache = %v, want auto", cache["youtube"])
	}

	var rejected map[string]interface{}
	if err := json.Unmarshal([]byte(Call("SetFreeAccessServiceMethod", `["discord","zapret"]`)), &rejected); err != nil {
		t.Fatal(err)
	}
	if rejected["success"] != false {
		t.Fatalf("Android strict Zapret policy unexpectedly succeeded: %#v", rejected)
	}
}

func TestAndroidAllTrafficRouteSummaryOverridesSavedDirectWithoutSyntheticLatency(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	current.Subscription = "vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls#demo"
	current.Config.RoutingMode = "all_traffic"
	current.RoutePolicies = map[string]string{"meta": androidRoutePolicyDirect}
	current.Connected = true
	mu.Unlock()

	var summary map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetBypassRouteSummary", "[]")), &summary); err != nil {
		t.Fatal(err)
	}
	for _, raw := range summary["services"].([]interface{}) {
		service := raw.(map[string]interface{})
		if service["tag"] != "meta" {
			continue
		}
		if service["selectedMethod"] != androidRoutePolicyDirect {
			t.Fatalf("saved meta policy = %v, want direct", service["selectedMethod"])
		}
		if service["effectiveMethodLabel"] != androidRoutePolicyLabel(androidRoutePolicyVPN) || service["requiresVpn"] != true {
			t.Fatalf("all-traffic meta route is not effective VPN: %#v", service)
		}
		if service["delayMs"] != float64(0) {
			t.Fatalf("unmeasured Android route latency = %v, want 0", service["delayMs"])
		}
		return
	}
	t.Fatal("meta route missing from Android summary")
}

func TestAndroidQuickCheckUsesEffectiveRouteWithoutClaimingTransportProof(t *testing.T) {
	result := androidClientQuickCheckResult(routeInfo{
		Tag:                  "meta",
		Name:                 "Instagram",
		SelectedMethod:       androidRoutePolicyDirect,
		EffectiveMethodLabel: androidRoutePolicyLabel(androidRoutePolicyVPN),
		RequiresVPN:          true,
	}, "https://www.instagram.com/", 200, "", 42)

	if result["expectedRoute"] != androidRoutePolicyVPN {
		t.Fatalf("expected route = %v, want effective VPN", result["expectedRoute"])
	}
	if result["routeVerified"] != false || result["checkScope"] != "endpoint_reachability" {
		t.Fatalf("Android quick check overstates transport proof: %#v", result)
	}
	if result["statusText"] != "ENDPOINT_OK" || result["success"] != true {
		t.Fatalf("successful endpoint result = %#v", result)
	}
}

func TestAndroidQuickCheckSessionValidityRejectsReconnect(t *testing.T) {
	mu.Lock()
	defer mu.Unlock()
	current = defaultState()
	current.Connected = true
	current.StartedAt = "2026-09-21T10:00:00+03:00"
	current.TotalSessions = 4

	if !androidQuickCheckSessionValidLocked(current.StartedAt, current.TotalSessions, true) {
		t.Fatal("unchanged Android VPN session was rejected")
	}
	current.TotalSessions++
	if androidQuickCheckSessionValidLocked("2026-09-21T10:00:00+03:00", 4, true) {
		t.Fatal("quick check from the previous Android VPN session was accepted")
	}
}

func TestAndroidWireGuardCRUD(t *testing.T) {
	mu.Lock()
	current = defaultState()
	current.BasePath = t.TempDir()
	mu.Unlock()

	config := `[Interface]
PrivateKey = private-key
Address = 10.7.0.2/32
DNS = 10.7.0.1
MTU = 1280

[Peer]
PublicKey = public-key
AllowedIPs = 10.7.0.0/24, 10.8.0.0/24
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25`

	args, err := json.Marshal([]interface{}{"office", "Office", config})
	if err != nil {
		t.Fatal(err)
	}
	if ok := decodeSuccess(Call("AddWireGuard", string(args))); !ok {
		t.Fatal("AddWireGuard success = false")
	}

	var list map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetWireGuardList", "[]")), &list); err != nil {
		t.Fatal(err)
	}
	if list["count"].(float64) != 1 {
		t.Fatalf("count = %v, want 1", list["count"])
	}

	var item map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetWireGuardConfig", `["office"]`)), &item); err != nil {
		t.Fatal(err)
	}
	if item["endpoint"] != "vpn.example.com:51820" {
		t.Fatalf("endpoint = %v", item["endpoint"])
	}

	if ok := decodeSuccess(Call("DeleteWireGuard", `["office"]`)); !ok {
		t.Fatal("DeleteWireGuard success = false")
	}
	if err := json.Unmarshal([]byte(Call("GetWireGuardList", "[]")), &list); err != nil {
		t.Fatal(err)
	}
	if list["count"].(float64) != 0 {
		t.Fatalf("count after delete = %v, want 0", list["count"])
	}
}

func decodeSuccess(raw string) bool {
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return false
	}
	return data["success"] != false
}

func installAndroidSubscriptionTestTransport(t *testing.T, client *http.Client) {
	t.Helper()
	previousFactory := androidSubscriptionTestFetcherFactory
	androidSubscriptionTestFetcherFactory = func() *subscriptionFetcher {
		fetcher := newSubscriptionFetcher()
		fetcher.client.Transport = client.Transport
		fetcher.client.Timeout = 5 * time.Second
		return fetcher
	}
	t.Cleanup(func() { androidSubscriptionTestFetcherFactory = previousFactory })
}

func assertAndroidSubscriptionCount(t *testing.T, want int) {
	t.Helper()
	var subscription map[string]interface{}
	if err := json.Unmarshal([]byte(Call("GetCurrentSubscription", "[]")), &subscription); err != nil {
		t.Fatal(err)
	}
	if subscription["proxyCount"] != float64(want) {
		t.Fatalf("subscription proxy count = %v, want %d", subscription["proxyCount"], want)
	}
}

func buildConfigForTest(t *testing.T) map[string]interface{} {
	t.Helper()
	var response map[string]interface{}
	if err := json.Unmarshal([]byte(BuildSingBoxConfig()), &response); err != nil {
		t.Fatal(err)
	}
	if response["success"] != true {
		t.Fatalf("success = %v, error = %v", response["success"], response["error"])
	}
	var config map[string]interface{}
	if err := json.Unmarshal([]byte(response["config"].(string)), &config); err != nil {
		t.Fatal(err)
	}
	return config
}

func androidContainsDomainRoute(config map[string]interface{}, suffix, outbound string) bool {
	route, _ := config["route"].(map[string]interface{})
	rules, _ := route["rules"].([]interface{})
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		if rule["outbound"] != outbound {
			continue
		}
		if stringListContains(rule["domain_suffix"], suffix) {
			return true
		}
	}
	return false
}

func androidContainsPackageRoute(config map[string]interface{}, packageName, outbound string) bool {
	route := config["route"].(map[string]interface{})
	for _, raw := range route["rules"].([]interface{}) {
		rule := raw.(map[string]interface{})
		if rule["outbound"] != outbound {
			continue
		}
		if stringListContains(rule["package_name"], packageName) {
			return true
		}
	}
	return false
}

func androidContainsDomainRegexRoute(config map[string]interface{}, expression, outbound string) bool {
	route := config["route"].(map[string]interface{})
	for _, raw := range route["rules"].([]interface{}) {
		rule := raw.(map[string]interface{})
		if rule["outbound"] == outbound && stringListContains(rule["domain_regex"], expression) {
			return true
		}
	}
	return false
}

func androidContainsDNSServer(config map[string]interface{}, suffix, server string) bool {
	dns, _ := config["dns"].(map[string]interface{})
	rules, _ := dns["rules"].([]interface{})
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		if rule["server"] != server {
			continue
		}
		if stringListContains(rule["domain_suffix"], suffix) {
			return true
		}
	}
	return false
}

func androidDNSServerByTag(config map[string]interface{}, tag string) map[string]interface{} {
	dns, _ := config["dns"].(map[string]interface{})
	servers, _ := dns["servers"].([]interface{})
	for _, raw := range servers {
		server, _ := raw.(map[string]interface{})
		if server["tag"] == tag {
			return server
		}
	}
	return nil
}

func androidContainsAnyDomainSuffix(config map[string]interface{}, suffix string) bool {
	route, _ := config["route"].(map[string]interface{})
	if rules, _ := route["rules"].([]interface{}); stringListRulesContain(rules, suffix) {
		return true
	}
	dns, _ := config["dns"].(map[string]interface{})
	rules, _ := dns["rules"].([]interface{})
	return stringListRulesContain(rules, suffix)
}

func androidContainsOutbound(config map[string]interface{}, tag string) bool {
	outbounds, _ := config["outbounds"].([]interface{})
	for _, raw := range outbounds {
		outbound, _ := raw.(map[string]interface{})
		if outbound["tag"] == tag {
			return true
		}
	}
	return false
}

func stringListRulesContain(rules []interface{}, suffix string) bool {
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		if stringListContains(rule["domain_suffix"], suffix) {
			return true
		}
	}
	return false
}

func stringListContains(raw interface{}, value string) bool {
	switch typed := raw.(type) {
	case []interface{}:
		for _, item := range typed {
			if item == value {
				return true
			}
		}
	case []string:
		for _, item := range typed {
			if item == value {
				return true
			}
		}
	}
	return false
}
