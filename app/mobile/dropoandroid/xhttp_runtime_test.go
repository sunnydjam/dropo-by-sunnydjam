package dropoandroid

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"github.com/miekg/dns"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/protocol/socks"
	xnet "github.com/xtls/xray-core/common/net"
)

const fixtureXHTTPUUID = "11111111-2222-3333-4444-555555555555"

func fixtureXHTTPOutbound(port int, tlsEnabled bool) map[string]any {
	stream := map[string]any{"network": "xhttp", "xhttpSettings": map[string]any{
		"host": "localhost", "path": "/dropo-test", "mode": "auto",
		"extra": map[string]any{"noGRPCHeader": true, "scMaxConcurrentPosts": 100,
			"scMaxEachPostBytes": 1000000, "scMinPostsIntervalMs": 30, "xPaddingBytes": "100-1000",
			"xmux": map[string]any{"maxConcurrency": 16, "cMaxReuseTimes": 64,
				"hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000"}}}}
	if tlsEnabled {
		stream["security"] = "tls"
		stream["tlsSettings"] = map[string]any{"serverName": "localhost", "fingerprint": "chrome", "alpn": []string{"h2", "http/1.1"}}
	}
	return map[string]any{"protocol": "vless", "tag": "candidate-source", "settings": map[string]any{
		"vnext": []any{map[string]any{"address": "127.0.0.1", "port": port,
			"users": []any{map[string]any{"id": fixtureXHTTPUUID, "encryption": "none"}}}}}, "streamSettings": stream}
}

func encodeXHTTPFixture(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func fixtureCertificate(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)},
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}))
}

func startXHTTPFixture(t *testing.T, tlsEnabled bool, physicalDNS ...string) (int, string) {
	t.Helper()
	reserved, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	reserved.Close()
	stream := map[string]any{"network": "xhttp", "xhttpSettings": map[string]any{"host": "localhost", "path": "/dropo-test"}}
	root, key := fixtureCertificate(t)
	if tlsEnabled {
		stream["security"] = "tls"
		stream["tlsSettings"] = map[string]any{"alpn": []string{"h2", "http/1.1"}, "certificates": []any{map[string]any{"certificate": strings.Split(strings.TrimSpace(root), "\n"), "key": strings.Split(strings.TrimSpace(key), "\n")}}}
	}
	dns := map[string]any{"hosts": map[string]any{"dropo-echo.test": "127.0.0.1"}}
	if len(physicalDNS) > 0 {
		dns["servers"] = physicalDNS
	}
	raw := encodeXHTTPFixture(t, map[string]any{"log": map[string]any{"loglevel": "none", "access": "none", "error": "none"},
		"dns": dns,
		"inbounds": []any{map[string]any{"listen": "127.0.0.1", "port": port, "protocol": "vless",
			"settings": map[string]any{"decryption": "none", "clients": []any{map[string]any{"id": fixtureXHTTPUUID}}}, "streamSettings": stream}},
		"outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{"domainStrategy": "UseIP"}}}})
	startXHTTPFixtureProcess(t, raw)
	return port, root
}

func startXHTTPEcho(t *testing.T) (M.Socksaddr, M.Socksaddr) {
	t.Helper()
	tcp, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tcp.Close(); udp.Close() })
	go func() {
		for {
			connection, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() { defer connection.Close(); io.Copy(connection, connection) }()
		}
	}()
	go func() {
		data := make([]byte, 8192)
		for {
			n, source, err := udp.ReadFrom(data)
			if err != nil {
				return
			}
			udp.WriteTo(data[:n], source)
		}
	}()
	return M.SocksaddrFromNet(tcp.Addr()), M.SocksaddrFromNet(udp.LocalAddr())
}

func exchangeXHTTPFixture(t *testing.T, bridge *xhttpBridge, tcp, udp M.Socksaddr) {
	t.Helper()
	client := socks.NewClient(&testOutboundDialer{address: bridge.listener.Addr().String()}, M.SocksaddrFromNet(bridge.listener.Addr()), socks.Version5, bridge.username, bridge.password)
	// The existing testOutboundDialer redirects every call to the TCP port;
	// use the actual network destination dialer for UDP associations below.
	client = socks.NewClient(xhttpFixtureDialer{}, M.SocksaddrFromNet(bridge.listener.Addr()), socks.Version5, bridge.username, bridge.password)
	connection, err := client.DialContext(context.Background(), "tcp", tcp)
	if err != nil {
		t.Fatal("TCP SOCKS negotiation failed")
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = connection.Write([]byte("tcp-through-xhttp")); err != nil {
		t.Fatal("TCP write failed")
	}
	data := make([]byte, len("tcp-through-xhttp"))
	if _, err = io.ReadFull(connection, data); err != nil || string(data) != "tcp-through-xhttp" {
		t.Fatal("TCP XHTTP echo failed")
	}
	packet, err := client.ListenPacket(context.Background(), udp)
	if err != nil {
		t.Fatal("UDP SOCKS negotiation failed")
	}
	defer packet.Close()
	packet.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = packet.WriteTo([]byte("udp-through-xhttp"), udp.UDPAddr()); err != nil {
		t.Fatal("UDP write failed")
	}
	data = make([]byte, 8192)
	n, _, err := packet.ReadFrom(data)
	if err != nil || string(data[:n]) != "udp-through-xhttp" {
		t.Fatal("UDP XHTTP echo failed")
	}
}

type xhttpFixtureDialer struct{}

func (xhttpFixtureDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, network, destination.String())
}
func (xhttpFixtureDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return (&net.ListenConfig{}).ListenPacket(ctx, "udp", "127.0.0.1:0")
}

func TestXHTTPActualTCPUDPAndReconnect(t *testing.T) {
	for _, secure := range []bool{false, true} {
		t.Run(map[bool]string{false: "plaintext", true: "verified-TLS-auto-provider-extra"}[secure], func(t *testing.T) {
			port, root := startXHTTPFixture(t, secure)
			tcp, udp := startXHTTPEcho(t)
			built, err := buildXHTTPConfig(encodeXHTTPFixture(t, fixtureXHTTPOutbound(port, secure)), []string{root})
			if err != nil {
				t.Fatal("supported provider fixture rejected")
			}
			var protections atomic.Int32
			protect := func(int32) error { protections.Add(1); return nil }
			first, err := newXHTTPBridge(built, protect, nil)
			if err != nil {
				t.Fatal(err)
			}
			exchangeXHTTPFixture(t, first, tcp, udp)
			first.close()
			old := protections.Load()
			if old == 0 {
				t.Fatal("XHTTP bypassed socket protection")
			}
			if _, err := (protectedXHTTPDialer{}).Dial(first.session.ctx, nil, xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(port)), nil); err == nil {
				t.Fatal("stopped session opened a socket")
			}
			second, err := newXHTTPBridge(built, protect, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer second.close()
			exchangeXHTTPFixture(t, second, tcp, udp)
			if protections.Load() <= old {
				t.Fatal("new session reused a stopped physical socket")
			}
			beforeReset := protections.Load()
			address, credentials := second.listener.Addr().String(), second.password
			second.resetNetwork()
			exchangeXHTTPFixture(t, second, tcp, udp)
			if protections.Load() <= beforeReset || second.listener.Addr().String() != address || second.password != credentials {
				t.Fatal("network reset failed to renew physical transport or recreated the local bridge")
			}
		})
	}
}

func TestXHTTPActualMultiDestinationUDPAfterDNSAndPayloadBounds(t *testing.T) {
	startXHTTPDNSFixture(t, "127.0.0.3", "dropo-echo.test.")
	port, root := startXHTTPFixture(t, true, "127.0.0.3")
	_, target := startXHTTPEcho(t)
	dns, err := net.ListenPacket("udp4", "127.0.0.2:53")
	if err != nil {
		t.Skip("synthetic loopback DNS port is unavailable")
	}
	defer dns.Close()
	go func() {
		data := make([]byte, 8192)
		for {
			n, peer, err := dns.ReadFrom(data)
			if err != nil {
				return
			}
			dns.WriteTo(data[:n], peer)
		}
	}()
	built, err := buildXHTTPConfig(encodeXHTTPFixture(t, fixtureXHTTPOutbound(port, true)), []string{root})
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := newXHTTPBridge(built, func(int32) error { return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.close()
	client := socks.NewClient(xhttpFixtureDialer{}, M.SocksaddrFromNet(bridge.listener.Addr()), socks.Version5, bridge.username, bridge.password)
	packet, err := client.ListenPacket(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	defer packet.Close()
	packet.SetDeadline(time.Now().Add(5 * time.Second))
	for i, destination := range []net.Addr{dns.LocalAddr(), target.UDPAddr(), dns.LocalAddr(), target.UDPAddr()} {
		payload := []byte(strings.Repeat(string(rune('a'+i)), 4096))
		if _, err = packet.WriteTo(payload, destination); err != nil {
			t.Fatal("multi-target UDP write failed")
		}
		data := make([]byte, 8192)
		n, source, err := packet.ReadFrom(data)
		if err != nil || string(data[:n]) != string(payload) || source.String() != destination.String() {
			t.Fatal("UDP target changed after first DNS destination or payload was truncated")
		}
	}
	remote, err := newXHTTPUDPConn(bridge.session.ctx, bridge.instance)
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	if _, err = remote.WriteTo(make([]byte, maxXHTTPUDPPayload+1), target); err == nil {
		t.Fatal("oversized UDP silently accepted")
	}
	domain := M.ParseSocksaddrHostPort("dropo-echo.test", target.Port)
	payload := []byte(strings.Repeat("d", maxXHTTPUDPPayload))
	if _, err = packet.WriteTo(payload, domain); err != nil {
		t.Fatal("domain UDP target write failed")
	}
	data := make([]byte, 8192)
	n, _, err := packet.ReadFrom(data)
	if err != nil || string(data[:n]) != string(payload) {
		t.Fatal("domain UDP target or maximum payload failed to echo")
	}
}

func startXHTTPDNSFixture(t *testing.T, listenIP, domain string) {
	t.Helper()
	packet, err := net.ListenPacket("udp4", listenIP+":53")
	if err != nil {
		t.Skip("synthetic physical DNS fixture port unavailable")
	}
	mux := dns.NewServeMux()
	mux.HandleFunc(domain, func(w dns.ResponseWriter, r *dns.Msg) {
		reply := new(dns.Msg)
		reply.SetReply(r)
		for _, q := range r.Question {
			if q.Qtype == dns.TypeA {
				reply.Answer = append(reply.Answer, &dns.A{Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.IPv4(127, 0, 0, 1)})
			}
		}
		w.WriteMsg(reply)
	})
	server := &dns.Server{PacketConn: packet, Handler: mux}
	go server.ActivateAndServe()
	t.Cleanup(func() { server.Shutdown() })
}

func TestXHTTPDomainResolutionUsesProtectedPhysicalDNS(t *testing.T) {
	packet, err := net.ListenPacket("udp4", "127.0.0.3:53")
	if err != nil {
		t.Skip("synthetic physical DNS fixture port unavailable")
	}
	mux := dns.NewServeMux()
	mux.HandleFunc("dropo-dns.test.", func(w dns.ResponseWriter, r *dns.Msg) {
		reply := new(dns.Msg)
		reply.SetReply(r)
		for _, q := range r.Question {
			if q.Qtype == dns.TypeA {
				reply.Answer = append(reply.Answer, &dns.A{Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.IPv4(127, 0, 0, 1)})
			}
		}
		w.WriteMsg(reply)
	})
	server := &dns.Server{PacketConn: packet, Handler: mux}
	go server.ActivateAndServe()
	defer server.Shutdown()
	tcp, _ := startXHTTPEcho(t)
	var controls atomic.Int32
	session := newXHTTPSocketSession(func(int32) error { controls.Add(1); return nil }, func() []string { return []string{"127.0.0.3"} })
	defer session.close()
	connection, err := (protectedXHTTPDialer{}).Dial(session.ctx, nil, xnet.TCPDestination(xnet.DomainAddress("dropo-dns.test"), xnet.Port(tcp.Port)), nil)
	if err != nil {
		t.Fatal("physical protected DNS lookup failed")
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(2 * time.Second))
	connection.Write([]byte("dns-protected"))
	data := make([]byte, 13)
	if _, err = io.ReadFull(connection, data); err != nil || string(data) != "dns-protected" || controls.Load() < 2 {
		t.Fatal("DNS or destination socket bypassed Android protection")
	}
}

func TestXHTTPSourceProbeTraversesSelectedBridgeAndStopCancels(t *testing.T) {
	port, root := startXHTTPFixture(t, true)
	built, err := buildXHTTPConfig(encodeXHTTPFixture(t, fixtureXHTTPOutbound(port, true)), []string{root})
	if err != nil {
		t.Fatal(err)
	}
	bridge, err := newXHTTPBridge(built, func(int32) error { return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer bridge.close()
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/204" {
			w.WriteHeader(204)
			return
		}
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	client := socks.NewClient(xhttpFixtureDialer{}, M.SocksaddrFromNet(bridge.listener.Addr()), socks.Version5, bridge.username, bridge.password)
	if err = probeSourceHTTP(context.Background(), server.URL+"/204", client); err != nil {
		t.Fatal("source probe bypassed or failed XHTTP bridge")
	}
	done := make(chan error, 1)
	go func() { done <- probeSourceHTTP(context.Background(), server.URL+"/pending", client) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("pending source request did not reach fixture")
	}
	bridge.stop()
	select {
	case err = <-done:
		if err == nil {
			t.Fatal("stopped probe reported success")
		}
	case <-time.After(time.Second):
		t.Fatal("Stop left a pending source probe alive")
	}
}

func TestXHTTPShutdownRejectsInFlightRegistrationAndOldOwnerAfterRearm(t *testing.T) {
	epoch := currentXHTTPEpoch()
	created, continueRegistration := make(chan struct{}), make(chan struct{})
	result := make(chan bool, 1)
	go func() { close(created); <-continueRegistration; result <- registerXHTTPBridge(&xhttpBridge{}, epoch) }()
	<-created
	shutdownXHTTPInstances()
	defer rearmXHTTPRuntime()
	close(continueRegistration)
	if <-result {
		t.Fatal("pending bridge registered after Shutdown snapshot")
	}
	rearmXHTTPRuntime()
	if xHTTPEpochCurrent(epoch) || registerXHTTPBridge(&xhttpBridge{}, epoch) {
		t.Fatal("old CommandServer generation recovered after EnsureStarted")
	}
}

func TestXHTTPProtectFailureClosedForTCPUDPAndStaleContext(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var controls atomic.Int32
	session := newXHTTPSocketSession(func(int32) error { controls.Add(1); return errors.New("private diagnostic") }, nil)
	defer session.close()
	for _, network := range []xnet.Network{xnet.Network_TCP, xnet.Network_UDP} {
		dest := xnet.Destination{Network: network, Address: xnet.LocalHostIP, Port: xnet.Port(listener.Addr().(*net.TCPAddr).Port)}
		_, err := (protectedXHTTPDialer{}).Dial(session.ctx, nil, dest, nil)
		if err == nil || strings.Contains(err.Error(), "private diagnostic") {
			t.Fatal("socket protection failure was ignored or leaked")
		}
	}
	if controls.Load() != 2 {
		t.Fatal("TCP/UDP missing protect callbacks")
	}
	session.close()
	ctx := context.WithoutCancel(session.ctx)
	_, err = (protectedXHTTPDialer{}).Dial(ctx, nil, xnet.TCPDestination(xnet.LocalHostIP, 80), nil)
	if err == nil || controls.Load() != 2 {
		t.Fatal("stale WithoutCancel context resurrected protection")
	}
}

func TestXHTTPClosedAndFullTrackDoNotDeadlock(t *testing.T) {
	for _, closed := range []bool{false, true} {
		session := newXHTTPSocketSession(func(int32) error { return nil }, nil)
		if closed {
			session.close()
		} else {
			for i := 0; i < 512; i++ {
				session.connections[&noopXHTTPCloser{}] = struct{}{}
			}
		}
		left, right := net.Pipe()
		defer right.Close()
		done := make(chan bool, 1)
		go func() { done <- session.track(&trackedXHTTPConn{Conn: left, session: session}) }()
		select {
		case accepted := <-done:
			if accepted {
				t.Fatal("closed/full session accepted a socket")
			}
		case <-time.After(time.Second):
			t.Fatal("track deadlocked while closing wrapped socket")
		}
		session.close()
	}
}

type noopXHTTPCloser struct{ marker byte }

func (*noopXHTTPCloser) Close() error { return nil }

func TestXHTTPConfigCheckHasNoNetworkOrInstancesAndSanitizesErrors(t *testing.T) {
	liveXHTTPBridges.Lock()
	before := len(liveXHTTPBridges.items)
	liveXHTTPBridges.Unlock()
	placeholder := map[string]any{"type": xhttpOutboundType, "tag": "source-one", "xray_outbound": fixtureXHTTPOutbound(443, true)}
	config := string(encodeXHTTPFixture(t, map[string]any{"outbounds": []any{placeholder}, "route": map[string]any{"final": "source-one"}}))
	if err := CheckConfig(config); err != nil {
		t.Fatalf("XHTTP configuration check failed: %v", err)
	}
	liveXHTTPBridges.Lock()
	after := len(liveXHTTPBridges.items)
	liveXHTTPBridges.Unlock()
	if before != after {
		t.Fatal("configuration check started an Xray instance")
	}
	invalid := fixtureXHTTPOutbound(443, true)
	invalid["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["users"].([]any)[0].(map[string]any)["id"] = strings.Repeat("credential", 10)
	_, err := buildXHTTPConfig(encodeXHTTPFixture(t, invalid), nil)
	if err == nil || strings.Contains(err.Error(), "credential") {
		t.Fatal("invalid provider identity accepted or exposed")
	}
	invalid = fixtureXHTTPOutbound(443, true)
	invalid["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)["allowInsecure"] = true
	if _, err = buildXHTTPConfig(encodeXHTTPFixture(t, invalid), nil); err == nil {
		t.Fatal("insecure TLS accepted")
	}
}
