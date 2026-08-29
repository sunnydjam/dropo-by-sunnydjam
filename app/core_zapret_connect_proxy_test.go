package main

import (
	"testing"

	traffic "dropo/trafficorchestrator"
)

func TestZapretConnectScopeAllowsOnlySelectedServicesAndDirectWins(t *testing.T) {
	plan := traffic.TrafficPlan{
		Services: []traffic.ServiceRule{
			{ID: "youtube", DomainSuffixes: []string{"youtube.com", "googlevideo.com"}, TCPPorts: []int{80, 443}},
			{ID: "discord", ExactHosts: []string{"gateway.discord.gg"}, DomainSuffixes: []string{"discord.com", "discord.media"}, TCPPorts: []int{443, 2053, 2083, 2087, 2096, 8443}},
			{ID: "openai", DomainSuffixes: []string{"chatgpt.com"}, TCPPorts: []int{443}},
		},
		Routes: []traffic.ServiceRoute{
			{ServiceID: "youtube", Kind: traffic.ServiceRouteZapret},
			{ServiceID: "discord", Kind: traffic.ServiceRouteZapret},
			{ServiceID: "openai", Kind: traffic.ServiceRouteVPN},
		},
		DirectRules: []traffic.DirectRule{{ID: "steam-direct", DomainSuffixes: []string{"steamcommunity.com", "steamstatic.com"}}},
	}
	scope, err := compileZapretConnectScope(plan)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range []struct {
		host string
		port int
	}{
		{"www.youtube.com", 443}, {"rr1.googlevideo.com", 443}, {"gateway.discord.gg", 443}, {"cdn.discord.com", 2053},
	} {
		if !scope.allows(target.host, target.port) {
			t.Fatalf("selected Zapret target rejected: %s:%d", target.host, target.port)
		}
	}
	for _, target := range []struct {
		host string
		port int
	}{
		{"www.youtube.com", 8443}, {"chatgpt.com", 443}, {"store.steamcommunity.com", 443}, {"cdn.steamstatic.com", 443}, {"example.com", 443},
	} {
		if scope.allows(target.host, target.port) {
			t.Fatalf("non-Zapret/direct target accepted: %s:%d", target.host, target.port)
		}
	}
}

func TestParseConnectTargetRejectsIPAndMalformedTargets(t *testing.T) {
	host, port, target, err := parseConnectTarget("gateway.discord.gg:443")
	if err != nil || host != "gateway.discord.gg" || port != 443 || target != "gateway.discord.gg:443" {
		t.Fatalf("valid CONNECT target parsed as host=%q port=%d target=%q err=%v", host, port, target, err)
	}
	for _, value := range []string{"127.0.0.1:443", "[::1]:443", "discord.com:0", "discord.com:70000", "bad host:443"} {
		if _, _, _, err := parseConnectTarget(value); err == nil {
			t.Fatalf("unsafe CONNECT target accepted: %q", value)
		}
	}
}

func TestZapretSourcePortPoolIsBoundedAndReusable(t *testing.T) {
	pool := zapretSourcePortPool{next: zapretConnectSourcePortFirst, active: make(map[int]struct{})}
	seen := make(map[int]struct{}, zapretConnectSourcePortLast-zapretConnectSourcePortFirst+1)
	for {
		port, ok := pool.acquire()
		if !ok {
			break
		}
		if port < zapretConnectSourcePortFirst || port > zapretConnectSourcePortLast {
			t.Fatalf("source port outside scoped range: %d", port)
		}
		seen[port] = struct{}{}
	}
	if len(seen) != zapretConnectSourcePortLast-zapretConnectSourcePortFirst+1 {
		t.Fatalf("source port pool size = %d", len(seen))
	}
	pool.release(zapretConnectSourcePortFirst)
	if port, ok := pool.acquire(); !ok || port != zapretConnectSourcePortFirst {
		t.Fatalf("released source port was not reusable: port=%d ok=%t", port, ok)
	}
}
