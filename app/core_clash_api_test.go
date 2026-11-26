package main

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSingBoxReadinessWaitsForAuthenticatedVersion(t *testing.T) {
	const secret = "startup-fixture"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/version" || r.Header.Get("Authorization") != "Bearer "+secret {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte("{\"version\":\"sing-box fixture\"}"))
	}))
	defer server.Close()
	port := server.Listener.Addr().(*net.TCPAddr).Port
	exited := make(chan error, 1)
	if err := waitForSingBoxReady(&clashAPIAccess{port: port, secret: secret}, exited, func() bool { return true }, time.Second); err != nil {
		t.Fatal(err)
	}
	if err := waitForSingBoxReady(&clashAPIAccess{port: port, secret: "other"}, exited, func() bool { return true }, 120*time.Millisecond); err == nil {
		t.Fatal("an occupied loopback listener was reported ready without authentication")
	}
	exited <- errors.New("test process exited")
	close(exited)
	if err := waitForSingBoxReady(&clashAPIAccess{port: port, secret: secret}, exited, func() bool { return true }, time.Second); err == nil || !strings.Contains(err.Error(), "test process exited") {
		t.Fatalf("early process exit: %v", err)
	}
}

func TestClashAPIAccessAppliesRandomAuthenticatedEndpoint(t *testing.T) {
	access := newClashAPIAccess()
	if err := access.validate(); err != nil {
		t.Fatalf("newClashAPIAccess() failed: %v", err)
	}
	if len(access.secret) != 64 {
		t.Fatalf("secret length = %d, want 64 hex chars", len(access.secret))
	}
	template := map[string]interface{}{}
	if err := access.apply(template); err != nil {
		t.Fatalf("apply() failed: %v", err)
	}
	experimental := template["experimental"].(map[string]interface{})
	clash := experimental["clash_api"].(map[string]interface{})
	if clash["external_controller"] != net.JoinHostPort("127.0.0.1", strconv.Itoa(access.port)) {
		t.Fatalf("external_controller = %v", clash["external_controller"])
	}
	if clash["secret"] != access.secret {
		t.Fatal("generated config did not receive the process-local secret")
	}
	origins := clash["access_control_allow_origin"].([]interface{})
	if len(origins) != 1 || origins[0] != clashAPIOrigin {
		t.Fatalf("allowed origins = %v, want only %q", origins, clashAPIOrigin)
	}
}

func TestClashAPIClientSendsBearerSecret(t *testing.T) {
	const secret = "unit-test-secret"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer "+secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, portText, err := net.SplitHostPort(parsed.Host)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	app := &App{configBuilder: &ConfigBuilderForStorage{clashAPI: &clashAPIAccess{port: port, secret: secret}}}
	resp, err := app.clashAPIGet(server.Client(), "/proxies")
	if err != nil {
		t.Fatalf("clashAPIGet() failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
}
