package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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

func TestQuickCheckTreatsRegionalServiceFailureAsExpected(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	client := &http.Client{Transport: failingRoundTripper{}}
	result := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name:     "Gosuslugi",
		URL:      "https://www.gosuslugi.ru",
		Category: "Direct-RU",
		Regional: true,
	}, client, nil)

	if !result.Success || result.StatusText != "REGION_LIMIT" {
		t.Fatalf("regional service failure = success:%v status:%s, want REGION_LIMIT success", result.Success, result.StatusText)
	}
	if result.NormalSuccess {
		t.Fatal("regional failure should keep NormalSuccess=false for diagnostics")
	}
}

type failingRoundTripper struct{}

func (failingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("region restricted")
}

func TestQuickCheckFailuresQueueUniqueBlockedServiceMaintenance(t *testing.T) {
	app := &App{routeStrategyJobs: make(chan string, 4), isRunning: true}
	app.handleClientQuickCheckFailures([]clientQuickCheckResult{
		{Name: "Discord", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret, Success: false, NormalError: "timeout"},
		{Name: "Discord API", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteZapret, Success: false, NormalError: "timeout"},
		{Name: "Yandex", Category: "Direct-RU", Success: false, NormalError: "timeout"},
	})

	select {
	case reason := <-app.routeStrategyJobs:
		if !strings.HasPrefix(reason, "service:discord ") {
			t.Fatalf("queued reason = %q, want discord service maintenance", reason)
		}
	default:
		t.Fatal("expected blocked service maintenance to be queued")
	}

	select {
	case reason := <-app.routeStrategyJobs:
		t.Fatalf("unexpected duplicate maintenance job: %q", reason)
	default:
	}
}

func TestQuickCheckExplicitVPNDoesNotQueueFreeMethodMaintenance(t *testing.T) {
	app := &App{routeStrategyJobs: make(chan string, 2), isRunning: true}
	app.handleClientQuickCheckFailures([]clientQuickCheckResult{
		{Name: "YouTube", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteVPN, Success: true, ProxySuccess: true, StatusText: "VPN_OK"},
	})

	select {
	case reason := <-app.routeStrategyJobs:
		t.Fatalf("explicit VPN route must not queue free-method maintenance, got %q", reason)
	default:
	}
}

func TestQuickCheckAIVPNOnlyProxyFallbackDoesNotQueueFreeMethodMaintenance(t *testing.T) {
	app := &App{routeStrategyJobs: make(chan string, 2), isRunning: true}
	app.handleClientQuickCheckFailures([]clientQuickCheckResult{
		{Name: "OpenAI API", Category: "AI-VPNOnly", ExpectedRoute: clientQuickCheckRouteVPN, Success: true, ProxySuccess: true, StatusText: "VPN_OK"},
	})

	select {
	case reason := <-app.routeStrategyJobs:
		t.Fatalf("AI/VPN-only proxy fallback must not queue free-method maintenance, got %q", reason)
	default:
	}
}

func TestRouteStrategyMaintenanceSkippedWhileStopping(t *testing.T) {
	app := &App{routeStrategyJobs: make(chan string, 2), isRunning: true, stoppedManually: true}
	app.requestRouteStrategyMaintenance("service:discord stop race")

	select {
	case reason := <-app.routeStrategyJobs:
		t.Fatalf("maintenance must not be queued while VPN is stopping, got %q", reason)
	default:
	}
}

func TestRouteStrategyMaintenanceCoalescesByService(t *testing.T) {
	app := NewApp()
	app.isRunning = true
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
	defer close(app.routeStrategyJobs)

	app.requestRouteStrategyMaintenance("service:discord first failure")
	// Dequeue and mark as searched, mimicking the maintenance listener.
	<-app.routeStrategyJobs
	app.finishRouteStrategyService("discord")

	app.requestRouteStrategyMaintenance("service:discord second failure")
	select {
	case reason := <-app.routeStrategyJobs:
		t.Fatalf("service must not be searched during cooldown, got %q", reason)
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
		Name: "Steam", URL: "https://store.steampowered.com", Category: "Direct-Game", ExpectedRoute: clientQuickCheckRouteDirect,
	}, directClient, proxyClient)
	if !directResult.Success || directResult.StatusText != "DIRECT_OK" || directTransport.calls != 1 || proxyTransport.calls != 0 {
		t.Fatalf("direct route result=%#v direct_calls=%d proxy_calls=%d", directResult, directTransport.calls, proxyTransport.calls)
	}

	directTransport.calls = 0
	proxyTransport.calls = 0
	vpnResult := runSingleClientQuickCheck(ctx, clientQuickCheckService{
		Name: "Discord", URL: "https://discord.com", Category: "Blocked", ExpectedRoute: clientQuickCheckRouteVPN,
	}, directClient, proxyClient)
	if !vpnResult.Success || vpnResult.StatusText != "VPN_OK" || directTransport.calls != 0 || proxyTransport.calls != 1 {
		t.Fatalf("VPN route result=%#v direct_calls=%d proxy_calls=%d", vpnResult, directTransport.calls, proxyTransport.calls)
	}
}

func TestRouteSummaryStaleProbeCannotOverwriteNewRoute(t *testing.T) {
	app := &App{routeLatencyCache: map[string]routeSummaryLatencyEntry{
		"youtube": {Route: clientQuickCheckRouteVPN, InFlight: true},
	}}
	app.storeRouteSummaryLatency("youtube", clientQuickCheckRouteDirect, 10)
	if got := app.routeLatencyCache["youtube"]; got.Route != clientQuickCheckRouteVPN || got.Delay != 0 || !got.InFlight {
		t.Fatalf("stale direct completion overwrote VPN cache: %#v", got)
	}
	app.storeRouteSummaryLatency("youtube", clientQuickCheckRouteVPN, 25)
	if got := app.routeLatencyCache["youtube"]; got.Route != clientQuickCheckRouteVPN || got.Delay != 25 || got.InFlight {
		t.Fatalf("current VPN completion was not stored: %#v", got)
	}
}
