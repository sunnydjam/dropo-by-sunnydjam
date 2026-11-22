package dropocore

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSelectLatestAndroidReleaseSkipsReleaseWithoutTrustedAPK(t *testing.T) {
	data := `[
		{"tag_name":"v3.0.4","assets":[{"name":"dropo-Windows-x64.exe","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Windows-x64.exe","size":10}]},
		{"tag_name":"v3.0.3","assets":[{"name":"dropo-Android-arm64.apk","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.3/dropo-Android-arm64.apk","size":20},{"name":"dropo-Android-arm64.apk.sha256","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.3/dropo-Android-arm64.apk.sha256","size":96}]}
	]`
	var releases []androidGitHubRelease
	if err := json.Unmarshal([]byte(data), &releases); err != nil {
		t.Fatal(err)
	}
	_, version, name, downloadURL, size, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam", "stable", "arm64")
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
		_, _ = w.Write([]byte(`[{"tag_name":"v3.0.4","html_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v3.0.4","assets":[{"name":"dropo-Android-arm64.apk","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Android-arm64.apk","size":123},{"name":"dropo-Android-arm64.apk.sha256","browser_download_url":"https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.4/dropo-Android-arm64.apk.sha256","size":96}]}]`))
	}))
	defer server.Close()

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(checkAndroidUpdatesForArchitecture(server.Client(), server.URL, "sunnydjam/dropo-by-sunnydjam", "3.0.3", "arm64")), &result); err != nil {
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
	if _, _, _, _, _, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam", "stable", "arm64"); ok {
		t.Fatal("foreign Android asset host was accepted")
	}
}

func androidReleaseWithAssetsForTest(tag string, names ...string) androidGitHubRelease {
	release := androidGitHubRelease{TagName: tag}
	for _, name := range names {
		release.Assets = append(release.Assets, struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
			Size               int64  `json:"size"`
		}{Name: name, BrowserDownloadURL: "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/" + tag + "/" + name, Size: 123})
		if strings.HasSuffix(name, ".apk") {
			release.Assets = append(release.Assets, struct {
				Name               string `json:"name"`
				BrowserDownloadURL string `json:"browser_download_url"`
				Size               int64  `json:"size"`
			}{Name: name + ".sha256", BrowserDownloadURL: "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/" + tag + "/" + name + ".sha256", Size: 96})
		}
	}
	return release
}

func TestAndroidUpdateAssetSeparatesPackagesAndArchitectures(t *testing.T) {
	const stableUniversal = "dropo-Android-universal.apk"
	const stableARM64 = "dropo-Android-arm64.apk"
	const previewUniversal = "dropo-Android-Preview-universal.apk"
	const previewARM64 = "dropo-Android-Preview-arm64.apk"
	tests := []struct {
		name, channel, architecture string
		assets                      []string
		want                        string
	}{
		{"stable prefers universal", "stable", "arm64", []string{previewUniversal, stableARM64, stableUniversal}, stableUniversal},
		{"preview prefers universal", "preview", "arm64", []string{stableUniversal, previewARM64, previewUniversal}, previewUniversal},
		{"stable arm64 fallback", "stable", "arm64", []string{previewUniversal, stableARM64}, stableARM64},
		{"preview arm64 fallback", "preview", "arm64", []string{stableUniversal, previewARM64}, previewARM64},
		{"stable ARMv7 universal", "stable", "arm", []string{stableARM64, stableUniversal}, stableUniversal},
		{"preview ARMv7 universal", "preview", "arm", []string{previewARM64, previewUniversal}, previewUniversal},
		{"stable ARMv7 rejects arm64", "stable", "arm", []string{stableARM64}, ""},
		{"preview ARMv7 rejects arm64", "preview", "arm", []string{previewARM64}, ""},
		{"stable never takes preview", "stable", "arm64", []string{previewUniversal, previewARM64}, ""},
		{"preview never takes stable", "preview", "arm64", []string{stableUniversal, stableARM64}, ""},
		{"no arbitrary Android APK", "stable", "arm64", []string{"android-test.apk", "dropo-Android.apk", "dropo-Android-Preview-services.apk"}, ""},
		{"no incompatible x86 package", "stable", "amd64", []string{stableUniversal, stableARM64}, ""},
		{"no unknown channel", "beta", "arm64", []string{stableUniversal, previewUniversal}, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			name, downloadURL, size := androidUpdateAsset(androidReleaseWithAssetsForTest("v3.0.41", test.assets...), test.channel, test.architecture)
			if name != test.want {
				t.Fatalf("asset = %q, want %q", name, test.want)
			}
			if test.want == "" && (downloadURL != "" || size != 0) {
				t.Fatal("incompatible package retained download metadata")
			}
		})
	}
}

func TestLatestAndroidReleaseRemainsInInstalledPackageChannel(t *testing.T) {
	releases := []androidGitHubRelease{
		androidReleaseWithAssetsForTest("v3.0.43", "dropo-Windows-Setup-x64.exe"),
		androidReleaseWithAssetsForTest("v3.0.42", "dropo-Android-Preview-universal.apk"),
		androidReleaseWithAssetsForTest("v3.0.41", "dropo-Android-universal.apk"),
		androidReleaseWithAssetsForTest("v3.0.40", "dropo-Android-universal.apk", "dropo-Android-Preview-universal.apk"),
	}
	for _, test := range []struct{ channel, version, asset string }{
		{"stable", "3.0.41", "dropo-Android-universal.apk"},
		{"preview", "3.0.42-preview", "dropo-Android-Preview-universal.apk"},
	} {
		_, version, asset, _, _, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam", test.channel, "arm64")
		if !ok || version != test.version || asset != test.asset {
			t.Fatalf("%s selected %q %q (found=%v)", test.channel, version, asset, ok)
		}
	}
}

func TestLatestAndroidReleaseSkipsIncompatibleNewerARM64OnlyVersion(t *testing.T) {
	releases := []androidGitHubRelease{
		androidReleaseWithAssetsForTest("v3.0.42", "dropo-Android-arm64.apk"),
		androidReleaseWithAssetsForTest("v3.0.41", "dropo-Android-universal.apk"),
	}
	for _, test := range []struct{ architecture, version string }{
		{"arm", "3.0.41"}, {"arm64", "3.0.42"},
	} {
		_, version, _, _, _, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam", "stable", test.architecture)
		if !ok || version != test.version {
			t.Fatalf("%s selected %q (found=%v), want %q", test.architecture, version, ok, test.version)
		}
	}
}

func TestLatestAndroidReleaseRejectsCrossPackageDownloadPath(t *testing.T) {
	for _, channel := range []string{"stable", "preview"} {
		asset, other := "dropo-Android-universal.apk", "dropo-Android-Preview-universal.apk"
		if channel == "preview" {
			asset, other = other, asset
		}
		release := androidReleaseWithAssetsForTest("v3.0.41", asset)
		release.Assets[0].BrowserDownloadURL = strings.Replace(release.Assets[0].BrowserDownloadURL, asset, other, 1)
		if _, _, _, _, _, ok := selectLatestAndroidRelease([]androidGitHubRelease{release}, "sunnydjam/dropo-by-sunnydjam", channel, "arm64"); ok {
			t.Fatalf("%s accepted the other package's APK URL", channel)
		}
	}
}

func TestLatestAndroidReleaseUsesOnlyStableRecordsWithValidAssetSize(t *testing.T) {
	draft := androidReleaseWithAssetsForTest("v3.0.46", "dropo-Android-universal.apk")
	draft.Draft = true
	prerelease := androidReleaseWithAssetsForTest("v3.0.45", "dropo-Android-universal.apk")
	prerelease.Prerelease = true
	empty := androidReleaseWithAssetsForTest("v3.0.44", "dropo-Android-universal.apk")
	empty.Assets[0].Size = 0
	releases := []androidGitHubRelease{
		draft, prerelease, empty,
		androidReleaseWithAssetsForTest("v3.0.43-preview", "dropo-Android-universal.apk"),
		androidReleaseWithAssetsForTest("v3.0.42-rc.1", "dropo-Android-universal.apk"),
		androidReleaseWithAssetsForTest("v3.0.41", "dropo-Android-universal.apk"),
	}
	if _, version, _, _, _, ok := selectLatestAndroidRelease(releases, "sunnydjam/dropo-by-sunnydjam", "stable", "arm64"); !ok || version != "3.0.41" {
		t.Fatalf("selected %q (found=%v), want stable 3.0.41", version, ok)
	}
}

func TestAndroidUpdateResponseUsesInstalledVersionChannel(t *testing.T) {
	for _, test := range []struct {
		name, current, channel, latest, asset string
		hasUpdate                             bool
	}{
		{"stable newer", "3.0.40", "stable", "3.0.41", "dropo-Android-universal.apk", true},
		{"preview newer", "3.0.40-preview", "preview", "3.0.41-preview", "dropo-Android-Preview-universal.apk", true},
		{"stable current", "3.0.41", "stable", "3.0.41", "dropo-Android-universal.apk", false},
		{"preview current", "3.0.41-preview", "preview", "3.0.41-preview", "dropo-Android-Preview-universal.apk", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			releases := []androidGitHubRelease{androidReleaseWithAssetsForTest("v3.0.41", "dropo-Android-arm64.apk", "dropo-Android-Preview-arm64.apk", "dropo-Android-universal.apk", "dropo-Android-Preview-universal.apk")}
			data, err := json.Marshal(releases)
			if err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(data)
			}))
			defer server.Close()
			var result map[string]interface{}
			if err := json.Unmarshal([]byte(checkAndroidUpdatesForArchitecture(server.Client(), server.URL, "sunnydjam/dropo-by-sunnydjam", test.current, "arm64")), &result); err != nil {
				t.Fatal(err)
			}
			if result["success"] != true || result["hasUpdate"] != test.hasUpdate || result["latestVersion"] != test.latest ||
				result["currentVersion"] != test.current || result["assetName"] != test.asset || result["updateChannel"] != test.channel || result["selfUpdate"] != true {
				t.Fatalf("unexpected %s response: %#v", test.name, result)
			}
		})
	}
}

func TestAndroidPreviewUpdateDoesNotOfferStableOnlyRelease(t *testing.T) {
	data, err := json.Marshal([]androidGitHubRelease{androidReleaseWithAssetsForTest("v3.0.41", "dropo-Android-universal.apk")})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(data)
	}))
	defer server.Close()
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(checkAndroidUpdatesForArchitecture(server.Client(), server.URL, "sunnydjam/dropo-by-sunnydjam", "3.0.40-preview", "arm64")), &result); err != nil {
		t.Fatal(err)
	}
	if result["success"] != true || result["hasUpdate"] != false || result["latestVersion"] != "3.0.40-preview" || result["updateChannel"] != "preview" || result["downloadURL"] != nil {
		t.Fatalf("Preview offered an incompatible production install: %#v", result)
	}
}

func TestAndroidUpdateSkipsMissingOrInvalidChecksumSidecar(t *testing.T) {
	for _, mutate := range []struct {
		name string
		edit func(*androidGitHubRelease)
	}{
		{"missing", func(r *androidGitHubRelease) { r.Assets = r.Assets[:1] }},
		{"empty", func(r *androidGitHubRelease) { r.Assets[1].Size = 0 }},
		{"unbounded", func(r *androidGitHubRelease) { r.Assets[1].Size = 1025 }},
		{"foreign", func(r *androidGitHubRelease) { r.Assets[1].BrowserDownloadURL = "https://example.test/file.sha256" }},
		{"wrong name", func(r *androidGitHubRelease) { r.Assets[1].Name = "another.apk.sha256" }},
		{"wrong release", func(r *androidGitHubRelease) {
			r.Assets[1].BrowserDownloadURL = strings.Replace(r.Assets[1].BrowserDownloadURL, "v3.0.44", "v3.0.43", 1)
		}},
	} {
		t.Run(mutate.name, func(t *testing.T) {
			r := androidReleaseWithAssetsForTest("v3.0.44", "dropo-Android-Preview-universal.apk")
			mutate.edit(&r)
			if _, _, _, _, _, ok := selectLatestAndroidRelease([]androidGitHubRelease{r}, "sunnydjam/dropo-by-sunnydjam", "preview", "arm64"); ok {
				t.Fatal("incomplete/untrusted APK update was advertised")
			}
		})
	}
}

func TestAndroidUpdateURLRejectsPortsQueriesFragmentsAndCredentials(t *testing.T) {
	valid := "https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.44/dropo-Android-Preview-universal.apk"
	for _, value := range []string{
		valid + "?token=secret", valid + "#APK",
		strings.Replace(valid, "github.com", "github.com:444", 1),
		strings.Replace(valid, "github.com", "user:password@github.com", 1),
	} {
		if trustedAndroidDownloadURL(value, "sunnydjam/dropo-by-sunnydjam") {
			t.Fatalf("unsafe update URL was accepted: %q", value)
		}
	}
}

func TestAndroidUpdateRejectsAnAssetFromAnotherReleaseTag(t *testing.T) {
	release := androidReleaseWithAssetsForTest("v3.0.44", "dropo-Android-Preview-universal.apk")
	for i := range release.Assets {
		release.Assets[i].BrowserDownloadURL = strings.Replace(release.Assets[i].BrowserDownloadURL, "v3.0.44", "v3.0.43", 1)
	}
	if _, _, _, _, _, ok := selectLatestAndroidRelease([]androidGitHubRelease{release}, "sunnydjam/dropo-by-sunnydjam", "preview", "arm64"); ok {
		t.Fatal("new release advertised the APK from an older tag")
	}
}

func TestAndroidUpdateResponseAdvertisesNativeInstallerWithChecksum(t *testing.T) {
	release := androidReleaseWithAssetsForTest("v3.0.44", "dropo-Android-Preview-universal.apk")
	data, err := json.Marshal([]androidGitHubRelease{release})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(data)
	}))
	defer server.Close()
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(checkAndroidUpdatesForArchitecture(server.Client(), server.URL, "sunnydjam/dropo-by-sunnydjam", "3.0.43-preview", "arm64")), &result); err != nil {
		t.Fatal(err)
	}
	if result["selfUpdate"] != true || result["hasUpdate"] != true || result["checksumURL"] != result["downloadURL"].(string)+".sha256" {
		t.Fatalf("native installer metadata missing: %#v", result)
	}
}
