//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

type updatePolicyTransport func(*http.Request) (*http.Response, error)

func (transport updatePolicyTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

func TestUpdateCheckOnlyReportsMetadataAndKeepsVPNRunning(t *testing.T) {
	// These process-local mocks never start the core, contact GitHub, write an
	// installer or invoke the installed application's networking lifecycle.
	previousClient, previousDownloadClient, previousVersion := HTTPClient, LongHTTPClient, Version
	t.Cleanup(func() {
		HTTPClient, LongHTTPClient, Version = previousClient, previousDownloadClient, previousVersion
	})
	Version = "3.0.33"
	var downloadRequests atomic.Int32
	LongHTTPClient = &http.Client{Transport: updatePolicyTransport(func(*http.Request) (*http.Response, error) {
		downloadRequests.Add(1)
		return nil, fmt.Errorf("an update check must not download an artifact")
	})}
	for _, unavailable := range []bool{false, true} {
		t.Run(map[bool]string{false: "available", true: "metadata-unavailable"}[unavailable], func(t *testing.T) {
			var metadataRequests atomic.Int32
			HTTPClient = &http.Client{Transport: updatePolicyTransport(func(request *http.Request) (*http.Response, error) {
				metadataRequests.Add(1)
				if request.Method != http.MethodGet || request.URL.Hostname() != "api.github.com" || request.URL.Path != "/repos/"+GitHubRepo+"/releases" {
					t.Errorf("check requested non-metadata URL: %s %s", request.Method, request.URL)
					return nil, fmt.Errorf("unexpected request")
				}
				if unavailable {
					return nil, fmt.Errorf("metadata unavailable fixture")
				}
				assets := make([]GitHubReleaseAsset, 0, 2)
				for _, name := range []string{"dropo-Windows-Setup-x64.exe", "dropo-Windows-Portable-x64.zip"} {
					assets = append(assets, GitHubReleaseAsset{
						Name: name, Size: 123, Digest: "sha256:" + strings.Repeat("a", 64),
						BrowserDownloadURL: GitHubURL + "/releases/download/v3.0.34/" + name,
					})
				}
				body, err := json.Marshal([]GitHubRelease{{TagName: "v3.0.34", HTMLURL: GitHubURL + "/releases/tag/v3.0.34", Assets: assets}})
				if err != nil {
					return nil, err
				}
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(body))), Request: request}, nil
			})}
			app := &App{isRunning: true}
			result := app.CheckForUpdates()
			if result["success"] != !unavailable {
				t.Fatalf("check result = %v", result)
			}
			if !unavailable && (result["hasUpdate"] != true || result["latestVersion"] != "3.0.34") {
				t.Fatalf("available release was not reported: %v", result)
			}
			if metadataRequests.Load() != 1 || downloadRequests.Load() != 0 {
				t.Fatalf("metadata calls=%d, artifact calls=%d", metadataRequests.Load(), downloadRequests.Load())
			}
			if !app.isVPNRunning() || app.vpnStopping.Load() || app.reconnecting.Load() || app.reconnectGeneration.Load() != 0 {
				t.Fatal("checking release metadata mutated the active VPN lifecycle")
			}
		})
	}
}
