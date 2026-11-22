package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	traffic "dropo/trafficorchestrator"
)

func TestQuickCheckTreatsRedirectLimitAsReachable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/loop", http.StatusFound)
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	result := invokeQuickCheckURL(ctx, newQuickCheckHTTPClient(nil), server.URL)
	if !result.Success {
		t.Fatalf("redirecting service should be considered reachable: status=%d err=%q", result.Status, result.Error)
	}
	if result.Status != http.StatusFound {
		t.Fatalf("expected final redirect response, got status %d", result.Status)
	}
}

func TestQuickCheckDoesNotMaskRegionalServiceTransportFailure(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	client := &http.Client{Transport: failingRoundTripper{}}
	result := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name:     "Gosuslugi",
		URL:      "https://www.gosuslugi.ru",
		Category: "Direct-RU",
		Regional: true,
	}, client, nil, nil)

	if result.Success || result.StatusText != "FAIL" {
		t.Fatalf("regional service failure = success:%v status:%s, want a real failure", result.Success, result.StatusText)
	}
	if result.NormalSuccess {
		t.Fatal("regional failure should keep NormalSuccess=false for diagnostics")
	}
}

type failingRoundTripper struct{}

func (failingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("region restricted")
}

func newRunningRouteStrategyTestApp(queueSize int) *App {
	app := NewApp()
	app.routeStrategyJobs = make(chan routeStrategyMaintenanceJob, queueSize)
	app.isRunning = true
	app.resetRouteStrategySession()
	return app
}

func TestQuickCheckFailuresQueueUniqueBlockedServiceMaintenance(t *testing.T) {
	app := newRunningRouteStrategyTestApp(4)
	session := app.currentRouteStrategySession()
	app.handleClientQuickCheckFailures(session, []clientQuickCheckResult{
		{Name: "Discord", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret, Success: false, NormalError: "timeout", RouteVerified: true},
		{Name: "Discord API", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret, Success: false, NormalError: "timeout", RouteVerified: true},
		{Name: "Yandex", Category: "Direct-RU", Success: false, NormalError: "timeout"},
	})

	select {
	case job := <-app.routeStrategyJobs:
		if job.Session != session || !strings.HasPrefix(job.Reason, "service:discord ") {
			t.Fatalf("queued job = %#v, want current-session discord maintenance", job)
		}
	default:
		t.Fatal("expected blocked service maintenance to be queued")
	}

	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("unexpected duplicate maintenance job: %#v", job)
	default:
	}
}

func TestEndpointOnlyQuickCheckFailureDoesNotQueueMaintenance(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	app.handleClientQuickCheckFailures(app.currentRouteStrategySession(), []clientQuickCheckResult{{
		Name:          "YouTube",
		ServiceTag:    "youtube",
		Category:      "Blocked",
		ExpectedRoute: clientQuickCheckRouteZapret,
		NormalError:   "timeout",
		RouteVerified: false,
		CheckScope:    "endpoint_reachability",
	}})

	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("endpoint-only failure must not retune the active route, got %#v", job)
	default:
	}
}

func TestQuickCheckExplicitVPNDoesNotQueueFreeMethodMaintenance(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	app.handleClientQuickCheckFailures(app.currentRouteStrategySession(), []clientQuickCheckResult{
		{Name: "YouTube", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteVPN, Success: true, ProxySuccess: true, StatusText: "VPN_OK"},
	})

	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("explicit VPN route must not queue free-method maintenance, got %#v", job)
	default:
	}
}

func TestQuickCheckAIVPNOnlyProxyFallbackDoesNotQueueFreeMethodMaintenance(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	app.handleClientQuickCheckFailures(app.currentRouteStrategySession(), []clientQuickCheckResult{
		{Name: "OpenAI API", Category: "AI-VPNOnly", ExpectedRoute: clientQuickCheckRouteVPN, Success: true, ProxySuccess: true, StatusText: "VPN_OK"},
	})

	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("AI/VPN-only proxy fallback must not queue free-method maintenance, got %#v", job)
	default:
	}
}

func TestRouteStrategyMaintenanceSkippedWhileStopping(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	app.stoppedManually = true
	app.requestRouteStrategyMaintenance("service:discord stop race")

	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("maintenance must not be queued while VPN is stopping, got %#v", job)
	default:
	}
}

func TestRouteStrategyMaintenanceCoalescesByService(t *testing.T) {
	app := NewApp()
	app.isRunning = true
	app.resetRouteStrategySession()
	defer close(app.routeStrategyJobs)

	uniqueTags := map[string]bool{}
	for _, svc := range clientQuickCheckServices {
		if svc.Category != "Blocked" {
			continue
		}
		tag := clientQuickCheckServiceTag(svc.Name)
		if tag != "" {
			uniqueTags[tag] = true
		}
		// Multiple endpoints map to the same service tag (Discord/Discord API/...)
		// and must collapse into a single search.
		app.requestRouteStrategyMaintenance("service:" + tag + " test failure")
	}

	queued := 0
	for {
		select {
		case <-app.routeStrategyJobs:
			queued++
		default:
			if queued != len(uniqueTags) {
				t.Fatalf("queued %d jobs, want one per unique blocked service (%d)", queued, len(uniqueTags))
			}
			return
		}
	}
}

func TestRouteStrategyMaintenanceAllowsLaterRetryAfterCooldown(t *testing.T) {
	app := NewApp()
	app.isRunning = true
	app.resetRouteStrategySession()
	defer close(app.routeStrategyJobs)

	app.requestRouteStrategyMaintenance("service:discord first failure")
	// Dequeue and mark as searched, mimicking the maintenance listener.
	<-app.routeStrategyJobs
	app.finishRouteStrategyService(app.currentRouteStrategySession(), "discord")

	app.requestRouteStrategyMaintenance("service:discord second failure")
	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("service must not be searched during cooldown, got %#v", job)
	default:
	}

	app.routeStrategyMu.Lock()
	app.routeStrategyLastAttempt["discord"] = time.Now().Add(-routeStrategyRetryCooldown - time.Second)
	app.routeStrategyMu.Unlock()
	app.requestRouteStrategyMaintenance("service:discord later failure")
	select {
	case <-app.routeStrategyJobs:
	default:
		t.Fatal("later failure must allow another search after cooldown")
	}

	// A new session also resets the cooldown immediately.
	app.resetRouteStrategySession()
	app.requestRouteStrategyMaintenance("service:discord new session")
	select {
	case <-app.routeStrategyJobs:
	default:
		t.Fatal("new session must allow the service to be searched again")
	}
}

func TestQuickCheckFromOldSessionCannotQueueMaintenance(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	oldSession := app.currentRouteStrategySession()
	app.invalidateRouteStrategySession()
	app.resetRouteStrategySession()

	app.handleClientQuickCheckFailures(oldSession, []clientQuickCheckResult{{
		Name:          "Discord",
		Category:      "Blocked",
		ExpectedRoute: clientQuickCheckRouteZapret,
		NormalError:   "timeout",
		RouteVerified: true,
	}})
	select {
	case job := <-app.routeStrategyJobs:
		t.Fatalf("old quick-check queued maintenance in a new session: %#v", job)
	default:
	}
}

func TestStaleRouteStrategyBookkeepingCannotTouchNewSession(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	oldSession := app.currentRouteStrategySession()
	if !app.markRouteStrategyQueued(oldSession, "discord") {
		t.Fatal("old session could not reserve service")
	}
	app.resetRouteStrategySession()
	newSession := app.currentRouteStrategySession()
	if !app.markRouteStrategyQueued(newSession, "discord") {
		t.Fatal("new session could not reserve service")
	}
	app.finishRouteStrategyService(oldSession, "discord")
	app.releaseRouteStrategyQueued(oldSession, "discord")
	if app.markRouteStrategyQueued(newSession, "discord") {
		t.Fatal("stale bookkeeping removed the new session reservation")
	}
}

func TestRouteStrategyCommitRejectsExpiredSession(t *testing.T) {
	app := newRunningRouteStrategyTestApp(1)
	oldSession := app.currentRouteStrategySession()
	app.invalidateRouteStrategySession()
	called := false
	err := app.commitRouteStrategySession(oldSession, func() error {
		called = true
		return nil
	})
	if !errors.Is(err, errRouteStrategySessionExpired) || called {
		t.Fatalf("stale commit err=%v called=%v", err, called)
	}
	if err := app.retunePerServiceStrategy("discord", "stale test", oldSession); !errors.Is(err, errRouteStrategySessionExpired) {
		t.Fatalf("stale retune error = %v, want session expired", err)
	}
}

func TestMaintenanceListenerDropsQueuedJobFromPreviousSession(t *testing.T) {
	app := newRunningRouteStrategyTestApp(2)
	app.requestRouteStrategyMaintenance("service:discord old failure")
	if len(app.routeStrategyJobs) != 1 {
		t.Fatal("old-session job was not queued for the test")
	}
	app.resetRouteStrategySession()
	app.startRouteStrategyMaintenanceListener()
	defer close(app.routeStrategyJobs)

	deadline := time.Now().Add(time.Second)
	for len(app.routeStrategyJobs) != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if len(app.routeStrategyJobs) != 0 {
		t.Fatal("listener did not drain the stale maintenance job")
	}
	app.routeStrategyMu.Lock()
	_, hasCooldown := app.routeStrategyLastAttempt["discord"]
	app.routeStrategyMu.Unlock()
	if hasCooldown {
		t.Fatal("stale maintenance job created a cooldown in the new session")
	}
}

func TestTransparentReselectionRunsOncePerSession(t *testing.T) {
	app := NewApp()

	if !app.beginTransparentReselectionOncePerSession() {
		t.Fatal("first reselection in a session must be allowed")
	}
	if app.beginTransparentReselectionOncePerSession() {
		t.Fatal("second reselection in the same session must be suppressed")
	}

	app.resetRouteStrategySession()
	if !app.beginTransparentReselectionOncePerSession() {
		t.Fatal("a new session must allow reselection again")
	}
}

func TestClientQuickCheckServiceTag(t *testing.T) {
	cases := map[string]string{
		"YouTube API":  "youtube",
		"WhatsApp CDN": "whatsapp",
		"Instagram":    "meta",
		"X":            "twitter",
		"ChatGPT":      "openai",
		"Cursor API":   "ai-other",
		"Docker Hub":   "docker",
		"Trello":       "atlassian",
		"Gosuslugi":    "",
	}
	for name, want := range cases {
		if got := clientQuickCheckServiceTag(name); got != want {
			t.Fatalf("clientQuickCheckServiceTag(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestClientQuickCheckCatalogUsesDenseRuntimeIndexes(t *testing.T) {
	services := denseClientQuickCheckServices(clientQuickCheckServices)
	results := make([]clientQuickCheckResult, len(services))
	for _, service := range services {
		if service.Index < 0 || service.Index >= len(results) {
			t.Fatalf("runtime index %d is outside result size %d for %s", service.Index, len(results), service.Name)
		}
		results[service.Index] = clientQuickCheckResult{Name: service.Name}
	}
	for i, result := range results {
		if result.Name == "" {
			t.Fatalf("runtime result %d was not populated", i)
		}
	}
}

func TestClientQuickCheckKeepsDirectGuardsAndSelectedServicesOnly(t *testing.T) {
	cases := []struct {
		service clientQuickCheckService
		want    bool
	}{
		{clientQuickCheckService{Category: "Direct-Game", ExpectedRoute: clientQuickCheckRouteDirect}, true},
		{clientQuickCheckService{Category: "Blocked", ExpectedRoute: clientQuickCheckRouteVPN}, true},
		{clientQuickCheckService{Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret}, true},
		{clientQuickCheckService{Category: "Blocked", ExpectedRoute: clientQuickCheckRouteDirect}, false},
	}
	for _, tc := range cases {
		if got := includeClientQuickCheckService(tc.service); got != tc.want {
			t.Fatalf("includeClientQuickCheckService(%#v) = %v, want %v", tc.service, got, tc.want)
		}
	}
}

func TestClientQuickCheckAllTrafficUsesVPNForEveryEndpoint(t *testing.T) {
	app := &App{}
	settings := GlobalAppSettings{RoutingMode: RoutingModeAllTraffic, HideRuTraffic: true}
	for _, service := range []clientQuickCheckService{
		{Name: "Yandex", Category: "Direct-RU"},
		{Name: "Steam Store", Category: "Direct-Game"},
		{Name: "Discord", Category: "Blocked", ServiceTag: "discord"},
	} {
		if got := app.clientQuickCheckExpectedRoute(settings, nil, service); got != clientQuickCheckRouteVPN {
			t.Fatalf("all-traffic route for %s = %q, want VPN", service.Name, got)
		}
	}
}

func TestClientQuickCheckHideRURoutesRussianEndpointsThroughCore(t *testing.T) {
	app := &App{}
	settings := GlobalAppSettings{RoutingMode: RoutingModeBlockedOnly, HideRuTraffic: true}
	if got := app.clientQuickCheckExpectedRoute(settings, nil, clientQuickCheckService{
		Name: "Yandex", Category: "Direct-RU",
	}); got != clientQuickCheckRouteRU {
		t.Fatalf("Hide-RU route = %q, want %q", got, clientQuickCheckRouteRU)
	}
	if got := app.clientQuickCheckExpectedRoute(settings, nil, clientQuickCheckService{
		Name: "Steam", Category: "Direct-Game",
	}); got != clientQuickCheckRouteDirect {
		t.Fatalf("non-RU direct route = %q, want direct", got)
	}
}

func TestClientQuickCheckTUNUsesTheLiveServiceSelector(t *testing.T) {
	services := []clientQuickCheckService{
		{Name: "YouTube", ServiceTag: "youtube", ExpectedRoute: clientQuickCheckRouteZapret},
		{Name: "Discord", ServiceTag: "discord", ExpectedRoute: clientQuickCheckRouteZapret},
		{Name: "Twitter", ServiceTag: "twitter", ExpectedRoute: clientQuickCheckRouteZapret},
	}
	routes, direct := clientQuickCheckEffectiveTUNRoutes(services, map[string]clashProxyInfo{
		ServiceBypassGroupTag("youtube"): {Now: "direct"},
		ServiceBypassGroupTag("discord"): {Now: "auto-select"},
	})
	if routes[0].ExpectedRoute != clientQuickCheckRouteZapret || !direct["youtube"] {
		t.Fatalf("direct selector route = %#v ready=%v, want the live Zapret carrier", routes[0], direct)
	}
	if !routes[0].EndpointOnly {
		t.Fatal("plain TUN probe must be labelled endpoint-only even with a direct selector snapshot")
	}
	if routes[1].ExpectedRoute != clientQuickCheckRouteVPN || direct["discord"] {
		t.Fatalf("VPN fallback route = %#v ready=%v, want VPN", routes[1], direct)
	}
	if routes[2].ExpectedRoute != clientQuickCheckRouteZapret || direct["twitter"] {
		t.Fatalf("unknown selector route = %#v ready=%v, want an unavailable Zapret check", routes[2], direct)
	}
	if !routes[2].EndpointOnly {
		t.Fatal("missing TUN selector snapshot must remain endpoint-only")
	}
}

func TestAllTrafficSummaryUsesTheEffectiveProxyChain(t *testing.T) {
	method, outbound, delay := summarizeAllTrafficProxy(map[string]clashProxyInfo{
		"proxy":        {Name: "proxy", Now: "auto-select"},
		"auto-select":  {Name: "auto-select", Now: "nl-amsterdam", History: []clashProxyHistoryEntry{{Delay: 72}}},
		"nl-amsterdam": {Name: "nl-amsterdam"},
	})
	if method != "VPN" || outbound != "nl-amsterdam" || delay != 72 {
		t.Fatalf("all-traffic summary = %q/%q/%d, want VPN/nl-amsterdam/72", method, outbound, delay)
	}
}

func TestAllTrafficSummaryDoesNotCallCachedDirectSelectionVPN(t *testing.T) {
	method, outbound, _ := summarizeAllTrafficProxy(map[string]clashProxyInfo{
		"proxy":  {Name: "proxy", Now: "direct"},
		"direct": {Name: "direct"},
	})
	if method != "Direct" || outbound != "direct" {
		t.Fatalf("cached direct selection reported as %q/%q, want Direct/direct", method, outbound)
	}
}

func TestNativeTrafficPlanIsTheAuthorityForDirectCarrierRoutes(t *testing.T) {
	app := &App{trafficEngine: &NativeTrafficManager{plan: traffic.TrafficPlan{
		Revision:   4,
		Strategies: []traffic.TrafficStrategy{{ID: "native-safe", Label: "Native safe split"}},
		Selections: []traffic.ServiceSelection{{ServiceID: "youtube", StrategyID: "native-safe"}},
		Routes:     []traffic.ServiceRoute{{ServiceID: "youtube", Kind: traffic.ServiceRouteZapret}},
	}}}
	method, outbound, ok := app.nativeTrafficRouteSummary("youtube")
	if !ok || method != "Native safe split" || outbound != "native-safe" {
		t.Fatalf("native route summary = %q/%q/%v, want active immutable plan selection", method, outbound, ok)
	}
	if _, _, ok := app.nativeTrafficRouteSummary("discord"); ok {
		t.Fatal("missing native service route was reported as active")
	}
}

func TestNewRouteStrategySessionClearsPreviousProbeObservations(t *testing.T) {
	app := &App{isRunning: true}
	app.rememberRouteProbeResults([]routeProbeServiceResult{{Tag: "discord", Success: true, MethodTag: "old-strategy"}})
	app.resetRouteStrategySession()
	if _, ok := app.lastRouteProbeResult("discord"); ok {
		t.Fatal("new VPN session retained a previous session's route probe")
	}
}

func TestClientQuickCheckUsesEndpointOnlyTUNPathWhenScopedProxyIsUnavailable(t *testing.T) {
	direct := &http.Client{Transport: &countingRoundTripper{}}
	if got := clientQuickCheckZapretHTTPClient("youtube", "", true, direct); got != direct {
		t.Fatal("TUN-sidecar endpoint check did not use the plain TUN client")
	}
	if got := clientQuickCheckZapretHTTPClient("youtube", "", false, direct); got != nil {
		t.Fatal("selective Zapret check must not silently fall back when its scoped proxy is unavailable")
	}
}

func TestServiceStrategyProbeFailsClosedWithoutScopedZapretProxy(t *testing.T) {
	app := &App{
		isRunning: true,
		storage: &Storage{data: &SettingsFile{App: GlobalAppSettings{
			HideRuTraffic: true,
		}}},
		trafficEngine: &NativeTrafficManager{activeTag: composedStrategyTag},
	}

	failures := app.probeServiceFailuresThroughEngine([]string{"youtube"})
	detail, failed := failures["youtube"]
	if !failed || !strings.Contains(detail, "канал проверки Zapret не активен") {
		t.Fatalf("TUN probe without scoped CONNECT = %#v, want a fail-closed result", failures)
	}
}

type countingRoundTripper struct {
	calls int
}

func (r *countingRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	r.calls++
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       http.NoBody,
		Request:    req,
	}, nil
}

func TestQuickCheckUsesOnlyTheExpectedRoute(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	directTransport := &countingRoundTripper{}
	proxyTransport := &countingRoundTripper{}
	directClient := &http.Client{Transport: directTransport}
	proxyClient := &http.Client{Transport: proxyTransport}

	directResult := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name: "Steam", ServiceTag: "steam", URL: "https://store.steampowered.com", Category: "Direct-Game", ExpectedRoute: clientQuickCheckRouteDirect,
	}, directClient, proxyClient, nil)
	if !directResult.Success || directResult.StatusText != "DIRECT_OK" || directTransport.calls != 1 || proxyTransport.calls != 0 {
		t.Fatalf("direct route result=%#v direct_calls=%d proxy_calls=%d", directResult, directTransport.calls, proxyTransport.calls)
	}
	if !directResult.RouteVerified || directResult.CheckScope != "route" {
		t.Fatalf("direct route scope=%q verified=%v, want verified route", directResult.CheckScope, directResult.RouteVerified)
	}
	if directResult.ServiceTag != "steam" {
		t.Fatalf("service tag = %q, want steam", directResult.ServiceTag)
	}
	encoded, err := json.Marshal(directResult)
	if err != nil {
		t.Fatalf("marshal quick-check result: %v", err)
	}
	if !strings.Contains(string(encoded), `"serviceTag":"steam"`) {
		t.Fatalf("serialized quick-check result does not expose serviceTag: %s", encoded)
	}

	directTransport.calls = 0
	proxyTransport.calls = 0
	vpnResult := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name: "Discord", URL: "https://discord.com", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteVPN,
	}, directClient, proxyClient, nil)
	if !vpnResult.Success || vpnResult.StatusText != "VPN_OK" || directTransport.calls != 0 || proxyTransport.calls != 1 {
		t.Fatalf("VPN route result=%#v direct_calls=%d proxy_calls=%d", vpnResult, directTransport.calls, proxyTransport.calls)
	}
	if !vpnResult.RouteVerified || vpnResult.CheckScope != "route" {
		t.Fatalf("VPN route scope=%q verified=%v, want verified route", vpnResult.CheckScope, vpnResult.RouteVerified)
	}

	directTransport.calls = 0
	proxyTransport.calls = 0
	zapretTransport := &countingRoundTripper{}
	zapretClient := &http.Client{Transport: zapretTransport}
	zapretResult := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name: "YouTube", ServiceTag: "youtube", URL: "https://www.youtube.com", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret,
	}, directClient, proxyClient, zapretClient)
	if !zapretResult.Success || zapretResult.StatusText != "ZAPRET_OK" || directTransport.calls != 0 || proxyTransport.calls != 0 || zapretTransport.calls != 1 {
		t.Fatalf("Zapret route result=%#v direct_calls=%d proxy_calls=%d zapret_calls=%d", zapretResult, directTransport.calls, proxyTransport.calls, zapretTransport.calls)
	}
	if !zapretResult.RouteVerified || zapretResult.CheckScope != "route" {
		t.Fatalf("Zapret route scope=%q verified=%v, want verified route", zapretResult.CheckScope, zapretResult.RouteVerified)
	}

	directTransport.calls = 0
	proxyTransport.calls = 0
	ruResult := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name: "Yandex", URL: "https://ya.ru", Category: "Direct-RU", ExpectedRoute: clientQuickCheckRouteRU,
	}, directClient, proxyClient, nil)
	if !ruResult.Success || ruResult.StatusText != "ENDPOINT_OK" || ruResult.RouteVerified || ruResult.CheckScope != "endpoint_reachability" || directTransport.calls != 0 || proxyTransport.calls != 1 {
		t.Fatalf("RU route result=%#v direct_calls=%d proxy_calls=%d", ruResult, directTransport.calls, proxyTransport.calls)
	}
}
