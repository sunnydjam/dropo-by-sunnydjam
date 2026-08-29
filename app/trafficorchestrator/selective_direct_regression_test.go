package trafficorchestrator

import (
	"bytes"
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
