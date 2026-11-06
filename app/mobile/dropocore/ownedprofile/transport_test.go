package ownedprofile

import "testing"

func TestManagedBudgetCannotBeOverriddenAndDoesNotChangeOtherProviders(t *testing.T) {
	for _, path := range []string{"/managed/v1/free", "/managed/v1/boost/"} {
		s := map[string]interface{}{"path": path, "extra": map[string]interface{}{"xmux": map[string]interface{}{"maxConnections": 100}, "xPaddingBytes": "100-200"}}
		if !ApplyXHTTPBudget("193.233.88.97", 443, "tls", "cdn.droponevedimka.ru", "cdn.droponevedimka.ru", s) {
			t.Fatal("managed endpoint not recognized")
		}
		e := s["extra"].(map[string]interface{})
		x := e["xmux"].(map[string]interface{})
		if x["maxConnections"] != 1 || x["maxConcurrency"] != 0 || e["xPaddingBytes"] != "100-200" {
			t.Fatal("carrier budget or unrelated padding changed")
		}
	}
	for _, server := range []string{"third-party.example", "193.233.88.97"} {
		s := map[string]interface{}{"path": "/legacy"}
		if ApplyXHTTPBudget(server, 443, "tls", "cdn.droponevedimka.ru", "cdn.droponevedimka.ru", s) || len(s) != 1 {
			t.Fatal("unmanaged transport changed")
		}
	}
}
