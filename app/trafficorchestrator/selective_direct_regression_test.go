package trafficorchestrator

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestSelectiveRuntimeLeavesSteamAndGameTrafficByteForByteDirect(t *testing.T) {
	plan := fakeIPTestPlan()
	plan.DirectRules = []DirectRule{{
		ID: "latency-sensitive-direct",
		DomainSuffixes: []string{
			"steampowered.com",
			"steamcommunity.com",
		},
		ProcessNames: []string{
			"steam.exe",
			"steamwebhelper.exe",
			"MistfallHunter-Win64-Shipping.exe",
		},
	}}

	tests := []struct {
		name        string
		processName string
		packet      func(*testing.T) []byte
	}{
		{
			name:        "Steam TLS on a shared selected-service address",
			processName: `C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe`,
			packet: func(t *testing.T) []byte {
				return testIPv4TCPPacketTo(t, "66.22.200.1", "store.steampowered.com")
			},
		},
		{
			name:        "Steam WebHelper CDN TLS remains direct",
			processName: `C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe`,
			packet: func(t *testing.T) []byte {
				return testIPv4TCPPacketTo(t, "142.250.74.206", "cdn.cloudflare.steamstatic.com")
			},
		},
		{
			name:        "Steam WebHelper QUIC remains direct",
			processName: `C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe`,
			packet: func(t *testing.T) []byte {
				return testIPv4UDPPacket("8.8.4.4", 443, []byte{0xc0, 0, 0, 0, 1, 7, 9, 11})
			},
		},
		{
			name:        "Mistfall Hunter QUIC-like game datagram",
			processName: `E:\SteamLibrary\steamapps\common\Mistfall Hunter\MistfallHunter\Binaries\Win64\MistfallHunter-Win64-Shipping.exe`,
			packet: func(*testing.T) []byte {
				return testIPv4UDPPacket("66.22.200.1", 443, []byte{0xc0, 0, 0, 0, 1, 7, 9, 11})
			},
		},
		{
			name:        "opaque Mistfall Hunter UDP media",
			processName: `E:\SteamLibrary\steamapps\common\Mistfall Hunter\MistfallHunter\Binaries\Win64\MistfallHunter-Win64-Shipping.exe`,
			packet: func(*testing.T) []byte {
				return testIPv4UDPPacket("35.217.47.13", 50005, []byte("opaque encrypted game traffic"))
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory, err := NewFakeIPDirectory(plan)
			if err != nil {
				t.Fatal(err)
			}
			tcpRedirector, err := NewTCPPacketRedirector(NewTCPRedirectRegistry(), 34010)
			if err != nil {
				t.Fatal(err)
			}
			udpRedirector, err := NewUDPPacketRedirector(NewUDPRedirectRegistry(), 34010)
			if err != nil {
				t.Fatal(err)
			}
			resolver := &fixedFlowIdentityResolver{name: test.processName}
			processor, err := NewProcessorWithFullSelectiveRuntime(plan, resolver, tcpRedirector, udpRedirector, directory)
			if err != nil {
				t.Fatal(err)
			}

			original := test.packet(t)
			decision := processor.Process(original)
			if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 {
				t.Fatalf("direct decision = %+v", decision)
			}
			if !bytes.Equal(decision.Packets[0], original) {
				t.Fatal("selective runtime changed a direct Steam/game packet")
			}
			if decision.Reason != "reserved for direct rule latency-sensitive-direct" {
				t.Fatalf("direct reason = %q", decision.Reason)
			}
		})
	}
}

func TestEveryFlowseal1102StrategyKeepsSteamDirect(t *testing.T) {
	original := testIPv4TCPPacketTo(t, "66.22.200.1", "store.steampowered.com")
	resolver := &fixedFlowIdentityResolver{name: `C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe`}
	for _, strategy := range BuiltinStrategies() {
		serviceID := ""
		domain := ""
		switch {
		case len(strategy.ID) > len("native-flowseal-1102-youtube-") && strategy.ID[:len("native-flowseal-1102-youtube-")] == "native-flowseal-1102-youtube-":
			serviceID, domain = "youtube", "youtube.com"
		case len(strategy.ID) > len("native-discord-flowseal-1102-") && strategy.ID[:len("native-discord-flowseal-1102-")] == "native-discord-flowseal-1102-":
			serviceID, domain = "discord", "discord.com"
		default:
			continue
		}
		t.Run(strategy.ID, func(t *testing.T) {
			plan := TrafficPlan{
				Revision: 1, CatalogRevision: BuiltinCatalogRevision,
				Strategies: []TrafficStrategy{strategy},
				Services: []ServiceRule{{
					ID: serviceID, DisplayName: serviceID, DomainSuffixes: []string{domain}, TCPPorts: []int{443},
					Fingerprints: []string{"tls-client-hello"}, CandidateStrategyIDs: []string{strategy.ID},
				}},
				Selections: []ServiceSelection{{ServiceID: serviceID, StrategyID: strategy.ID}},
				Routes:     []ServiceRoute{{ServiceID: serviceID, Kind: ServiceRouteZapret}},
				DirectRules: []DirectRule{{
					ID: "steam-direct", ProcessNames: []string{"steam.exe", "steamwebhelper.exe"},
				}},
			}
			processor, err := NewProcessorWithIdentityResolver(plan, resolver)
			if err != nil {
				t.Fatal(err)
			}
			decision := processor.Process(original)
			if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 || !bytes.Equal(decision.Packets[0], original) {
				t.Fatalf("strategy changed direct Steam traffic: %+v", decision)
			}
			if decision.Reason != "reserved for direct rule steam-direct" {
				t.Fatalf("direct reason = %q", decision.Reason)
			}
		})
	}
}

func TestDiscordProcessTLSDiscoveryTransformsOnlyDiscordOnAlternativePort(t *testing.T) {
	strategy := builtinStrategyByID(t, "native-discord-flowseal-1102-alt")
	plan := TrafficPlan{
		Revision: 1, CatalogRevision: BuiltinCatalogRevision,
		Strategies: []TrafficStrategy{strategy},
		Services: []ServiceRule{{
			ID: "discord", DisplayName: "Discord", DomainSuffixes: []string{"discord.media"},
			ProcessNames: []string{"Discord.exe"}, ProcessMatchPolicy: ProcessMatchIdentity,
			TCPPorts: []int{443, 2087}, ProcessDiscoveryTCPPorts: []int{2087},
			CandidateStrategyIDs: []string{strategy.ID}, AllowDirectFallback: true,
		}},
		Selections: []ServiceSelection{{ServiceID: "discord", StrategyID: strategy.ID}},
		Routes:     []ServiceRoute{{ServiceID: "discord", Kind: ServiceRouteZapret}},
	}
	original := testIPv4TCPPacketTo(t, "162.159.128.235", "shared.cloudflare.example")
	binary.BigEndian.PutUint16(original[22:24], 2087)
	calculateChecksums(original)

	gameProcessor, err := NewProcessorWithIdentityResolver(plan, &fixedFlowIdentityResolver{name: `E:\Games\OtherGame.exe`})
	if err != nil {
		t.Fatal(err)
	}
	gameDecision := gameProcessor.Process(original)
	if gameDecision.Dropped || gameDecision.Transformed || len(gameDecision.Packets) != 1 || !bytes.Equal(gameDecision.Packets[0], original) {
		t.Fatalf("unrelated process on Discord discovery port changed: %+v", gameDecision)
	}

	discordProcessor, err := NewProcessorWithIdentityResolver(plan, &fixedFlowIdentityResolver{name: `C:\Users\u\AppData\Local\Discord\Discord.exe`})
	if err != nil {
		t.Fatal(err)
	}
	discordDecision := discordProcessor.Process(original)
	if discordDecision.Dropped || !discordDecision.Transformed || discordDecision.ServiceID != "discord" || discordDecision.Route != ServiceRouteZapret {
		t.Fatalf("Discord TLS on 2087 was not transformed: %+v", discordDecision)
	}
}

func TestSelectiveRuntimePassesUnselectedDNSByteForByte(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithFullSelectiveRuntime(plan, nil, nil, nil, directory)
	if err != nil {
		t.Fatal(err)
	}

	for _, host := range []string{"store.steampowered.com", "api.mistfallhunter.example", "unrelated.example"} {
		original := testDNSQueryPacket(t, host, dnsTypeA)
		decision := processor.Process(original)
		if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 {
			t.Fatalf("DNS %q decision = %+v", host, decision)
		}
		if !bytes.Equal(decision.Packets[0], original) {
			t.Fatalf("unselected DNS query %q was changed", host)
		}
	}
}

func TestSelectiveRuntimeLeavesEncryptedDNSByteForByteDirect(t *testing.T) {
	plan := fakeIPTestPlan()
	directory, err := NewFakeIPDirectory(plan)
	if err != nil {
		t.Fatal(err)
	}
	processor, err := NewProcessorWithFullSelectiveRuntime(plan, nil, nil, nil, directory)
	if err != nil {
		t.Fatal(err)
	}
	packets := [][]byte{
		testIPv4TCPPacketTo(t, "8.8.8.8", "dns.google"),
		testIPv4UDPPacket("1.1.1.1", 853, []byte{0xc0, 0, 0, 0, 1, 7, 9, 11}),
	}
	for _, original := range packets {
		decision := processor.Process(original)
		if decision.Dropped || decision.Transformed || len(decision.Packets) != 1 || !bytes.Equal(decision.Packets[0], original) {
			t.Fatalf("encrypted DNS direct decision = %+v", decision)
		}
	}
}
