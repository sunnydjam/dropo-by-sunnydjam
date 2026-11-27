package dropocore

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestAndroidLiveRoutingKeepsPreparedPoolAndActiveCandidate(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Free, "Free", ownedReserveFixture, true)
	turbo := strings.Replace(ownedReserveFixture, "%2Ffree", "%2Fboost", 1)
	expiry := strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10)
	turbo = strings.Replace(turbo, "expiry=0", "expiry="+expiry, 1)
	sourceSuccess(t, "AddManagedVPNSource", ownedprofile.Boost, "Turbo", turbo, true)
	sourceSuccess(t, "AddVPNSource", "Personal", sourceTestKey)
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("could not prepare candidate pool")
	}
	activeConfig := current.CachedSingBoxConfig
	candidates := append([]androidSourceCandidate(nil), current.preparedSources...)
	SetConnected(true)
	startedAt, totalSessions := current.StartedAt, current.TotalSessions
	for _, candidate := range candidates {
		if !decodeSuccess(BeginAndroidSourceSessionWithActive(candidate.ID)) {
			t.Fatal("could not resume active source")
		}
		apply := func(method, args string) {
			t.Helper()
			result, err := ApplyAndroidRoutingChange(method, args, activeConfig, func(config string) error {
				activeConfig = config
				return nil
			})
			if err != nil || !decodeSuccess(result) {
				t.Fatalf("live %s failed: %s, %v", method, result, err)
			}
		}
		apply("SetRoutingMode", `["blocked_only"]`)
		apply("SetFreeAccessServiceMethod", `["meta","direct"]`)
		assertAndroidLiveMetaRoute(t, activeConfig, "direct", "dns-direct")
		apply("SetRoutingMode", `["all_traffic"]`)
		assertAndroidLiveMetaRoute(t, activeConfig, "", "")
		apply("SetRoutingMode", `["blocked_only"]`)
		assertAndroidLiveMetaRoute(t, activeConfig, "direct", "dns-direct")
		gotID, gotTag := ActiveAndroidSource()
		if gotID != candidate.ID || gotTag != candidate.Tag || !reflect.DeepEqual(current.preparedSources, candidates) ||
			!current.Connected || current.StartedAt != startedAt || current.TotalSessions != totalSessions {
			t.Fatal("policy changes replaced the active source, candidate pool or VPN session")
		}
	}
}

func TestAndroidCustomVPNDomainSurvivesModeChangesAndIsRemovedLive(t *testing.T) {
	resetOwnedReserveTest(t)
	sourceSuccess(t, "AddVPNSource", "Personal", sourceTestKey)
	if !decodeSuccess(BuildSingBoxConfig()) {
		t.Fatal("could not prepare VPN config")
	}
	active := current.CachedSingBoxConfig
	SetConnected(true)
	apply := func(method, args string) {
		t.Helper()
		result, err := ApplyAndroidRoutingChange(method, args, active, func(config string) error {
			active = config
			return nil
		})
		if err != nil || !decodeSuccess(result) {
			t.Fatalf("%s: %s (%v)", method, result, err)
		}
	}
	assertRoute := func(want bool) {
		t.Helper()
		var parsed map[string]interface{}
		if err := json.Unmarshal([]byte(active), &parsed); err != nil {
			t.Fatal(err)
		}
		if androidContainsDomainRoute(parsed, "vk.com", "proxy") != want || androidContainsDNSServer(parsed, "vk.com", "dns-remote") != want {
			t.Fatalf("custom VPN rule presence must be %t", want)
		}
	}
	apply("SetPersonalAddress", `["test.example",false]`)
	apply("SetPersonalAddress", `["8.8.8.8",false]`)
	apply("SetApplicationBinding", `["","com.example.player","user-app-vpn"]`)
	for _, mode := range []string{"all_traffic", "blocked_only"} {
		apply("SetRoutingMode", `["`+mode+`"]`)
		for _, entry := range []string{"test.example", "dropo-user-ips", "8.8.8.8/32", "com.example.player"} {
			if !strings.Contains(active, entry) {
				t.Fatal("personal route missing", entry, mode)
			}
		}
	}
	apply("SetApplicationBinding", `["com.example.player","",""]`)
	apply("SetPersonalAddress", `["test.example",true]`)
	apply("SetPersonalAddress", `["8.8.8.8",true]`)
	for _, entry := range []string{"test.example", "dropo-user-ips", "com.example.player"} {
		if strings.Contains(active, entry) {
			t.Fatal("personal route retained", entry)
		}
	}
	apply("SetCustomVPNService", `["","Custom VK","vk.com",false]`)
	assertRoute(true)
	apply("SetRoutingMode", `["blocked_only"]`)
	assertRoute(true)
	apply("SetRoutingMode", `["all_traffic"]`)
	assertRoute(true)
	args, err := json.Marshal([]any{current.CustomVPNServices[0].ID, "", "", true})
	if err != nil {
		t.Fatal(err)
	}
	apply("SetCustomVPNService", string(args))
	assertRoute(false)
}

func assertAndroidLiveMetaRoute(t *testing.T, config, outbound, dns string) {
	t.Helper()
	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(config), &parsed); err != nil {
		t.Fatal(err)
	}
	if outbound == "" {
		if androidContainsDomainRoute(parsed, "instagram.com", "direct") || androidContainsDomainRoute(parsed, "instagram.com", "proxy") ||
			androidContainsDNSServer(parsed, "instagram.com", "dns-direct") || androidContainsDNSServer(parsed, "instagram.com", "dns-remote") {
			t.Fatal("catalog preset hardcoded a per-service override")
		}
		return
	}
	if !androidContainsDomainRoute(parsed, "instagram.com", outbound) || !androidContainsDNSServer(parsed, "instagram.com", dns) {
		t.Fatalf("expected Instagram route %s and DNS %s", outbound, dns)
	}
	policy := parsed["dns"].(map[string]interface{})
	if dns == "dns-direct" {
		assertAndroidSystemDNS(t, parsed)
		if policy["final"] != "dns-direct" {
			t.Fatal("unselected traffic lost system DNS")
		}
		return
	}
	if policy["final"] != "dns-direct" {
		t.Fatal("ordinary DNS lost its direct route")
	}
	for _, tag := range []string{dns + "-fi", dns, dns + "-lv"} {
		if !androidContainsDNSServer(parsed, "instagram.com", tag) {
			t.Fatalf("missing named DNS transport %s", tag)
		}
	}
}

func TestAndroidLiveRoutingRollbackAndStop(t *testing.T) {
	for _, failure := range []string{"engine", "persist", "stop"} {
		t.Run(failure, func(t *testing.T) {
			refreshedSourceSession(t)
			previous := current.CachedSingBoxConfig
			if failure == "persist" {
				current.BasePath = filepath.Join(t.TempDir(), "not-a-directory")
				if err := os.WriteFile(current.BasePath, nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			calls := 0
			result, err := ApplyAndroidRoutingChange("SetRoutingMode", `["blocked_only"]`, previous, func(config string) error {
				calls++
				if calls == 2 && config != previous {
					t.Fatal("rollback was not based on the running configuration")
				}
				if calls == 1 && failure == "engine" {
					return errors.New("engine rejected config")
				}
				if failure == "stop" {
					CancelPendingSourceWork()
				}
				return nil
			})
			expectedCalls := 2
			if failure == "stop" {
				expectedCalls = 1
			}
			if err != nil || decodeSuccess(result) || calls != expectedCalls || current.Config.RoutingMode != "all_traffic" {
				t.Fatal("failed live update did not preserve the previous mode")
			}
		})
	}
}
