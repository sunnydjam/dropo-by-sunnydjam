package trafficorchestrator

// This file is a typed, service-scoped transcription of the YouTube/Google and
// Discord rules in Flowseal zapret-discord-youtube 1.10.2 general*.bat. Global
// IP sets, game filters and any-protocol catch-alls are intentionally omitted:
// Dropo applies these actions only after positive service classification.

const flowseal1102TimestampDelta = -600000

var (
	flowsealTLSFingerprint   = []string{"tls-client-hello"}
	flowsealHTTPFingerprint  = []string{"http-request"}
	flowsealQUICFingerprint  = []string{"quic-initial"}
	flowsealMediaFingerprint = []string{"discord-media", "stun"}
	flowsealYouTubePorts     = []int{443}
	flowsealDiscordWebPorts  = []int{80, 443}
	flowsealDiscordMediaTCP  = []int{2053, 2083, 2087, 2096, 8443}
	flowsealDiscordMediaUDP  = []PortRange{{First: 19294, Last: 19344}, {First: 50000, Last: 50100}}
)

type flowseal1102TCPRecipe struct {
	ports          []int
	payloads       []string
	fakePayloads   []string
	fakeRepeats    int
	sequenceDelta  int
	timestamp      bool
	ipv4IDZero     bool
	invalidSum     bool
	mode           PacketActionKind
	positions      []PacketPosition
	overlap        int
	overlapPayload string
	hostTemplate   string
	hostRepeats    int
	alternateOrder bool
}

type flowseal1102UDPRecipe struct {
	ports      []int
	portRanges []PortRange
	payloads   []string
	payload    string
	repeats    int
	padTo      int
}

type flowseal1102Profile struct {
	slug, label string
	youtubeTCP  []flowseal1102TCPRecipe
	discordTCP  []flowseal1102TCPRecipe
	quicRepeats int
	discordUDP  []flowseal1102UDPRecipe
	dataPhase   bool
}

func flowseal1102BuiltinStrategies(common StrategyConstraints) []TrafficStrategy {
	profiles := flowseal1102Profiles()
	result := make([]TrafficStrategy, 0, len(profiles)*2)
	for _, profile := range profiles {
		// General ALT was already validated live for YouTube, Discord desktop,
		// Discord voice and Steam isolation before the complete 1.10.2 catalog
		// was transcribed. Preserve that proven service-scoped recipe exactly;
		// the more granular upstream transcription caused a live regression.
		if profile.slug == "alt" {
			result = append(result, flowseal1102ProvenALTStrategies(common)...)
			continue
		}
		youtubeLabel := "Flowseal 1.10.2 " + profile.label + " adapted — YouTube"
		discordLabel := "Flowseal 1.10.2 " + profile.label + " adapted — Discord"
		if profile.dataPhase {
			youtubeLabel = "Flowseal 1.10.2 ALT5 scoped data phase — YouTube"
			discordLabel = "Flowseal 1.10.2 ALT5 scoped data phase — Discord"
		}
		result = append(result,
			flowseal1102BuildStrategy("native-flowseal-1102-youtube-"+profile.slug, youtubeLabel, profile.youtubeTCP, []flowseal1102UDPRecipe{flowsealQUICRecipe(profile.quicRepeats)}, common, profile.dataPhase),
			flowseal1102BuildStrategy("native-discord-flowseal-1102-"+profile.slug, discordLabel, profile.discordTCP, append([]flowseal1102UDPRecipe{flowsealQUICRecipe(profile.quicRepeats)}, profile.discordUDP...), common, profile.dataPhase),
		)
	}
	return result
}

// flowseal1102ProvenALTStrategies is the bounded in-process General ALT
// adaptation that passed the project's live release gate. It deliberately has
// no payload fingerprint on the TCP actions: service classification already
// supplies the required domain/process context, while Discord's desktop and
// gateway connections must also be covered after their ClientHello packet.
func flowseal1102ProvenALTStrategies(common StrategyConstraints) []TrafficStrategy {
	const timestampDelta = -600000
	return []TrafficStrategy{
		{
			ID: "native-flowseal-1102-youtube-alt", Revision: 5,
			Label: "Flowseal 1.10.2 ALT proven — YouTube",
			TCP: []PacketAction{
				{
					Kind: ActionFake, Payload: "tls_google", PadTo: 681, Repeats: 6, Ports: []int{443},
					TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta, IPv4ID: IPv4IDZero,
				},
				{
					Kind: ActionFakeDataSplit, Position: 1, Repeats: 6, FakePattern: FakePatternZero, Ports: []int{443},
					TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta, IPv4ID: IPv4IDZero,
				},
			},
			UDP:         []PacketAction{{Kind: ActionFake, Payload: "quic_google", PadTo: 1200, Repeats: 6, Ports: []int{443}}},
			Constraints: common,
			Cost:        StrategyCost{SyntheticPackets: 30, BufferedBytes: 1881, Risk: 18},
		},
		{
			ID: "native-discord-flowseal-1102-alt", Revision: 5,
			Label: "Flowseal 1.10.2 ALT proven — Discord",
			TCP: []PacketAction{
				{
					Kind: ActionFake, Payload: "stun_decoy", PadTo: 100, Repeats: 6, Ports: []int{443},
					TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta,
				},
				{
					Kind: ActionFake, Payload: "tls_google", PadTo: 681, Repeats: 6,
					TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta,
				},
				{
					Kind: ActionFakeDataSplit, Position: 1, Repeats: 6, FakePattern: FakePatternZero,
					TCPFooling: TCPFoolingTimestampOrBadSum, TimestampDelta: timestampDelta,
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

func flowseal1102BuildStrategy(id, label string, tcpRecipes []flowseal1102TCPRecipe, udpRecipes []flowseal1102UDPRecipe, common StrategyConstraints, dataPhase bool) TrafficStrategy {
	tcp := make([]PacketAction, 0, len(tcpRecipes)*3)
	maxTCPPackets := 1
	for _, recipe := range tcpRecipes {
		tcp = append(tcp, flowseal1102TCPActions(recipe)...)
		maxTCPPackets = max(maxTCPPackets, flowseal1102RecipePacketCount(recipe))
	}
	udp := make([]PacketAction, 0, len(udpRecipes))
	maxUDPPackets := 1
	for _, recipe := range udpRecipes {
		if recipe.repeats < 1 {
			continue
		}
		udp = append(udp, PacketAction{
			Kind: ActionFake, Payload: recipe.payload, Repeats: recipe.repeats, PadTo: recipe.padTo,
			Ports: append([]int(nil), recipe.ports...), PortRanges: append([]PortRange(nil), recipe.portRanges...),
			Payloads: append([]string(nil), recipe.payloads...),
		})
		maxUDPPackets = max(maxUDPPackets, recipe.repeats+1)
	}
	risk := 20
	if dataPhase {
		risk = 34
	}
	return TrafficStrategy{
		ID: id, Revision: 5, Label: label, TCP: tcp, UDP: udp, Constraints: common,
		Cost: StrategyCost{SyntheticPackets: max(maxTCPPackets, maxUDPPackets), BufferedBytes: 1881, Risk: risk},
	}
}

func flowseal1102TCPActions(recipe flowseal1102TCPRecipe) []PacketAction {
	result := make([]PacketAction, 0, len(recipe.fakePayloads)+1)
	for _, payload := range recipe.fakePayloads {
		action := PacketAction{
			Kind: ActionFake, Payload: payload, PadTo: flowseal1102PayloadSize(payload), Repeats: max(1, recipe.fakeRepeats),
			SequenceDelta: recipe.sequenceDelta, IPv4ID: flowseal1102IPv4ID(recipe.ipv4IDZero), InvalidSum: recipe.invalidSum,
			Ports: append([]int(nil), recipe.ports...), Payloads: append([]string(nil), recipe.payloads...),
		}
		flowseal1102ApplyTimestamp(&action, recipe.timestamp)
		result = append(result, action)
	}
	if recipe.mode == "" {
		return result
	}
	action := PacketAction{
		Kind: recipe.mode, Positions: append([]PacketPosition(nil), recipe.positions...),
		Overlap: recipe.overlap, Payload: recipe.overlapPayload, IPv4ID: flowseal1102IPv4ID(recipe.ipv4IDZero),
		Ports: append([]int(nil), recipe.ports...), Payloads: append([]string(nil), recipe.payloads...),
	}
	if len(action.Positions) == 1 && action.Positions[0].Absolute > 0 {
		action.Position = action.Positions[0].Absolute
		action.Positions = nil
	}
	switch recipe.mode {
	case ActionFakeDataSplit:
		action.Repeats = max(1, recipe.fakeRepeats)
		action.FakePattern = FakePatternZero
		action.SequenceDelta = recipe.sequenceDelta
		action.InvalidSum = recipe.invalidSum
		flowseal1102ApplyTimestamp(&action, recipe.timestamp)
	case ActionHostFakeSplit:
		action.Repeats = max(1, recipe.hostRepeats)
		action.HostTemplate = recipe.hostTemplate
		action.AlternateOrder = recipe.alternateOrder
		action.SequenceDelta = recipe.sequenceDelta
		action.InvalidSum = recipe.invalidSum
		flowseal1102ApplyTimestamp(&action, recipe.timestamp)
	}
	result = append(result, action)
	return result
}

func flowseal1102ApplyTimestamp(action *PacketAction, enabled bool) {
	if enabled {
		action.TCPFooling = TCPFoolingTimestampOrBadSum
		action.TimestampDelta = flowseal1102TimestampDelta
	}
}

func flowseal1102IPv4ID(enabled bool) IPv4IDMode {
	if enabled {
		return IPv4IDZero
	}
	return ""
}

func flowseal1102PayloadSize(payload string) int {
	switch payload {
	case "tls_google":
		return 681
	case "tls_4pda":
		return 284
	case "tls_max":
		return 664
	case "tls_sochi":
		return 244
	case "stun_decoy":
		return 100
	case "stun2_decoy":
		return 120
	case "quic_google", "discord_active":
		return 1200
	case "zero":
		return 4
	default:
		return 0
	}
}

func flowseal1102RecipePacketCount(recipe flowseal1102TCPRecipe) int {
	count := len(recipe.fakePayloads)*max(1, recipe.fakeRepeats) + 1
	switch recipe.mode {
	case ActionFakeDataSplit:
		count += max(1, recipe.fakeRepeats)*4 + 1
	case ActionHostFakeSplit:
		if recipe.alternateOrder {
			count += max(1, recipe.hostRepeats) + 2
		} else {
			count += max(1, recipe.hostRepeats)*2 + 2
		}
	case ActionSplit, ActionDisorder:
		count += len(recipe.positions)
	}
	return count
}

func flowsealQUICRecipe(repeats int) flowseal1102UDPRecipe {
	return flowseal1102UDPRecipe{ports: []int{443}, payloads: flowsealQUICFingerprint, payload: "quic_google", repeats: repeats, padTo: 1200}
}

func flowsealDiscordActive(repeats int) []flowseal1102UDPRecipe {
	return []flowseal1102UDPRecipe{{portRanges: flowsealDiscordMediaUDP, payloads: flowsealMediaFingerprint, payload: "discord_active", repeats: repeats, padTo: 1200}}
}

func flowsealRule(ports []int, payloads []string, mode PacketActionKind, positions []PacketPosition, overlap int, overlapPayload string) flowseal1102TCPRecipe {
	return flowseal1102TCPRecipe{ports: ports, payloads: payloads, mode: mode, positions: positions, overlap: overlap, overlapPayload: overlapPayload}
}

func flowsealFakeRule(ports []int, payloads, fakes []string, repeats, sequenceDelta int, timestamp bool) flowseal1102TCPRecipe {
	return flowseal1102TCPRecipe{ports: ports, payloads: payloads, fakePayloads: fakes, fakeRepeats: repeats, sequenceDelta: sequenceDelta, timestamp: timestamp}
}

func flowsealFakeModeRule(ports []int, payloads, fakes []string, repeats, sequenceDelta int, timestamp bool, mode PacketActionKind, positions []PacketPosition, overlap int, overlapPayload string) flowseal1102TCPRecipe {
	recipe := flowsealFakeRule(ports, payloads, fakes, repeats, sequenceDelta, timestamp)
	recipe.mode, recipe.positions, recipe.overlap, recipe.overlapPayload = mode, positions, overlap, overlapPayload
	return recipe
}

func flowsealHostRule(ports []int, payloads []string, template string, repeats int, alternate, timestamp bool) flowseal1102TCPRecipe {
	return flowseal1102TCPRecipe{ports: ports, payloads: payloads, mode: ActionHostFakeSplit, hostTemplate: template, hostRepeats: repeats, alternateOrder: alternate, timestamp: timestamp}
}

func flowsealFakeHostRule(ports []int, payloads, fakes []string, repeats int, template string, alternate, timestamp bool) flowseal1102TCPRecipe {
	recipe := flowsealFakeRule(ports, payloads, fakes, repeats, 0, timestamp)
	recipe.mode, recipe.hostTemplate, recipe.hostRepeats, recipe.alternateOrder = ActionHostFakeSplit, template, repeats, alternate
	return recipe
}

func flowsealWithIPv4ID(recipe flowseal1102TCPRecipe) flowseal1102TCPRecipe {
	recipe.ipv4IDZero = true
	return recipe
}

func flowsealWithInvalidSum(recipe flowseal1102TCPRecipe) flowseal1102TCPRecipe {
	recipe.invalidSum = true
	return recipe
}

func flowseal1102Profiles() []flowseal1102Profile {
	abs1 := []PacketPosition{{Absolute: 1}}
	abs2 := []PacketPosition{{Absolute: 2}}
	firstAndMidSLD := []PacketPosition{{Absolute: 1}, {Anchor: "tls-sni-middle-sld"}}
	alt7Positions := []PacketPosition{{Absolute: 2}, {Anchor: "tls-sni-extension-start", Offset: 1}}

	generalY := flowsealWithIPv4ID(flowsealRule(flowsealYouTubePorts, flowsealTLSFingerprint, ActionSplit, abs1, 681, "tls_google"))
	generalMedia := flowsealRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, ActionSplit, abs1, 681, "tls_google")
	generalWeb := flowsealRule(flowsealDiscordWebPorts, []string{"http-request", "tls-client-hello"}, ActionSplit, abs1, 568, "tls_4pda")

	altY := flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true, ActionFakeDataSplit, abs1, 0, ""))
	altMedia := flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true, ActionFakeDataSplit, abs1, 0, "")
	altWebTLS := flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun_decoy", "tls_google"}, 6, 0, true, ActionFakeDataSplit, abs1, 0, "")
	altWebHTTP := flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 0, true, ActionFakeDataSplit, abs1, 0, "")

	profiles := []flowseal1102Profile{
		{
			slug: "alt13", label: "ALT13", quicRepeats: 11, discordUDP: flowsealDiscordActive(5),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, "www.google.com", 1, false, true)},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 7, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeHostRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_sochi", "stun2_decoy"}, 5, "mail.ru", true, true),
				flowsealFakeHostRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_sochi"}, 5, "mail.ru", true, true),
			},
		},
		{slug: "general", label: "General", youtubeTCP: []flowseal1102TCPRecipe{generalY}, discordTCP: []flowseal1102TCPRecipe{generalMedia, generalWeb}, quicRepeats: 6, discordUDP: flowsealDiscordActive(6)},
		{slug: "alt", label: "ALT", youtubeTCP: []flowseal1102TCPRecipe{altY}, discordTCP: []flowseal1102TCPRecipe{altMedia, altWebTLS, altWebHTTP}, quicRepeats: 6, discordUDP: flowsealDiscordActive(6)},
		{
			slug: "alt2", label: "ALT2", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealRule(flowsealYouTubePorts, flowsealTLSFingerprint, ActionSplit, abs2, 652, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, ActionSplit, abs2, 652, "tls_google"),
				flowsealRule(flowsealDiscordWebPorts, []string{"http-request", "tls-client-hello"}, ActionSplit, abs2, 652, "tls_google"),
			},
		},
		{
			slug: "alt3", label: "ALT3", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 1, "www.google.com", true, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeHostRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_auto_google"}, 1, "www.google.com", true, true),
				flowsealFakeHostRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_auto_ya"}, 1, "ya.ru", true, true),
				flowsealFakeHostRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 1, "ya.ru", true, true),
			},
		},
		{
			slug: "alt4", label: "ALT4", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 1000, false, ActionSplit, abs2, 0, ""))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 1000, false, ActionSplit, abs2, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun_decoy", "tls_google"}, 6, 1000, false, ActionSplit, abs2, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 1000, false, ActionSplit, abs2, 0, ""),
			},
		},
		{
			slug: "alt5", label: "ALT5", quicRepeats: 6, discordUDP: flowsealDiscordActive(6), dataPhase: true,
			youtubeTCP: []flowseal1102TCPRecipe{flowsealRule(flowsealYouTubePorts, flowsealTLSFingerprint, ActionDisorder, abs2, 0, "")},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, ActionDisorder, abs2, 0, ""),
				flowsealRule(flowsealDiscordWebPorts, []string{"http-request", "tls-client-hello"}, ActionDisorder, abs2, 0, ""),
			},
		},
		{
			slug: "alt6", label: "ALT6", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealRule(flowsealYouTubePorts, flowsealTLSFingerprint, ActionSplit, abs1, 681, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, ActionSplit, abs1, 681, "tls_google"),
				flowsealRule(flowsealDiscordWebPorts, []string{"http-request", "tls-client-hello"}, ActionSplit, abs1, 681, "tls_google"),
			},
		},
		{
			slug: "alt7", label: "ALT7", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealRule(flowsealYouTubePorts, flowsealTLSFingerprint, ActionSplit, alt7Positions, 679, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, ActionSplit, alt7Positions, 679, "tls_google"),
				flowsealRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, ActionSplit, alt7Positions, 679, "tls_google"),
			},
		},
		{
			slug: "alt8", label: "ALT8", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_default"}, 6, 2, false))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_default"}, 6, 2, false),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_default"}, 6, 2, false),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 2, false),
			},
		},
		{
			slug: "alt9", label: "ALT9", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, "www.google.com", 4, false, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealHostRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, "www.google.com", 4, false, true),
				flowsealWithInvalidSum(flowsealHostRule(flowsealDiscordWebPorts, []string{"http-request", "tls-client-hello"}, "ozon.ru", 4, false, true)),
			},
		},
		{
			slug: "alt10", label: "ALT10", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun_decoy", "tls_4pda"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 0, true),
			},
		},
		{
			slug: "alt11", label: "ALT11", quicRepeats: 11, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun2_decoy", "tls_max"}, 8, 0, true, ActionSplit, abs1, 664, "tls_max"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 8, 0, true, ActionSplit, abs1, 664, "tls_max"),
			},
		},
		{
			slug: "alt12", label: "ALT12", quicRepeats: 11,
			discordUDP: []flowseal1102UDPRecipe{
				{portRanges: flowsealDiscordMediaUDP, payloads: []string{"discord-media"}, payload: "stun_decoy", repeats: 3, padTo: 100},
				{portRanges: flowsealDiscordMediaUDP, payloads: flowsealMediaFingerprint, payload: "discord_active", repeats: 3, padTo: 1200},
			},
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, "www.google.com", 1, false, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun_decoy", "tls_max"}, 8, 0, true, ActionSplit, abs1, 664, "tls_max"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 8, 0, true, ActionSplit, abs1, 664, "tls_max"),
			},
		},
		{
			slug: "exp", label: "EXP", quicRepeats: 11,
			discordUDP: []flowseal1102UDPRecipe{
				{portRanges: flowsealDiscordMediaUDP, payloads: []string{"discord-media"}, payload: "quic_google", repeats: 4, padTo: 1200},
				{portRanges: flowsealDiscordMediaUDP, payloads: flowsealMediaFingerprint, payload: "discord_active", repeats: 4, padTo: 1200},
			},
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, "www.google.com", 1, false, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_max"}, 4, 0, true, ActionSplit, abs1, 480, "stun2_decoy"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 4, 0, true, ActionSplit, abs1, 480, "stun2_decoy"),
			},
		},
		{
			slug: "fake-tls-auto", label: "FAKE TLS AUTO", quicRepeats: 11, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"zero", "tls_auto_google"}, 11, -10000, false, ActionDisorder, firstAndMidSLD, 0, ""))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"zero", "tls_auto_google"}, 11, -10000, false, ActionDisorder, firstAndMidSLD, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"zero", "tls_auto_google"}, 11, -10000, false, ActionDisorder, firstAndMidSLD, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 11, -10000, false, ActionSplit, abs2, 0, ""),
			},
		},
		{
			slug: "fake-tls-auto-alt", label: "FAKE TLS AUTO ALT", quicRepeats: 11, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 2, false, ActionFakeDataSplit, abs1, 0, ""))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 2, false, ActionFakeDataSplit, abs1, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 2, false, ActionFakeDataSplit, abs1, 0, ""),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 8, 2, false, ActionFakeDataSplit, abs1, 0, ""),
			},
		},
		{
			slug: "fake-tls-auto-alt2", label: "FAKE TLS AUTO ALT2", quicRepeats: 11, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 10000000, false, ActionSplit, abs1, 681, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 10000000, false, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 10000000, false, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 8, 10000000, false, ActionSplit, abs1, 681, "tls_google"),
			},
		},
		{
			slug: "fake-tls-auto-alt3", label: "FAKE TLS AUTO ALT3", quicRepeats: 11, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeModeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeModeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_auto_google"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
				flowsealFakeModeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 8, 0, true, ActionSplit, abs1, 681, "tls_google"),
			},
		},
		{
			slug: "simple-fake", label: "SIMPLE FAKE", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealHostRule(flowsealYouTubePorts, flowsealTLSFingerprint, "www.google.com", 1, false, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 0, true),
			},
		},
		{
			slug: "simple-fake-alt", label: "SIMPLE FAKE ALT", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 2, false))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 2, false),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun2_decoy", "tls_google"}, 6, 2, false),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 2, false),
			},
		},
		{
			slug: "simple-fake-alt2", label: "SIMPLE FAKE ALT2", quicRepeats: 6, discordUDP: flowsealDiscordActive(6),
			youtubeTCP: []flowseal1102TCPRecipe{flowsealWithIPv4ID(flowsealFakeRule(flowsealYouTubePorts, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true))},
			discordTCP: []flowseal1102TCPRecipe{
				flowsealFakeRule(flowsealDiscordMediaTCP, flowsealTLSFingerprint, []string{"tls_google"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealTLSFingerprint, []string{"stun2_decoy", "tls_max"}, 6, 0, true),
				flowsealFakeRule(flowsealDiscordWebPorts, flowsealHTTPFingerprint, []string{"tls_max"}, 6, 0, true),
			},
		},
	}
	return profiles
}
