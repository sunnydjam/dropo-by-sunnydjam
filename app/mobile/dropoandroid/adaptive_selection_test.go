package dropoandroid

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	core "dropocore"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAdaptiveHealthIsBoundedAndHandoverClearsCooldown(t *testing.T) {
	server := &CommandServer{adaptiveNext: map[string]int64{}, adaptiveHealthIndex: map[string]int{}, adaptiveSelected: map[string]bool{}}
	_, _, due := server.adaptiveProbeDue(context.Background(), 0, "youtube")
	if !due {
		t.Fatal("initial probe skipped")
	}
	_, _, due = server.adaptiveProbeDue(context.Background(), 0, "youtube")
	if due {
		t.Fatal("failed candidates retried continuously")
	}
	server.resetAdaptiveLocked()
	server.adaptiveSelected["youtube"] = true
	active, index, due := server.adaptiveProbeDue(context.Background(), 0, "youtube")
	if !active || !due || index != 0 {
		t.Fatal("active health check unavailable")
	}
	_, _, due = server.adaptiveProbeDue(context.Background(), 0, "youtube")
	if due {
		t.Fatal("active health checks unbounded")
	}
	server.resetAdaptiveLocked()
	_, _, due = server.adaptiveProbeDue(context.Background(), 0, "youtube")
	if !due {
		t.Fatal("handover did not schedule fresh acceptance")
	}
}

func TestAdaptiveStaleWorkerCannotPostponeNewSessionProbes(t *testing.T) {
	server := &CommandServer{sourceGeneration: 2, adaptiveNext: map[string]int64{}, adaptiveHealthIndex: map[string]int{}, adaptiveSelected: map[string]bool{}}
	if _, _, due := server.adaptiveProbeDue(context.Background(), 1, "youtube"); due {
		t.Fatal("stale session scheduled a probe")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, due := server.adaptiveProbeDue(cancelled, 2, "youtube"); due {
		t.Fatal("cancelled network cycle scheduled a probe")
	}
	if len(server.adaptiveNext) != 0 || len(server.adaptiveHealthIndex) != 0 {
		t.Fatal("cancelled work changed the next session's health schedule")
	}
	if _, _, due := server.adaptiveProbeDue(context.Background(), 2, "youtube"); !due {
		t.Fatal("fresh session probe was postponed")
	}
}

func TestAdaptiveBuiltGraphPassesPinnedEngineConfigCheck(t *testing.T) {
	playPolicyFixture(t)
	storedCoreFixture(t)
	var response map[string]any
	raw := core.Call("AddVPNSource", `["TLS fixture","vless://00000000-0000-0000-0000-000000000001@fixture.invalid:443?security=tls"]`)
	if json.Unmarshal([]byte(raw), &response) != nil || response["success"] != true {
		t.Fatal("source fixture failed")
	}
	if json.Unmarshal([]byte(core.Call("SetRoutingMode", `["blocked_only"]`)), &response) != nil || response["success"] != true {
		t.Fatal("selective mode fixture failed")
	}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &response) != nil || response["success"] != true {
		t.Fatal("adaptive graph rejected")
	}
	config := response["config"].(string)
	if !strings.Contains(config, core.AndroidAdaptiveSelectorPrefix) {
		t.Fatal("adaptive selectors absent")
	}
	if err := CheckConfig(config); err != nil {
		t.Fatal("pinned engine rejected adaptive graph", err)
	}
}

func TestAdaptiveRequiresAllTargetsInEveryRoundAndCancels(t *testing.T) {
	count := 0
	targets := []string{"one", "two", "three"}
	probe := func(context.Context, string) error { count++; return nil }
	if err := probeAdaptiveAttempts(context.Background(), targets, 3, probe); err != nil || count != 9 {
		t.Fatal("not three complete rounds", count, err)
	}
	count = 0
	failed := func(_ context.Context, target string) error {
		count++
		if target == "two" {
			return errors.New("unavailable")
		}
		return nil
	}
	if probeAdaptiveAttempts(context.Background(), targets, 3, failed) == nil {
		t.Fatal("partial success accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	count = 0
	if probeAdaptiveAttempts(ctx, targets, 3, probe) == nil || count != 0 {
		t.Fatal("cancelled task performed probes")
	}
}

func TestAdaptiveTLSRecordUsesVerifiedTLSAndRejectsHTTPFailures(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	now := time.Now()
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "fragment.fixture.invalid"}, DNSNames: []string{"fragment.fixture.invalid"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	status := 200
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status); w.Write([]byte("ok")) }))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	server.StartTLS()
	defer server.Close()
	dialer := &testOutboundDialer{address: server.Listener.Addr().String()}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	target := "https://fragment.fixture.invalid/"
	if err = probeAdaptiveHTTPWithRoots(ctx, target, dialer, roots); err != nil {
		t.Fatal("record-fragmented verified handshake failed", err)
	}
	status = 403
	if probeAdaptiveHTTPWithRoots(ctx, target, dialer, roots) == nil {
		t.Fatal("403 counted as healthy")
	}
	if probeAdaptiveHTTPWithRoots(ctx, "https://wrong.fixture.invalid/", dialer, roots) == nil {
		t.Fatal("wrong hostname accepted")
	}
	if probeAdaptiveHTTP(ctx, target, dialer) == nil {
		t.Fatal("untrusted certificate accepted")
	}
}

func TestAdaptiveEncryptionExceptionCannotBroadenVPNSelector(t *testing.T) {
	var domains []any
	json.Unmarshal([]byte(core.AndroidAdaptiveServiceDomains("youtube")), &domains)
	selector := map[string]any{"type": "selector", "tag": core.AndroidAdaptiveSelectorPrefix + "youtube", "outbounds": []any{"proxy", "direct"}, "default": "proxy", "interrupt_exist_connections": true}
	rule := map[string]any{"network": "tcp", "protocol": "tls", "port": 443, "domain_suffix": domains, "action": "route", "outbound": selector["tag"], "tls_record_fragment": true}
	secure := map[string]any{"type": "vless", "tag": "secure", "tls": verifiedTLSFixture()}
	proxy := map[string]any{"type": "selector", "tag": "proxy", "outbounds": []any{"secure"}}
	route := map[string]any{"final": "direct", "rules": []any{rule}}
	cfg := map[string]any{"outbounds": []any{secure, proxy, map[string]any{"type": "direct", "tag": "direct"}, selector}, "route": route}
	encode := func() string { data, _ := json.Marshal(cfg); return string(data) }
	if err := validateEncryptedVPNConfig(encode()); err != nil {
		t.Fatal("narrow selector refused", err)
	}
	route["final"] = "proxy"
	if validateEncryptedVPNConfig(encode()) == nil {
		t.Fatal("full VPN accepted an adaptive direct exception")
	}
	route["final"] = "direct"
	rule["network"] = "udp"
	if validateEncryptedVPNConfig(encode()) == nil {
		t.Fatal("UDP exception accepted")
	}
	rule["network"] = "tcp"
	rule["domain_suffix"] = []any{"com"}
	if validateEncryptedVPNConfig(encode()) == nil {
		t.Fatal("broad domain exception accepted")
	}
	rule["domain_suffix"] = domains
	proxy["outbounds"] = []any{selector["tag"]}
	if validateEncryptedVPNConfig(encode()) == nil {
		t.Fatal("general VPN routed through adaptive direct")
	}
	proxy["outbounds"] = []any{"secure"}
	selector["default"] = "direct"
	if validateEncryptedVPNConfig(encode()) == nil {
		t.Fatal("direct bootstrap accepted")
	}
	if strings.Contains(core.AndroidAdaptiveServiceDomains("discord"), "discord.com") {
		t.Fatal("unverified media service in direct candidates")
	}
}
