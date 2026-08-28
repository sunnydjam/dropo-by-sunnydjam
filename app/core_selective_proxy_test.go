package main

import (
	"strings"
	"testing"
)

func TestSelectiveProxyPACRoutesOnlySelectedDomains(t *testing.T) {
	script, domains, err := buildSelectiveProxyPAC("127.0.0.1:2088", map[string]struct{}{
		"youtube.com": {}, "discord.com": {},
	}, map[string]struct{}{"steamcommunity.com": {}})
	if err != nil {
		t.Fatal(err)
	}
	if len(domains) != 2 || domains[0] != "discord.com" || domains[1] != "youtube.com" {
		t.Fatalf("ordered PAC domains = %v", domains)
	}
	for _, required := range []string{"host === \"youtube.com\"", "dnsDomainIs(host, \".\" + \"discord.com\")", "host === \"steamcommunity.com\"", "PROXY 127.0.0.1:2088", "return \"DIRECT\""} {
		if !strings.Contains(script, required) {
			t.Fatalf("PAC script is missing %q:\n%s", required, script)
		}
	}
	if strings.Index(script, "steamcommunity.com") > strings.Index(script, "PROXY 127.0.0.1:2088") {
		t.Fatal("explicit direct rule must precede selected VPN rules")
	}
	for _, forbidden := range []string{"mistfall", "dnsResolve", "isInNet"} {
		if strings.Contains(strings.ToLower(script), forbidden) {
			t.Fatalf("PAC script contains broad/unwanted token %q", forbidden)
		}
	}
}
