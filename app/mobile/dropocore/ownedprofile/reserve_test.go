package ownedprofile

import (
	"dropocore/dnspolicy"
	"net/url"
	"strings"
	"testing"
	"time"
)

const reserveTestPrimary = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"

func TestManagedGroupsKeepPersonalSourcesAndOwnReserveOrder(t *testing.T) {
	boost := strings.ReplaceAll(strings.ReplaceAll(reserveTestPrimary, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=2000")
	_, freeRelay, _ := Pair(Free, reserveTestPrimary)
	_, boostRelay, _ := Pair(Boost, boost)
	sources := []Source{
		{ID: "free-relay", Provider: FreeReserve, URI: freeRelay, Disabled: true},
		{ID: "personal"},
		{ID: "turbo", Provider: Boost, URI: boost},
		{ID: "free", Provider: Free, URI: reserveTestPrimary},
		{ID: "turbo-relay", Provider: BoostReserve, URI: boostRelay},
	}
	plan := Candidates(sources, time.Unix(1000, 0))
	want := []string{"personal", Boost + "-fi-tcp", Boost + MainSuffix, Boost + ExtraSuffix, Free + "-lv-quic", Free + MainSuffix, Free + ExtraSuffix}
	if len(plan) != len(want) {
		t.Fatalf("expected %d candidates, got %d", len(want), len(plan))
	}
	for i, candidate := range plan {
		if candidate.ID != want[i] || (i >= 1 && i <= 3 && candidate.OwnerID != "turbo") || (i >= 4 && candidate.OwnerID != "free") {
			t.Fatalf("incorrect candidate ownership or order at index %d", i)
		}
	}
	order, ok := Move(sources, "free", 0)
	if !ok || len(order) != len(sources) || order[0] != 3 || order[1] != 0 || order[2] != 1 {
		t.Fatal("reordering did not move an entire group or affected the personal source")
	}
	sources[3].Disabled = true
	plan = Candidates(sources, time.Unix(2001, 0))
	if len(plan) != 1 || plan[0].ID != "personal" {
		t.Fatal("disabled Free or expired Turbo left a reserve active")
	}
}

func TestDirectReserveCompatibilityWithController(t *testing.T) {
	const fiKey = "cec3ca12-ad4b-4714-a401-a31c79362f07"
	const lvKey = "iUhknX5NjVWE2kSZjzYHqxHCSZnivpjJfBZCuCKrbUM"
	const lvVLESS = "5528f6e8-5768-4736-9c6c-608475e5a2dc"
	const fiHysteria = "4YNB5dgsEZB77M9N_uLLJ6DWpXkYQl7PlIZjYns62rc"
	paid := strings.NewReplacer("%2Ffree", "%2Fboost", "expiry=0", "expiry=4102444800").Replace(reserveTestPrimary)
	for _, tier := range []struct{ id, raw, ip, port, legacyKey string }{
		{Boost, paid, dnspolicy.FinlandIPv4, "2444", fiKey},
		{Free, reserveTestPrimary, dnspolicy.LatviaIPv4, "2443", lvKey},
	} {
		routes := DirectReserves(tier.id, tier.raw, time.Now())
		if len(routes) != 3 {
			t.Fatal("expected three regional transports")
		}
		seen := map[string]string{}
		for _, route := range routes {
			key, err := url.Parse(route.URI)
			port := tier.port
			if route.Ingress == XHTTP {
				port = "2446"
			}
			if err != nil || key.Hostname() != tier.ip || key.Port() != port {
				t.Fatalf("%s %s: wrong regional endpoint", tier.id, route.Ingress)
			}
			seen[route.Ingress] = key.User.Username()
		}
		primary, _ := url.Parse(tier.raw)
		if len(seen) != 3 || seen[RegionalIngress(tier.id)] != tier.legacyKey || seen[XHTTP] != seen[Reality] || seen[Reality] == primary.User.Username() || seen[Hysteria] == primary.User.Username() {
			t.Fatal("regional credential partition does not match the backend")
		}
		if tier.id == Free && seen[Reality] != lvVLESS || tier.id == Boost && seen[Hysteria] != fiHysteria {
			t.Fatal("derived transport key differs from the server fixture")
		}
	}
	boost := strings.ReplaceAll(strings.ReplaceAll(reserveTestPrimary, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=2000")
	if len(DirectReserves(Boost, boost, time.Unix(2001, 0))) != 0 || len(DirectReserves("personal", reserveTestPrimary, time.Now())) != 0 {
		t.Fatal("expired Boost or a personal source acquired a managed reserve")
	}
}

func TestOwnedReservePreservesIdentityPoolAndExpiry(t *testing.T) {
	for _, primary := range []string{Free, Boost} {
		raw := reserveTestPrimary
		if primary == Boost {
			raw = strings.ReplaceAll(strings.ReplaceAll(raw, "%2Ffree", "%2Fboost"), "expiry=0", "expiry=2000")
		}
		id, key, err := Pair(primary, raw)
		if err != nil {
			t.Fatal(err)
		}
		original, _ := url.Parse(raw)
		derived, _ := url.Parse(key)
		until, err := Validate(id, key)
		if err != nil || original.User.String() != derived.User.String() || original.Query().Get("dropo_expiry") != derived.Query().Get("dropo_expiry") || Family(id) != primary {
			t.Fatal("reserve changed revocable identity or lifetime")
		}
		if derived.Host != ReserveIPv4+":443" || derived.Query().Get("sni") != ReserveHostname || derived.Query().Get("host") != ReserveHostname {
			t.Fatal("reserve endpoint was not pinned")
		}
		if primary == Boost && (until != 2000 || !Expired(id, key, time.Unix(2001, 0))) {
			t.Fatal("reserve bypassed Boost expiration")
		}
		if _, _, err := Pair(id, key); err == nil {
			t.Fatal("reserve was promoted to a primary")
		}
		for _, test := range []struct {
			name   string
			mutate func(*url.URL)
		}{
			{"wrong_ip", func(u *url.URL) { u.Host = "127.0.0.1:443" }},
			{"wrong_sni", func(u *url.URL) { q := u.Query(); q.Set("sni", "cdn.droponevedimka.ru"); u.RawQuery = q.Encode() }},
			{"wrong_host", func(u *url.URL) { q := u.Query(); q.Set("host", "dropo.fun"); u.RawQuery = q.Encode() }},
			{"plaintext", func(u *url.URL) { q := u.Query(); q.Set("security", "none"); u.RawQuery = q.Encode() }},
			{"insecure", func(u *url.URL) { q := u.Query(); q.Set("allowInsecure", "1"); u.RawQuery = q.Encode() }},
			{"duplicate", func(u *url.URL) { u.RawQuery += "&security=tls" }},
			{"cross_pool", func(u *url.URL) {
				q := u.Query()
				if primary == Free {
					q.Set("path", "/managed/v1/boost")
				} else {
					q.Set("path", "/managed/v1/free")
				}
				u.RawQuery = q.Encode()
			}},
			{"transport_extra", func(u *url.URL) {
				q := u.Query()
				q.Set("extra", `{"downloadSettings":{"address":"evil.example"}}`)
				u.RawQuery = q.Encode()
			}},
		} {
			t.Run(primary+"/"+test.name, func(t *testing.T) {
				u, _ := url.Parse(key)
				test.mutate(u)
				if _, err := Validate(id, u.String()); err == nil {
					t.Fatal("untrusted reserve accepted")
				}
			})
		}
		if _, err := Validate(primary, key); err == nil {
			t.Fatal("reserve accepted under canonical primary ID")
		}
		if _, err := Validate(id, raw); err == nil {
			t.Fatal("primary accepted under reserve ID")
		}
	}
	if _, _, err := Pair("personal", reserveTestPrimary); err == nil {
		t.Fatal("personal source converted to managed")
	}
}

func TestOwnedReserveTransportBudgetUsesOnlyExactEndpoint(t *testing.T) {
	for _, pool := range []string{"free", "boost"} {
		s := map[string]interface{}{"path": "/managed/v1/" + pool}
		if !ApplyXHTTPBudget(ReserveIPv4, 443, "tls", ReserveHostname, ReserveHostname, s) {
			t.Fatal("reserve missing carrier budget")
		}
		xmux := s["extra"].(map[string]interface{})["xmux"].(map[string]interface{})
		if xmux["maxConnections"] != 1 {
			t.Fatal("unbounded carrier count")
		}
	}
	for _, host := range []string{"dropo.fun", "evil.example"} {
		s := map[string]interface{}{"path": "/managed/v1/free"}
		if ApplyXHTTPBudget(ReserveIPv4, 443, "tls", host, host, s) || len(s) != 1 {
			t.Fatal("foreign transport changed")
		}
	}
}

func TestRegionalRoutesAcceptCachedPrimaryAndKeepTierScope(t *testing.T) {
	now := time.Unix(1000, 0)
	for _, host := range []string{"193.233.88.97", "cdn.droponevedimka.ru", PrimaryIPv4} {
		raw := strings.Replace(reserveTestPrimary, "@193.233.88.97", "@"+host, 1)
		if len(DirectReserves(Free, raw, now)) != 3 {
			t.Fatal("legacy Free credential did not migrate")
		}
	}
	for _, bad := range []string{"personal", FreeReserve, Boost} {
		if len(DirectReserves(bad, reserveTestPrimary, now)) != 0 {
			t.Fatal("cross-tier or unowned credential accepted")
		}
	}
}
