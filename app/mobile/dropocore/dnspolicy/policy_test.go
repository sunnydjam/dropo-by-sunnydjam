package dnspolicy

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestPolicyRejectsForeignAndPrivateBootstrap(t *testing.T) {
	for _, change := range []func(*Policy){func(p *Policy) { p.Resolvers[0].Hostname = "evil.invalid" }, func(p *Policy) { p.Resolvers[0].IPv4 = []string{"127.0.0.1"} }, func(p *Policy) { p.Resolvers[0].IPv4 = []string{"198.18.0.1"} }, func(p *Policy) { p.Resolvers[0].Path = "/other" }} {
		p := Default()
		change(&p)
		if p.Validate() == nil {
			t.Fatal("untrusted policy accepted")
		}
	}
}
func TestProtectedLookupPinsIPAndRejectsRebinding(t *testing.T) {
	for _, private := range []bool{false, true} {
		t.Run(map[bool]string{false: "public", true: "rebinding"}[private], func(t *testing.T) {
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Host != Hostname || r.Method != "POST" || r.URL.Path != QueryPath {
					t.Error("hostname/path changed")
				}
				raw, _ := io.ReadAll(r.Body)
				var msg dnsmessage.Message
				if msg.Unpack(raw) != nil {
					t.Error("invalid query")
				}
				msg.Header.Response = true
				msg.Header.RecursionAvailable = true
				address := [4]byte{93, 184, 215, 14}
				if private {
					address = [4]byte{10, 0, 0, 1}
				}
				msg.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: msg.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 30}, Body: &dnsmessage.AResource{A: address}}}
				packed, _ := msg.Pack()
				w.Header().Set("Content-Type", "application/dns-message")
				w.Write(packed)
			}))
			key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			template := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{Hostname}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
			der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
			if err != nil {
				t.Fatal(err)
			}
			server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
			server.StartTLS()
			defer server.Close()
			roots := x509.NewCertPool()
			roots.AddCert(server.Certificate())
			resolver := Resolver{Policy: Default(), TLS: &tls.Config{RootCAs: roots}, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				if address != BootstrapIPv4+":443" {
					t.Error("system DNS/bootstrap used")
				}
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}}
			addresses, err := resolver.Lookup(context.Background(), "example.com")
			if private && err == nil {
				t.Fatal("private rebinding answer accepted")
			}
			if !private && (err != nil || len(addresses) != 1 || addresses[0].String() != "93.184.215.14") {
				t.Fatalf("public answer failed: %v", err)
			}
			resolver.TLS = nil
			if _, err := resolver.Lookup(context.Background(), "example.com"); err == nil {
				t.Fatal("untrusted certificate accepted")
			}
		})
	}
}
func TestNoRawDNSFallback(t *testing.T) {
	calls := 0
	resolver := Resolver{Policy: Default(), Dial: func(context.Context, string, string) (net.Conn, error) { calls++; return nil, context.DeadlineExceeded }}
	if _, err := resolver.Lookup(context.Background(), "example.com"); err == nil || calls != 1 {
		t.Fatal("failed protected lookup did not fail closed")
	}
	for _, host := range []string{"printer.local", "router.home.arpa", "localhost", "10.0.0.1"} {
		if _, err := resolver.Lookup(context.Background(), host); err == nil {
			t.Fatal("local name leaked to public resolver")
		}
	}
}
