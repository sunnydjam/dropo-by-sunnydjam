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
		assertAndroidLiveMetaRoute(t, activeConfig, "proxy", "dns-remote")
		gotID, gotTag := ActiveAndroidSource()
		if gotID != candidate.ID || gotTag != candidate.Tag || !reflect.DeepEqual(current.preparedSources, candidates) ||
			!current.Connected || current.StartedAt != startedAt || current.TotalSessions != totalSessions {
			t.Fatal("policy changes replaced the active source, candidate pool or VPN session")
		}
	}
}

func assertAndroidLiveMetaRoute(t *testing.T, config, outbound, dns string) {
	t.Helper()
	var parsed map[string]interface{}
	if json.Unmarshal([]byte(config), &parsed) != nil ||
		!androidContainsDomainRoute(parsed, "instagram.com", outbound) ||
		!androidContainsDNSServer(parsed, "instagram.com", dns) {
		t.Fatalf("expected Instagram route %s and DNS %s", outbound, dns)
	}
	policy := parsed["dns"].(map[string]interface{})
	rules := policy["rules"].([]interface{})
	if len(rules) < 7 {
		t.Fatal("live mode change discarded encrypted DNS failover")
	}
	last := rules[len(rules)-7:]
	for i, want := range map[int]string{0: dns + "-fi", 3: dns, 6: dns + "-lv"} {
		if last[i].(map[string]interface{})["server"] != want {
			t.Fatalf("live mode change lost the public DNS chain at %d", i)
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
