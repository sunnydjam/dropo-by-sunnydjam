package trafficorchestrator

// BuiltinCatalogRevision changes whenever packet semantics or ordering changes.
const BuiltinCatalogRevision = "dropo-native-windows-7-flowseal-1.10.2-alt-exact"

// BuiltinStrategies returns the bounded strategy ladder implemented by the
// Dropo packet engine. It contains data only: no shell arguments, Lua or
// external payload files are accepted by the runtime.
func BuiltinStrategies() []TrafficStrategy {
	common := StrategyConstraints{
		Networks: []Network{NetworkTCP, NetworkUDP},
		Payloads: []string{
			"http-request", "tls-client-hello", "quic-initial", "stun",
			"discord-media", "wireguard-initiation", "wireguard-cookie",
		},
		IPv4:        true,
		IPv6:        true,
		MaxFlowData: 64 * 1024,
	}
	udpDecoy := []PacketAction{{Kind: ActionFake, Payload: "original", Repeats: 2, InvalidSum: true}}
	sniMiddle := PacketPosition{Anchor: "tls-sni-middle"}
	firstByte := PacketPosition{Absolute: 1}
	strategies := []TrafficStrategy{
		{
			ID: "native-zapret2-fake-multidisorder", Revision: 1, Label: "TLS fake and SNI multidisorder",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, Repeats: 11, InvalidSum: true},
				{Kind: ActionDisorder, Positions: []PacketPosition{firstByte, sniMiddle}},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_decoy", Repeats: 11}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 14, BufferedBytes: 681, Risk: 26},
		},
		{
			ID: "native-zapret2-fake-sni-split", Revision: 1, Label: "TLS fake and SNI split",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, SequenceDelta: -10000, Repeats: 6},
				{Kind: ActionSplit, Positions: []PacketPosition{sniMiddle}},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_decoy", Repeats: 5}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 8, BufferedBytes: 681, Risk: 18},
		},
		{
			ID: "native-zapret2-sni-disorder", Revision: 1, Label: "SNI multidisorder",
			TCP:         []PacketAction{{Kind: ActionDisorder, Positions: []PacketPosition{firstByte, sniMiddle}}},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_decoy", Repeats: 10}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 13, BufferedBytes: 681, Risk: 20},
		},
		{
			ID: "native-zapret2-overlap-sni", Revision: 1, Label: "Sequence overlap and SNI split",
			TCP: []PacketAction{
				{Kind: ActionSequenceOverlap, Overlap: 8},
				{Kind: ActionSplit, Positions: []PacketPosition{firstByte, sniMiddle}},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_decoy", Repeats: 5}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 9, BufferedBytes: 689, Risk: 23},
		},
		{
			ID: "native-split-1", Revision: 1, Label: "Segment at byte 1",
			TCP: []PacketAction{{Kind: ActionSplit, Position: 1}}, UDP: udpDecoy,
			Constraints: common, Cost: StrategyCost{SyntheticPackets: 2, BufferedBytes: 1, Risk: 5},
		},
		{
			ID: "native-split-2", Revision: 1, Label: "Segment at byte 2",
			TCP: []PacketAction{{Kind: ActionSplit, Position: 2}}, UDP: udpDecoy,
			Constraints: common, Cost: StrategyCost{SyntheticPackets: 2, BufferedBytes: 2, Risk: 8},
		},
		{
			ID: "native-overlap-split", Revision: 1, Label: "Sequence overlap and segment",
			TCP: []PacketAction{
				{Kind: ActionSequenceOverlap, Overlap: 8},
				{Kind: ActionSplit, Position: 2},
			},
			UDP: udpDecoy, Constraints: common,
			Cost: StrategyCost{SyntheticPackets: 3, BufferedBytes: 10, Risk: 18},
		},
		{
			ID: "native-disorder-2", Revision: 1, Label: "Out-of-order segments",
			TCP: []PacketAction{{Kind: ActionDisorder, Position: 2}}, UDP: udpDecoy,
			Constraints: common, Cost: StrategyCost{SyntheticPackets: 2, BufferedBytes: 2, Risk: 24},
		},
		{
			ID: "native-decoy-split", Revision: 1, Label: "Invalid-checksum decoy and segment",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", SequenceDelta: -10000, Repeats: 4, InvalidSum: true},
				{Kind: ActionSplit, Position: 2},
			},
			UDP: udpDecoy, Constraints: common,
			Cost: StrategyCost{SyntheticPackets: 6, BufferedBytes: 1024, Risk: 30},
		},
		{
			ID: "native-low-ttl-decoy", Revision: 1, Label: "Low-TTL decoy and segment",
			TCP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "tls_client_hello", SequenceDelta: -10000, Repeats: 4},
				{Kind: ActionSplit, Position: 2},
			},
			UDP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "original", Repeats: 2},
			},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 6, BufferedBytes: 1024, Risk: 42},
		},
	}
	// Discord's active discovery/STUN candidates deliberately differ on UDP.
	// The old catalog attached the same UDP action to every TCP strategy, so a
	// "next strategy" was often a no-op for voice. Protocol decoys are generated
	// in-process from the observed handshake and remain bounded to three packets.
	strategies = append(strategies,
		TrafficStrategy{
			ID: "native-discord-active-v2", Revision: 1, Label: "Discord active QUIC and SNI decoys",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, SequenceDelta: -10000, Repeats: 8},
				{Kind: ActionDisorder, Positions: []PacketPosition{firstByte, sniMiddle}},
			},
			UDP: []PacketAction{
				{Kind: ActionFake, Payload: "quic_decoy", Repeats: 3},
				{Kind: ActionFake, Payload: "protocol_decoy", Repeats: 3},
			},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 17, BufferedBytes: 1881, Risk: 18},
		},
		TrafficStrategy{
			ID: "native-discord-zero-v2", Revision: 1, Label: "Discord zero and TLS decoys",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, SequenceDelta: -10000, Repeats: 6},
				{Kind: ActionSplit, Positions: []PacketPosition{sniMiddle}},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "zero", PadTo: 32, Repeats: 2}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 10, BufferedBytes: 713, Risk: 20},
		},
		TrafficStrategy{
			ID: "native-discord-invalidsum-v2", Revision: 1, Label: "Discord invalid-checksum QUIC decoys",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, SequenceDelta: -10000, Repeats: 6, InvalidSum: true},
				{Kind: ActionSplit, Positions: []PacketPosition{sniMiddle}},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_decoy", Repeats: 4, InvalidSum: true}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 12, BufferedBytes: 1881, Risk: 25},
		},
		TrafficStrategy{
			ID: "native-discord-low-ttl-v2", Revision: 1, Label: "Discord low-TTL QUIC decoys",
			TCP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, SequenceDelta: -10000, Repeats: 4},
				{Kind: ActionSplit, Positions: []PacketPosition{sniMiddle}},
			},
			UDP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "quic_decoy", Repeats: 3},
			},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 9, BufferedBytes: 1881, Risk: 34},
		},
		TrafficStrategy{
			ID: "native-discord-active", Revision: 1, Label: "Discord active protocol decoys",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", SequenceDelta: -10000, Repeats: 4, InvalidSum: true},
				{Kind: ActionSplit, Position: 2},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "protocol_decoy", Repeats: 3}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 7, BufferedBytes: 1024, Risk: 16},
		},
		TrafficStrategy{
			ID: "native-discord-invalidsum", Revision: 1, Label: "Discord invalid-checksum protocol decoys",
			TCP: []PacketAction{
				{Kind: ActionFake, Payload: "tls_client_hello", SequenceDelta: -10000, Repeats: 4, InvalidSum: true},
				{Kind: ActionSplit, Position: 2},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "protocol_decoy", Repeats: 3, InvalidSum: true}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 7, BufferedBytes: 1024, Risk: 24},
		},
		TrafficStrategy{
			ID: "native-discord-low-ttl", Revision: 1, Label: "Discord low-TTL protocol decoys",
			TCP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "tls_client_hello", SequenceDelta: -10000, Repeats: 4},
				{Kind: ActionSplit, Position: 2},
			},
			UDP: []PacketAction{
				{Kind: ActionTTL, TTL: 3},
				{Kind: ActionFake, Payload: "protocol_decoy", Repeats: 3},
			},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 7, BufferedBytes: 1024, Risk: 36},
		},
	)
	// Flowseal exposes each general*.bat file as a user-selectable profile.
	// Keep those profiles distinct even when their typed in-process adaptation
	// is similar: their fake counts, overlap, ordering and Discord UDP decoys can
	// differ, and the UI must be able to test the complete upstream list.
	strategies = append(flowseal1102BuiltinStrategies(common), strategies...)
	return strategies
}

type flowseal1102Recipe struct {
	kind          string
	repeats       int
	overlap       int
	sequenceDelta int
	position      int
	sniEnd        bool
}

type flowseal1102Preset struct {
	slug, label            string
	youtube, discord       flowseal1102Recipe
	youtubeUDP, discordUDP int
}

func flowseal1102BuiltinStrategies(common StrategyConstraints) []TrafficStrategy {
	// Ordered with ALT13 first because it is the newest upstream preset, then
	// the remaining 1.10.2 files in their familiar launcher order.
	presets := []flowseal1102Preset{
		{"alt13", "ALT13", flowseal1102Recipe{kind: "hostsplit"}, flowseal1102Recipe{kind: "fake-overlap", repeats: 7, overlap: 681, position: 1}, 11, 5},
		{"general", "General", flowseal1102Recipe{kind: "overlap", overlap: 681, position: 1}, flowseal1102Recipe{kind: "overlap", overlap: 681, position: 1}, 6, 6},
		{"alt", "ALT", flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: -10000, position: 2}, flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: -10000, position: 2}, 6, 6},
		{"alt2", "ALT2", flowseal1102Recipe{kind: "overlap", overlap: 652, position: 2}, flowseal1102Recipe{kind: "overlap", overlap: 652, position: 2}, 6, 6},
		{"alt3", "ALT3", flowseal1102Recipe{kind: "fake-disorder", repeats: 6}, flowseal1102Recipe{kind: "fake-disorder", repeats: 6}, 6, 6},
		{"alt4", "ALT4", flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: 1000, position: 2}, flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: 1000, position: 2}, 6, 6},
		{"alt5", "ALT5", flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: 1000, position: 2}, flowseal1102Recipe{kind: "fake-split", repeats: 6, sequenceDelta: 1000, position: 2}, 6, 6},
		{"alt6", "ALT6", flowseal1102Recipe{kind: "overlap", overlap: 681, position: 1}, flowseal1102Recipe{kind: "overlap", overlap: 681, position: 1}, 6, 6},
		{"alt7", "ALT7", flowseal1102Recipe{kind: "overlap", overlap: 679, position: 2, sniEnd: true}, flowseal1102Recipe{kind: "overlap", overlap: 679, position: 2, sniEnd: true}, 6, 6},
		{"alt8", "ALT8", flowseal1102Recipe{kind: "fake", repeats: 6, sequenceDelta: 2}, flowseal1102Recipe{kind: "fake", repeats: 6, sequenceDelta: 2}, 6, 6},
		{"alt9", "ALT9", flowseal1102Recipe{kind: "hostsplit", repeats: 4}, flowseal1102Recipe{kind: "hostsplit", repeats: 4}, 6, 6},
		{"alt10", "ALT10", flowseal1102Recipe{kind: "fake", repeats: 6}, flowseal1102Recipe{kind: "fake", repeats: 6}, 6, 6},
		{"alt11", "ALT11", flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, 11, 6},
		{"alt12", "ALT12", flowseal1102Recipe{kind: "hostsplit"}, flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, 11, 3},
		{"exp", "EXP", flowseal1102Recipe{kind: "hostsplit"}, flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, 11, 4},
		{"fake-tls-auto", "FAKE TLS AUTO", flowseal1102Recipe{kind: "fake-disorder", repeats: 11, sequenceDelta: -10000}, flowseal1102Recipe{kind: "fake-disorder", repeats: 11, sequenceDelta: -10000}, 11, 6},
		{"fake-tls-auto-alt", "FAKE TLS AUTO ALT", flowseal1102Recipe{kind: "fake-split", repeats: 8, sequenceDelta: 2, position: 1}, flowseal1102Recipe{kind: "fake-split", repeats: 8, sequenceDelta: 2, position: 1}, 11, 6},
		{"fake-tls-auto-alt2", "FAKE TLS AUTO ALT2", flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, sequenceDelta: -65535, position: 1}, flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, sequenceDelta: -65535, position: 1}, 11, 6},
		{"fake-tls-auto-alt3", "FAKE TLS AUTO ALT3", flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, flowseal1102Recipe{kind: "fake-overlap", repeats: 8, overlap: 681, position: 1}, 11, 6},
		{"simple-fake", "SIMPLE FAKE", flowseal1102Recipe{kind: "hostsplit"}, flowseal1102Recipe{kind: "fake", repeats: 6}, 6, 6},
		{"simple-fake-alt", "SIMPLE FAKE ALT", flowseal1102Recipe{kind: "fake", repeats: 6, sequenceDelta: 2}, flowseal1102Recipe{kind: "fake", repeats: 6, sequenceDelta: 2}, 6, 6},
		{"simple-fake-alt2", "SIMPLE FAKE ALT2", flowseal1102Recipe{kind: "fake", repeats: 6}, flowseal1102Recipe{kind: "fake", repeats: 6}, 6, 6},
	}
	result := make([]TrafficStrategy, 0, len(presets)*2)
	for _, preset := range presets {
		if preset.slug == "alt" {
			result = append(result, flowseal1102GeneralALTStrategies(common)...)
			continue
		}
		result = append(result,
			flowseal1102Strategy("native-flowseal-1102-youtube-"+preset.slug, "Flowseal 1.10.2 "+preset.label+" — YouTube", preset.youtube, "quic_decoy", preset.youtubeUDP, common),
			flowseal1102Strategy("native-discord-flowseal-1102-"+preset.slug, "Flowseal 1.10.2 "+preset.label+" — Discord", preset.discord, "protocol_decoy", preset.discordUDP, common),
		)
	}
	return result
}

func flowseal1102GeneralALTStrategies(common StrategyConstraints) []TrafficStrategy {
	const timestampDelta = -600000
	youtubeMetadata := PacketAction{
		TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta, IPv4ID: IPv4IDZero,
	}
	discordMetadata := PacketAction{
		TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta,
	}
	return []TrafficStrategy{
		{
			ID: "native-flowseal-1102-youtube-alt", Revision: 3,
			Label: "Flowseal 1.10.2 ALT exact — YouTube",
			TCP: []PacketAction{
				{
					Kind: ActionFake, Payload: "tls_google", PadTo: 681, Repeats: 6, Ports: []int{443},
					TCPFooling: youtubeMetadata.TCPFooling, TimestampDelta: youtubeMetadata.TimestampDelta, IPv4ID: youtubeMetadata.IPv4ID,
				},
				{
					Kind: ActionFakeDataSplit, Position: 2, Repeats: 6, FakePattern: FakePatternZero, Ports: []int{443},
					TCPFooling: youtubeMetadata.TCPFooling, TimestampDelta: youtubeMetadata.TimestampDelta, IPv4ID: youtubeMetadata.IPv4ID,
				},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_google", PadTo: 1200, Repeats: 6, Ports: []int{443}}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 30, BufferedBytes: 1881, Risk: 18},
		},
		{
			ID: "native-discord-flowseal-1102-alt", Revision: 3,
			Label: "Flowseal 1.10.2 ALT exact — Discord",
			TCP: []PacketAction{
				{
					Kind: ActionFake, Payload: "stun_decoy", PadTo: 100, Repeats: 6, Ports: []int{443},
					TCPFooling: discordMetadata.TCPFooling, TimestampDelta: discordMetadata.TimestampDelta,
				},
				{
					Kind: ActionFake, Payload: "tls_google", PadTo: 681, Repeats: 6,
					TCPFooling: discordMetadata.TCPFooling, TimestampDelta: discordMetadata.TimestampDelta,
				},
				{
					Kind: ActionFakeDataSplit, Position: 2, Repeats: 6, FakePattern: FakePatternZero,
					TCPFooling: discordMetadata.TCPFooling, TimestampDelta: discordMetadata.TimestampDelta,
				},
			},
			UDP: []PacketAction{
				{Kind: ActionFake, Payload: "quic_google", PadTo: 1200, Repeats: 6, Ports: []int{443}},
				{
					Kind: ActionFake, Payload: "discord_active", PadTo: 1200, Repeats: 6,
					PortRanges: []PortRange{{First: 19294, Last: 19344}, {First: 50000, Last: 50100}},
				},
			},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 36, BufferedBytes: 1881, Risk: 20},
		},
	}
}

func flowseal1102Strategy(id, label string, recipe flowseal1102Recipe, udpPayload string, udpRepeats int, common StrategyConstraints) TrafficStrategy {
	firstByte := PacketPosition{Absolute: 1}
	sniMiddle := PacketPosition{Anchor: "tls-sni-middle"}
	positions := []PacketPosition{}
	if recipe.position > 0 {
		positions = append(positions, PacketPosition{Absolute: recipe.position})
	}
	if recipe.sniEnd {
		positions = append(positions, PacketPosition{Anchor: "tls-sni-end", Offset: 1})
	} else if recipe.kind == "hostsplit" || recipe.kind == "fake-disorder" {
		positions = append(positions, sniMiddle)
	}
	if len(positions) == 0 {
		positions = append(positions, firstByte, sniMiddle)
	}
	fake := PacketAction{Kind: ActionFake, Payload: "tls_client_hello", PadTo: 681, Repeats: max(1, recipe.repeats), SequenceDelta: recipe.sequenceDelta}
	tcp := []PacketAction{}
	switch recipe.kind {
	case "fake":
		tcp = append(tcp, fake)
	case "fake-split":
		tcp = append(tcp, fake, PacketAction{Kind: ActionSplit, Positions: positions})
	case "fake-overlap":
		tcp = append(tcp, fake, PacketAction{Kind: ActionSequenceOverlap, Overlap: recipe.overlap}, PacketAction{Kind: ActionSplit, Positions: positions})
	case "fake-disorder":
		tcp = append(tcp, fake, PacketAction{Kind: ActionDisorder, Positions: positions})
	case "overlap":
		tcp = append(tcp, PacketAction{Kind: ActionSequenceOverlap, Overlap: recipe.overlap}, PacketAction{Kind: ActionSplit, Positions: positions})
	default: // hostfakesplit is represented by a service-scoped SNI split.
		if recipe.repeats > 0 {
			tcp = append(tcp, fake)
		}
		tcp = append(tcp, PacketAction{Kind: ActionSplit, Positions: positions})
	}
	return TrafficStrategy{
		ID: id, Revision: 1, Label: label, TCP: tcp,
		UDP:         []PacketAction{{Kind: ActionFake, Payload: udpPayload, Repeats: max(1, udpRepeats)}},
		Constraints: common,
		Cost:        StrategyCost{SyntheticPackets: max(1, recipe.repeats) + max(1, udpRepeats) + len(tcp), BufferedBytes: 681, Risk: 20},
	}
}
