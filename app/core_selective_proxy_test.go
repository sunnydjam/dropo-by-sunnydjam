package main

import (
	"strings"
	"testing"
)

func TestSelectiveProxyPACRoutesOnlySelectedDomains(t *testing.T) {
	script, domains, err := buildSelectiveProxyPAC(
		"127.0.0.1:2088", "127.0.0.1:2089",
		map[string]struct{}{"chatgpt.com": {}},
		map[string]struct{}{"youtube.com": {}, "discord.com": {}},
		map[string]struct{}{"steamcommunity.com": {}, "steamstatic.com": {}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(domains) != 3 || domains[0] != "chatgpt.com" || domains[1] != "discord.com" || domains[2] != "youtube.com" {
		t.Fatalf("ordered PAC domains = %v", domains)
	}
	for _, required := range []string{"host === \"youtube.com\"", "dnsDomainIs(host, \".\" + \"discord.com\")", "host === \"steamcommunity.com\"", "host === \"steamstatic.com\"", "PROXY 127.0.0.1:2088", "PROXY 127.0.0.1:2089", "https:", "return \"DIRECT\""} {
		if !strings.Contains(script, required) {
			t.Fatalf("PAC script is missing %q:\n%s", required, script)
		}
	}
	if strings.Index(script, "steamcommunity.com") > strings.Index(script, "PROXY 127.0.0.1:2088") {
		t.Fatal("explicit direct rule must precede selected VPN rules")
	}
	if strings.Index(script, "steamstatic.com") > strings.Index(script, "PROXY 127.0.0.1:2088") {
		t.Fatal("Steam CDN direct rule must precede selected VPN rules")
	}
	if strings.Index(script, "steamcommunity.com") > strings.Index(script, "PROXY 127.0.0.1:2089") {
		t.Fatal("explicit direct rule must precede selected Zapret rules")
	}
	for _, forbidden := range []string{"mistfall", "dnsResolve", "isInNet"} {
		if strings.Contains(strings.ToLower(script), forbidden) {
			t.Fatalf("PAC script contains broad/unwanted token %q", forbidden)
		}
	}
}
