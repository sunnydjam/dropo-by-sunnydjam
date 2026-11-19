package ownedprofile

import (
	"net/url"
	"strings"
	"testing"
	"time"
)

const reserveTestPrimary = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"

func TestDirectReserveCompatibilityWithController(t *testing.T) {
	const fiKey = "cec3ca12-ad4b-4714-a401-a31c79362f07"
	const lvKey = "iUhknX5NjVWE2kSZjzYHqxHCSZnivpjJfBZCuCKrbUM"
	want := []struct{ scheme, port, key string }{{"vless", "2443", fiKey}, {"hysteria2", "2443", lvKey}}
	candidates := DirectReserves(Free, reserveTestPrimary, time.Now())
	if len(candidates) != len(want) {
		t.Fatal("expected both direct transports")
	}
	for i, candidate := range candidates {
		link, err := url.Parse(candidate.URI)
		if err != nil || link.Scheme != want[i].scheme || link.Port() != want[i].port || link.User.Username() != want[i].key {
			t.Fatalf("direct reserve %d does not match the backend contract", i)
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
