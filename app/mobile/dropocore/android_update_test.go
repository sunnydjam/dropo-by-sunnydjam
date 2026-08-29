package dropocore

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSelectLatestAndroidReleaseSkipsReleaseWithoutTrustedAPK(t *testing.T) {
	data := `[
		{"tag_name":"v3.0.4","assets":[{"name":"dropo-Windows-x64.exe","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Windows-x64.exe","size":10}]},
		{"tag_name":"v3.0.3","assets":[{"name":"dropo-Android-arm64.apk","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.3/dropo-Android-arm64.apk","size":20}]}
	]`
	var releases []androidGitHubRelease
	if err := json.Unmarshal([]byte(data), &releases); err != nil {
		t.Fatal(err)
	}
	_, version, name, downloadURL, size, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam")
	if !ok || version != "3.0.3" || name != "dropo-Android-arm64.apk" || size != 20 {
		t.Fatalf("selection = ok:%v version:%q name:%q size:%d", ok, version, name, size)
	}
	if downloadURL != "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.3/dropo-Android-arm64.apk" {
		t.Fatalf("download URL = %q", downloadURL)
	}
}

func TestCheckAndroidUpdatesUsesReleaseListAndReportsNewVersion(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/sunnydjam/dropo-by-sunnydjam/releases" || r.URL.Query().Get("per_page") != "100" {
			t.Fatalf("unexpected request: %s", r.URL.String())
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[{"tag_name":"v3.0.4","html_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v3.0.4","assets":[{"name":"dropo-Android-arm64.apk","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Android-arm64.apk","size":123}]}]`))
	}))
	defer server.Close()

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(checkAndroidUpdatesWithClient(server.Client(), server.URL, "sunnydjam/dropo-by-sunnydjam", "3.0.3")), &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != true || result["hasUpdate"] != true || result["latestVersion"] != "3.0.4" {
		t.Fatalf("unexpected update response: %#v", result)
	}
}

func TestSelectLatestAndroidReleaseRejectsForeignAssetHost(t *testing.T) {
	var releases []androidGitHubRelease
	if err := json.Unmarshal([]byte(`[{"tag_name":"v3.0.4","assets":[{"name":"dropo-Android-arm64.apk","browser_download_url":"https://github.com/Droponevedimka/dropo/releases/download/v3.0.4/dropo-Android-arm64.apk","size":123}]}]`), &releases); err != nil {
		t.Fatal(err)
	}
	if _, _, _, _, _, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam"); ok {
		t.Fatal("foreign Android asset host was accepted")
	}
}
