package dropoandroid

import (
	core "dropocore"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func encryptedConfigFixture(t *testing.T, outbounds ...map[string]any) string {
	t.Helper()
	items := make([]any, 0, len(outbounds))
	for _, outbound := range outbounds {
		items = append(items, outbound)
	}
	encoded, err := json.Marshal(map[string]any{"outbounds": items})
	if err != nil {
		t.Fatal("fixture encoding failed")
	}
	return string(encoded)
}

func verifiedTLSFixture() map[string]any {
	return map[string]any{"enabled": true, "server_name": "fixture.invalid"}
}

func realityKeyFixture() string {
	return base64.RawURLEncoding.EncodeToString(make([]byte, 32))
}

func playPolicyFixture(t *testing.T) {
	t.Helper()
	androidVPNDistribution.Lock()
	configured, play := androidVPNDistribution.configured, androidVPNDistribution.play
	androidVPNDistribution.configured, androidVPNDistribution.play = true, true
	androidVPNDistribution.Unlock()
	t.Cleanup(func() {
		androidVPNDistribution.Lock()
		androidVPNDistribution.configured, androidVPNDistribution.play = configured, play
		androidVPNDistribution.Unlock()
	})
}

func storedCoreFixture(t *testing.T) string {
	t.Helper()
	base := t.TempDir()
	// EnsureStarted may preserve an existing in-memory core for a missing file;
	// use explicit empty synthetic persisted state to isolate fixture sources.
	if os.WriteFile(filepath.Join(base, "dropocore_state.json"), []byte(`{"subscription":"","vpnSources":[],"cachedSingBoxConfig":"","cachedConfigSubscription":"","cachedConfigSignature":"","config":{"autoUpdateSub":false},"serviceState":"stopped","connected":false}`), 0600) != nil {
		t.Fatal("empty synthetic persisted state could not save")
	}
	core.EnsureStarted(base, "test")
	t.Cleanup(func() { core.Shutdown() })
	return base
}

func TestVPNDistributionDefaultsFailClosedAndIsImmutable(t *testing.T) {
	for _, play := range []bool{true, false} {
		var policy vpnDistributionPolicy
		if !policy.requiresEncryption() {
			t.Fatal("unconfigured binding was permissive")
		}
		if policy.configure(play) != nil || policy.requiresEncryption() != play || policy.configure(play) != nil {
			t.Fatal("distribution initialization is not idempotent")
		}
		if policy.configure(!play) == nil || policy.requiresEncryption() != play {
			t.Fatal("running process changed distribution")
		}
	}
}

func TestPlayVPNAllowsAuthenticatedEncryptedProtocols(t *testing.T) {
	for _, protocol := range []string{"vless", "trojan", "hysteria2", "tuic"} {
		t.Run(protocol+"-TLS", func(t *testing.T) {
			outbound := map[string]any{"type": protocol, "tag": "vpn", "tls": verifiedTLSFixture()}
			if validateEncryptedVPNConfig(encryptedConfigFixture(t, outbound)) != nil {
				t.Fatal("verified TLS protocol rejected")
			}
		})
	}
	for _, security := range []string{"auto", "aes-128-gcm", "chacha20-poly1305"} {
		outbound := map[string]any{"type": "vmess", "tag": "vpn", "security": security}
		if validateEncryptedVPNConfig(encryptedConfigFixture(t, outbound)) != nil {
			t.Fatal("authenticated VMess cipher rejected")
		}
	}
	for _, method := range []string{"aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
		"2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"} {
		outbound := map[string]any{"type": "shadowsocks", "tag": "vpn", "method": method}
		if validateEncryptedVPNConfig(encryptedConfigFixture(t, outbound)) != nil {
			t.Fatal("AEAD Shadowsocks cipher rejected")
		}
	}
	tls := verifiedTLSFixture()
	tls["reality"] = map[string]any{"enabled": true, "public_key": realityKeyFixture()}
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, map[string]any{"type": "vless", "tag": "vpn", "tls": tls})) != nil {
		t.Fatal("verified REALITY rejected")
	}
}

func TestPlayVPNRejectsPlaintextWeakAndUnverifiedProtocols(t *testing.T) {
	fixtures := []map[string]any{
		{"type": "vless", "tag": "vpn"},
		{"type": "trojan", "tag": "vpn", "tls": map[string]any{"enabled": false}},
		{"type": "vless", "tag": "vpn", "tls": map[string]any{"enabled": true, "insecure": true}},
		{"type": "hysteria2", "tag": "vpn", "tls": map[string]any{"enabled": true, "insecure": "false"}},
		{"type": "tuic", "tag": "vpn", "tls": map[string]any{"enabled": true, "min_version": "1.0"}},
		{"type": "vless", "tag": "vpn", "tls": map[string]any{"enabled": true, "reality": map[string]any{"enabled": true, "public_key": "invalid"}}},
		{"type": "vmess", "tag": "vpn", "security": "none"},
		{"type": "vmess", "tag": "vpn", "security": "zero"},
		{"type": "vmess", "tag": "vpn", "security": "auto", "tls": map[string]any{"enabled": true, "insecure": true}},
		{"type": "shadowsocks", "tag": "vpn", "method": "none"},
		{"type": "shadowsocks", "tag": "vpn", "method": "aes-256-cfb"},
		{"type": "shadowsocks", "tag": "vpn", "method": "future-cipher"},
		{"type": "socks", "tag": "vpn"},
		{"type": "http", "tag": "vpn"},
		{"type": "future-proxy", "tag": "vpn"},
		{"type": "direct", "tag": "vpn", "override_address": "fixture.invalid"},
	}
	for i, outbound := range fixtures {
		if validateEncryptedVPNConfig(encryptedConfigFixture(t, outbound)) == nil {
			t.Errorf("unsafe fixture %d accepted", i)
		}
	}
}

func TestPlayVPNChecksAllSourceAndAuxiliaryEndpoints(t *testing.T) {
	secure := map[string]any{"type": "vless", "tag": "vpn-one", "tls": verifiedTLSFixture()}
	plain := map[string]any{"type": "vless", "tag": "vpn-two"}
	selector := map[string]any{"type": "selector", "tag": "proxy", "outbounds": []any{"vpn-one", "vpn-two"}, "default": "vpn-one"}
	direct := map[string]any{"type": "direct", "tag": "direct"}
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, secure, plain, selector, direct)) == nil {
		t.Fatal("unencrypted fallback accepted behind encrypted primary source")
	}
	plain["tag"] = "ru-proxy-1"
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, secure, plain, direct)) == nil {
		t.Fatal("unencrypted auxiliary source accepted")
	}
	selector["outbounds"] = []any{"vpn-one"}
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, secure, selector, direct)) != nil {
		t.Fatal("safe direct exceptions rejected")
	}
	selector["outbounds"] = []any{"direct"}
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, secure, selector, direct)) == nil {
		t.Fatal("direct VPN selector accepted")
	}
	if validateEncryptedVPNConfig(encryptedConfigFixture(t, direct)) == nil {
		t.Fatal("direct-only graph presented as encrypted VPN")
	}
}

func TestPlayVPNChecksBothXHTTPDirectionsAndPeerVerification(t *testing.T) {
	for _, security := range []string{"tls", "reality"} {
		for _, insecure := range []string{"", "none", "tls-insecure", "reality-invalid", "download-none", "download-insecure"} {
			stream := map[string]any{"network": "xhttp", "security": security, "xhttpSettings": map[string]any{}}
			if security == "tls" {
				stream["tlsSettings"] = map[string]any{"serverName": "fixture.invalid"}
			} else {
				stream["realitySettings"] = map[string]any{"serverName": "fixture.invalid", "publicKey": realityKeyFixture()}
			}
			switch insecure {
			case "none":
				stream["security"] = "none"
			case "tls-insecure":
				stream["security"] = "tls"
				stream["tlsSettings"] = map[string]any{"allowInsecure": true}
			case "reality-invalid":
				stream["security"] = "reality"
				stream["realitySettings"] = map[string]any{"publicKey": "not-a-key"}
			case "download-none", "download-insecure":
				download := map[string]any{"network": "xhttp", "security": "none", "xhttpSettings": map[string]any{}}
				if insecure == "download-insecure" {
					download["security"] = "tls"
					download["tlsSettings"] = map[string]any{"allowInsecure": true}
				}
				stream["xhttpSettings"].(map[string]any)["extra"] = map[string]any{"downloadSettings": download}
			}
			outbound := map[string]any{"type": xhttpOutboundType, "tag": "vpn", "xray_outbound": map[string]any{"streamSettings": stream}}
			err := validateEncryptedVPNConfig(encryptedConfigFixture(t, outbound))
			if (err == nil) != (insecure == "") {
				t.Errorf("XHTTP %s / %s produced wrong encryption decision", security, insecure)
			}
		}
	}
	stream := map[string]any{"network": "xhttp", "security": "tls", "xhttpSettings": map[string]any{"extra": map[string]any{
		"downloadSettings": map[string]any{"network": "xhttp", "security": "tls", "xhttpSettings": map[string]any{}},
	}}}
	if !verifiedXHTTPEncryption(stream, 0) {
		t.Fatal("both encrypted XHTTP directions rejected")
	}
}

func TestPlayVPNRejectsMalformedAndSidecarGraphsWithoutSecrets(t *testing.T) {
	secure := encryptedConfigFixture(t, map[string]any{"type": "vless", "tag": "vpn", "tls": verifiedTLSFixture()})
	for _, config := range []string{"", "not-json", secure + "{}", `{"outbounds":[],"endpoints":[{"type":"socks"}]}`,
		`{"outbounds":[{"type":"vless","tag":"vpn","uuid":"synthetic-secret","server":"private.invalid"}]}`} {
		err := validateEncryptedVPNConfig(config)
		if err == nil || strings.Contains(err.Error(), "synthetic-secret") || strings.Contains(err.Error(), "private.invalid") {
			t.Fatal("unsafe graph accepted or secrets exposed")
		}
	}
}

func TestPlayVPNRejectsLegacyStoredSourceAtBuildAndConfigCheck(t *testing.T) {
	playPolicyFixture(t)
	storedCoreFixture(t)
	var response map[string]any
	result := core.Call("AddVPNSource", `["Legacy fixture","vless://00000000-0000-0000-0000-000000000001@fixture.invalid:443?security=none"]`)
	if json.Unmarshal([]byte(result), &response) != nil || response["success"] != true {
		t.Fatal("fixture source could not be saved")
	}
	for attempt := 0; attempt < 2; attempt++ {
		result = BuildSingBoxConfig()
		if json.Unmarshal([]byte(result), &response) != nil || response["success"] != false || response["code"] != "vpn_encryption_required" {
			t.Fatal("legacy stored source / cached graph escaped Play enforcement")
		}
		if strings.Contains(result, "fixture.invalid") || strings.Contains(result, "00000000") || response["config"] != nil {
			t.Fatal("rejected source configuration leaked to caller")
		}
	}
	plain := encryptedConfigFixture(t, map[string]any{"type": "vless", "tag": "vpn"})
	if err := CheckConfig(plain); err != errVPNEncryption {
		t.Fatal("runtime configuration check skipped encryption policy")
	}
}

func TestPlayVPNPreservesStoredAuthoritativeNodeUntilUserSelects(t *testing.T) {
	playPolicyFixture(t)
	base := storedCoreFixture(t)
	var response map[string]any
	result := core.Call("AddVPNSource", `["Stored fixture","vless://00000000-0000-0000-0000-000000000001@fixture.invalid:443?security=none"]`)
	if json.Unmarshal([]byte(result), &response) != nil || response["success"] != true {
		t.Fatal("stored source fixture could not be created")
	}
	core.Shutdown()
	// Only synthetic app-private state in t.TempDir is read or changed here.
	// Reproduce a pre-upgrade subscription with plaintext first + TLS sibling.
	path := filepath.Join(base, "dropocore_state.json")
	encoded, err := os.ReadFile(path)
	var state map[string]any
	if err != nil || json.Unmarshal(encoded, &state) != nil {
		t.Fatal("synthetic stored state could not load")
	}
	source := state["vpnSources"].([]any)[0].(map[string]any)
	first := source["nodes"].([]any)[0].(map[string]any)
	second := make(map[string]any, len(first))
	for key, value := range first {
		second[key] = value
	}
	second["Security"], second["SNI"], second["Name"] = "tls", "fixture.invalid", "Protected sibling"
	source["nodes"] = []any{first, second}
	encoded, err = json.Marshal(state)
	if err != nil || os.WriteFile(path, encoded, 0600) != nil {
		t.Fatal("synthetic stored subscription could not save")
	}
	// Change the fixture base once to reproduce a cold load, not an idempotent
	// Activity EnsureStarted call that deliberately preserves the live state.
	core.EnsureStarted(t.TempDir(), "test")
	core.EnsureStarted(base, "test")
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &response) != nil || response["success"] != false {
		t.Fatal("plaintext authoritative first node silently replaced by encrypted sibling")
	}
	if json.Unmarshal([]byte(core.Call("GetVPNSources", "[]")), &response) != nil {
		t.Fatal("stored source view could not read")
	}
	view := response["sources"].([]any)[0].(map[string]any)
	if view["node_count"] != float64(2) || view["selected_node"] != float64(0) {
		t.Fatal("Play policy filtered nodes or changed provider's authoritative selection")
	}
	args, _ := json.Marshal([]any{source["id"], 1})
	if json.Unmarshal([]byte(core.Call("SetVPNSourceNode", string(args))), &response) != nil || response["success"] != true {
		t.Fatal("explicit protected sibling choice failed")
	}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &response) != nil || response["success"] != true {
		t.Fatal("explicit protected stored source was rejected")
	}
	config, ok := response["config"].(string)
	if !ok || CheckConfig(config) != nil {
		t.Fatal("protected generated runtime graph did not pass actual configuration check")
	}
}

func TestPlayVPNGuardsXHTTPSidecarBeforeAnyStartOrProbe(t *testing.T) {
	playPolicyFixture(t)
	liveXHTTPBridges.Lock()
	before := len(liveXHTTPBridges.items)
	liveXHTTPBridges.Unlock()
	plain := fixtureXHTTPOutbound(443, false)
	config := encryptedConfigFixture(t, map[string]any{
		"type": xhttpOutboundType, "tag": "vpn", "xray_outbound": plain,
	})
	for _, start := range []bool{false, true} {
		_, runtime, err := normalizeXHTTPConfig(config, nil, start)
		if err != errVPNEncryption || runtime != nil {
			t.Fatal("sidecar normalization reached runtime setup before encryption gate")
		}
	}
	liveXHTTPBridges.Lock()
	after := len(liveXHTTPBridges.items)
	liveXHTTPBridges.Unlock()
	if before != after {
		t.Fatal("rejected plaintext configuration opened an XHTTP sidecar")
	}
}

func TestSideloadPolicyDoesNotFilterOrRewriteSources(t *testing.T) {
	androidVPNDistribution.RLock()
	play := androidVPNDistribution.play
	configured := androidVPNDistribution.configured
	androidVPNDistribution.RUnlock()
	if play || !configured {
		t.Fatal("test runner must explicitly identify synthetic Preview fixtures")
	}
	result := `{"success":true,"config":"synthetic-legacy-graph","cached":true}`
	if enforceBuiltVPNConfig(result) != result || enforceVPNEncryption("synthetic-legacy-graph") != nil {
		t.Fatal("sideload distribution unexpectedly filtered / rewrote source data")
	}
}
