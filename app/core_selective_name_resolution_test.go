package main

import (
	"bytes"
	"strings"
	"testing"

	traffic "dropo/trafficorchestrator"
)

func TestSelectiveHostsOverlayIsScopedAndReversible(t *testing.T) {
	input := []byte("# keep\r\n23.227.38.74 discord.com\r\n203.0.113.8 game.example steam.example # direct\r\n")
	output, disabled, conflicts := disableSelectedVPNHostsMappings(input, map[string]struct{}{"discord.com": {}})
	if disabled != 1 || conflicts != 0 {
		t.Fatalf("disabled=%d conflicts=%d", disabled, conflicts)
	}
	if strings.Contains(string(output), "\r\n23.227.38.74 discord.com\r\n") {
		t.Fatal("selected VPN mapping remained active")
	}
	if !strings.Contains(string(output), "203.0.113.8 game.example steam.example # direct") {
		t.Fatal("unrelated game mapping changed")
	}
	restored, count := restoreSelectedVPNHostsMappings(output)
	if count != 1 || !bytes.Equal(restored, input) {
		t.Fatalf("hosts overlay was not exactly reversible: count=%d\n%s", count, restored)
	}
}

func TestSelectiveHostsOverlayRejectsMixedServiceRecord(t *testing.T) {
	input := []byte("203.0.113.8 discord.com game.example\n")
	output, disabled, conflicts := disableSelectedVPNHostsMappings(input, map[string]struct{}{"discord.com": {}})
	if disabled != 0 || conflicts != 1 || !bytes.Equal(output, input) {
		t.Fatalf("mixed mapping changed: disabled=%d conflicts=%d output=%q", disabled, conflicts, output)
	}
}

func TestSelectiveHostsOverlayDoesNotMatchDeceptiveSuffix(t *testing.T) {
	input := []byte("203.0.113.8 notdiscord.com\n")
	output, disabled, conflicts := disableSelectedVPNHostsMappings(input, map[string]struct{}{"discord.com": {}})
	if disabled != 0 || conflicts != 0 || !bytes.Equal(output, input) {
		t.Fatalf("deceptive suffix changed: disabled=%d conflicts=%d output=%q", disabled, conflicts, output)
	}
}

func TestSelectiveFakeHostsOverlayIsExactScopedAndReversible(t *testing.T) {
	input := []byte("# keep\r\n203.0.113.8 game.example # direct\r\n")
	output, installed := installSelectiveFakeHosts(input, []selectiveFakeHostMapping{
		{Address: "198.18.1.10", Host: "updates.discord.com"},
		{Address: "invalid", Host: "ignored.example"},
	})
	if installed != 1 {
		t.Fatalf("installed=%d", installed)
	}
	if !strings.Contains(string(output), "198.18.1.10 updates.discord.com # dropo-selective-vpn-fake\r\n") {
		t.Fatalf("fake mapping missing: %q", output)
	}
	if !strings.Contains(string(output), "203.0.113.8 game.example # direct\r\n") {
		t.Fatal("unrelated direct mapping changed")
	}
	restored, removed := removeSelectiveFakeHosts(output)
	if removed != 1 || !bytes.Equal(restored, input) {
		t.Fatalf("fake overlay was not exactly reversible: removed=%d\n%s", removed, restored)
	}
}

func TestSelectiveFakeHostMappingsFollowTypedVPNRoute(t *testing.T) {
	plan := traffic.TrafficPlan{
		Revision: 1, CatalogRevision: "overlay-test",
		Services: []traffic.ServiceRule{{
			ID: "discord", DisplayName: "Discord", ExactHosts: []string{"updates.discord.com"},
			DomainSuffixes: []string{"discord.com"}, TCPPorts: []int{443},
		}},
		Routes: []traffic.ServiceRoute{{ServiceID: "discord", Kind: traffic.ServiceRouteVPN}},
	}
	directory, err := traffic.NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	mappings := selectedVPNFakeHostMappings(plan, directory)
	if len(mappings) != 1 || mappings[0].Host != "updates.discord.com" || !strings.HasPrefix(mappings[0].Address, "198.") {
		t.Fatalf("VPN bootstrap mappings = %#v", mappings)
	}
	plan.Revision++
	plan.Routes[0].Kind = traffic.ServiceRouteDirect
	if err := directory.ApplyPlan(plan); err != nil {
		t.Fatal(err)
	}
	if mappings := selectedVPNFakeHostMappings(plan, directory); len(mappings) != 0 {
		t.Fatalf("direct route retained fake mappings: %#v", mappings)
	}
}
