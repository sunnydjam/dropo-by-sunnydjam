package dropoandroid

import (
	"context"
	"crypto/tls"
	"dropocore/dnspolicy"
	"encoding/json"
	"encoding/pem"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/miekg/dns"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	singjson "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
)

func TestPinnedRuntimeDNSFailsOverOnTLSFailureAndSERVFAIL(t *testing.T) {
	var directAtProtected atomic.Bool
	doh := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wire, err := io.ReadAll(r.Body)
		var query dns.Msg
		if err != nil || query.Unpack(wire) != nil || len(query.Question) != 1 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if query.Question[0].Name == "game.direct.test." {
			directAtProtected.Store(true)
		}
		code := dns.RcodeServerFailure
		if strings.HasPrefix(query.Question[0].Name, "missing.") {
			code = dns.RcodeNameError
		}
		answer := new(dns.Msg).SetRcode(&query, code)
		body, _ := answer.Pack()
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(body)
	}))
	doh.Config.ErrorLog = log.New(io.Discard, "", 0)
	doh.StartTLS()
	defer doh.Close()
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: doh.TLS.Certificates})
	if err != nil {
		t.Fatal(err)
	}
	var workingAtDoT, missingAtDoT atomic.Bool
	dot := &dns.Server{Listener: listener, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, query *dns.Msg) {
		if len(query.Question) != 1 {
			return
		}
		switch query.Question[0].Name {
		case "game.direct.test.":
			directAtProtected.Store(true)
		case "working.example.com.":
			workingAtDoT.Store(true)
		case "missing.example.com.":
			missingAtDoT.Store(true)
		}
		answer := new(dns.Msg).SetReply(query)
		answer.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: query.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.IPv4(93, 184, 215, 14)}}
		w.WriteMsg(answer)
	})}
	go dot.ActivateAndServe()
	t.Cleanup(func() { dot.Shutdown(); listener.Close() })
	const tag = "dns-remote"
	// This local UDP server stands in for the physical network DNS. It sees
	// only the direct control name. Test builders separately enforce type local.
	networkDNS, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var protectedAtDirect, sawDirect atomic.Bool
	system := &dns.Server{PacketConn: networkDNS, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, q *dns.Msg) {
		if len(q.Question) != 1 {
			return
		}
		if q.Question[0].Name == "game.direct.test." {
			sawDirect.Store(true)
		} else {
			protectedAtDirect.Store(true)
		}
		a := new(dns.Msg).SetReply(q)
		a.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: q.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30}, A: net.IPv4(192, 0, 2, 7)}}
		_ = w.WriteMsg(a)
	})}
	go system.ActivateAndServe()
	t.Cleanup(func() { system.Shutdown(); networkDNS.Close() })
	config := map[string]interface{}{
		"servers": []any{dnspolicy.Server(tag, false), map[string]any{"type": "udp", "tag": "dns-direct", "server": "127.0.0.1", "server_port": networkDNS.LocalAddr().(*net.UDPAddr).Port}},
		"rules":   []any{map[string]any{"domain_suffix": []string{"example.com"}, "action": "route", "server": tag}}, "final": "dns-direct",
	}
	dnspolicy.ConfigureRuntimeFailover(config)
	certificate := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: doh.Certificate().Raw}))
	for _, item := range config["servers"].([]interface{}) {
		server := item.(map[string]interface{})
		if server["tag"] == "dns-direct" {
			continue
		}
		server["server"] = "127.0.0.1"
		tlsOptions := server["tls"].(map[string]interface{})
		tlsOptions["server_name"] = "127.0.0.1"
		tlsOptions["certificate"] = []string{certificate}
		switch server["tag"] {
		case tag + "-fi":
			// Both DoH transports use the local listener. The first resolver fails because
			// its trusted identity deliberately does not match the certificate.
			server["server_port"] = doh.Listener.Addr().(*net.TCPAddr).Port
			tlsOptions["server_name"] = "wrong.invalid"
		case tag:
			server["server_port"] = doh.Listener.Addr().(*net.TCPAddr).Port
		case tag + "-lv":
			server["server_port"] = listener.Addr().(*net.TCPAddr).Port
		}
	}
	data, err := json.Marshal(map[string]interface{}{"log": map[string]interface{}{"disabled": true}, "dns": config})
	if err != nil {
		t.Fatal(err)
	}
	ctx := include.Context(service.ContextWithDefaultRegistry(context.Background()))
	options, err := singjson.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		t.Fatal(err)
	}
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	router := service.FromContext[adapter.DNSRouter](ctx)
	queryCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	for _, want := range []struct {
		name string
		code int
	}{{"missing.example.com.", dns.RcodeNameError}, {"working.example.com.", dns.RcodeSuccess}, {"game.direct.test.", dns.RcodeSuccess}} {
		query := new(dns.Msg).SetQuestion(want.name, dns.TypeA)
		answer, err := router.Exchange(queryCtx, query, adapter.DNSQueryOptions{})
		if err != nil || answer == nil || answer.Rcode != want.code || want.code == dns.RcodeSuccess && len(answer.Answer) != 1 {
			t.Fatalf("%s: want DNS status %d, got %v, %v", want.name, want.code, answer, err)
		}
	}
	if !sawDirect.Load() || directAtProtected.Load() || protectedAtDirect.Load() {
		t.Fatal("DNS reached a resolver outside the service policy")
	}
	if !workingAtDoT.Load() || missingAtDoT.Load() {
		t.Fatal("DoT must see the failed DoH lookup and must not retry NXDOMAIN")
	}
}
