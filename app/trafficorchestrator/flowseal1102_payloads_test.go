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
