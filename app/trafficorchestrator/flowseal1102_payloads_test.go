package trafficorchestrator

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func TestFlowseal1102EmbeddedPayloadHashes(t *testing.T) {
	fixtures := []struct {
		name   string
		value  []byte
		length int
		sha256 string
	}{
		{"tls_clienthello_www_google_com.bin", flowseal1102GoogleTLS, 681, "936c2bee4cfb80aa3c426b2dcbcc834b3fbcd1adb17172959dc569c73a14275c"},
		{"quic_initial_www_google_com.bin", flowseal1102GoogleQUIC, 1200, "f4589c57749f956bb30538197a521d7005f8b0a8723b4707e72405e51ddac50a"},
		{"ACTIVE_DISCORD_UDP.bin", flowseal1102DiscordUDP, 1200, "2fe18b3bd20807d36704d0b072092ee49ae84edca907a4420ab9a0f0f28fddcf"},
		{"stun.bin", flowseal1102STUN, 100, "9cd5469309780ca56c0bd97266524a48c7ee529d02c3179cfecb20b260a59641"},
		{"stun2.bin", flowseal1102STUN2, 120, "b7c2497496039c541f7337ac8536813f0a1cf52363ab2faa5213b7816d458813"},
		{"tls_clienthello_4pda_to.bin", flowseal1102TLS4PDA, 284, "eefeaf09dde8d69b1f176212541f63c68b314a33a335eced99a8a29f17254da8"},
		{"tls_clienthello_max_ru.bin", flowseal1102TLSMax, 664, "4ee0870abe0a0128600b0095189987ba1d210dae8bf963bc725aff49cf922624"},
		{"tls_clienthello_sochi_park.bin", flowseal1102TLSSochi, 244, "ad552922acfe029521da884ea29f4bb28bb6bdcee9b1a70b46adbfd266c11d4d"},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.name, func(t *testing.T) {
			if len(fixture.value) != fixture.length {
				t.Fatalf("length = %d, want %d", len(fixture.value), fixture.length)
			}
			hash := sha256.Sum256(fixture.value)
			if got := hex.EncodeToString(hash[:]); got != fixture.sha256 {
				t.Fatalf("SHA-256 = %s, want %s", got, fixture.sha256)
			}
		})
	}
}
