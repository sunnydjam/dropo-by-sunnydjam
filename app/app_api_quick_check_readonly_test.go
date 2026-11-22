package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestReadOnlyQuickCheckNeverQueuesMaintenanceOrWritesCache(t *testing.T) {
	app := newRunningRouteStrategyTestApp(4)
	app.signalInitDone()
	app.basePath = t.TempDir()
	app.storage = &Storage{resourcesPath: filepath.Join(app.basePath, ResourcesFolder), data: &SettingsFile{App: GlobalAppSettings{
		FreeAccessMethods: map[string]string{"discord": FreeAccessMethodZapret},
	}}}
	cachePath := filepath.Join(app.basePath, ResourcesFolder, serviceStrategyCacheFileName)
	if err := os.MkdirAll(filepath.Dir(cachePath), 0700); err != nil {
		t.Fatal(err)
	}
	const cache = `{"version":1,"services":{}}`
	if err := os.WriteFile(cachePath, []byte(cache), 0600); err != nil {
		t.Fatal(err)
	}
	// No scoped proxy is active. A maintenance-enabled check would queue this
	// failed blocked-service observation; the help check must only report it.
	payload := app.runClientQuickCheck(false, true, []clientQuickCheckService{{
		Name: "Discord", Category: "Blocked", URL: "https://discord.com",
	}})
	if payload["readOnly"] != true || payload["sessionValid"] != true || payload["failedCount"] != 1 {
		t.Fatalf("unexpected observation summary: %#v", payload)
	}
	if len(app.routeStrategyJobs) != 0 {
		t.Fatal("help check queued strategy maintenance")
	}
	actual, err := os.ReadFile(cachePath)
	if err != nil || string(actual) != cache {
		t.Fatalf("help check changed the cache: err=%v", err)
	}
	if app.currentRouteStrategySession() != 1 {
		t.Fatal("help check changed the VPN session")
	}
}

func TestReadOnlyQuickCheckReportsLocalEndpointWithoutRepair(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	app := newRunningRouteStrategyTestApp(1)
	app.signalInitDone()
	payload := app.runClientQuickCheck(false, true, []clientQuickCheckService{{
		Name: "Local direct fixture", Category: "Direct-Game", URL: server.URL,
	}})
	if payload["success"] != true || payload["readOnly"] != true || payload["okCount"] != 1 {
		t.Fatalf("local observation failed: %#v", payload)
	}
	if _, allowed := bridgeCallableMethods["RunClientQuickCheckReadOnly"]; !allowed {
		t.Fatal("read-only check missing from the trusted bridge allowlist")
	}
}

func TestReadOnlyQuickCheckRejectsExpiredSessionResult(t *testing.T) {
	app := newRunningRouteStrategyTestApp(1)
	app.signalInitDone()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		app.invalidateRouteStrategySession()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	payload := app.runClientQuickCheck(false, true, []clientQuickCheckService{{
		Name: "Local direct fixture", Category: "Direct-Game", URL: server.URL,
	}})
	if payload["sessionValid"] != false || len(app.routeStrategyJobs) != 0 {
		t.Fatal("expired check result was accepted or queued maintenance")
	}
}
