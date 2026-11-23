// Package dnspolicy defines the same bounded, encrypted bootstrap on both OSes.
package dnspolicy

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const Hostname = "dns.droponevedimka.ru"
const BootstrapIPv4 = "109.120.152.117"
const legacyBootstrapIPv4 = "193.233.88.97"
const QueryPath = "/dns-query"
const FinlandHostname = "dropo.fun"
const FinlandIPv4 = "77.42.65.119"
const LatviaHostname = "lv1.dropo.fun"
const LatviaIPv4 = "62.72.20.9"

var errNameNotFound = errors.New("public DNS name does not exist")

type Endpoint struct {
	Hostname string   `json:"hostname"`
	IPv4     []string `json:"ipCandidates"`
	Port     int      `json:"port"`
	Path     string   `json:"path"`
}
type Policy struct {
	Version     int        `json:"version"`
	PrivacyMode string     `json:"privacyMode"`
	Resolvers   []Endpoint `json:"resolvers"`
}

func Default() Policy {
	return Policy{Version: 1, PrivacyMode: "encrypted", Resolvers: []Endpoint{
		{Hostname: Hostname, IPv4: []string{BootstrapIPv4}, Port: 443, Path: QueryPath},
		{Hostname: FinlandHostname, IPv4: []string{FinlandIPv4}, Port: 443, Path: QueryPath},
		{Hostname: LatviaHostname, IPv4: []string{LatviaIPv4}, Port: 853},
	}}
}
func (p Policy) Validate() error {
	if p.Version != 1 || p.PrivacyMode != "encrypted" || len(p.Resolvers) < 1 || len(p.Resolvers) > 4 {
		return errors.New("unsupported DNS policy")
	}
	for _, e := range p.Resolvers {
		switch e.Hostname {
		case Hostname:
			if e.Port != 443 || e.Path != QueryPath {
				return errors.New("untrusted primary DNS transport")
			}
		case FinlandHostname:
			if e.Port != 443 || e.Path != QueryPath || len(e.IPv4) != 1 || e.IPv4[0] != FinlandIPv4 {
				return errors.New("untrusted Finnish DNS endpoint")
			}
		case LatviaHostname:
			if e.Port != 853 || e.Path != "" || len(e.IPv4) != 1 || e.IPv4[0] != LatviaIPv4 {
				return errors.New("untrusted Latvian DNS endpoint")
			}
		default:
			return errors.New("untrusted DNS endpoint")
		}
		if len(e.IPv4) < 1 || len(e.IPv4) > 8 {
			return errors.New("untrusted DNS endpoint")
		}
		for _, raw := range e.IPv4 {
			ip, err := netip.ParseAddr(raw)
			if err != nil || !ip.Is4() || !Public(ip) {
				return errors.New("invalid DNS bootstrap address")
			}
		}
	}
	return nil
}
func Public(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	for _, prefix := range []string{"0.0.0.0/8", "100.64.0.0/10", "198.18.0.0/15", "240.0.0.0/4", "2001:db8::/32"} {
		if netip.MustParsePrefix(prefix).Contains(ip) {
			return false
		}
	}
	return true
}

// Server pins only the connection address. TLS always verifies the DNS hostname.
func Server(tag string, throughVPN bool) map[string]interface{} {
	result := map[string]interface{}{"type": "https", "tag": tag, "server": BootstrapIPv4, "server_port": 443, "path": QueryPath, "tls": map[string]interface{}{"enabled": true, "server_name": Hostname}}
	if throughVPN {
		result["detour"] = "proxy"
	}
	return result
}

type DialContext func(context.Context, string, string) (net.Conn, error)
type Resolver struct {
	Policy Policy
	Dial   DialContext
	// TLS is supplied only for private test CAs. InsecureSkipVerify is rejected.
	TLS *tls.Config
}

func (r Resolver) Lookup(ctx context.Context, host string) ([]netip.Addr, error) {
	if err := r.Policy.Validate(); err != nil {
		return nil, err
	}
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	if ip, err := netip.ParseAddr(host); err == nil {
		if Public(ip) {
			return []netip.Addr{ip}, nil
		}
		return nil, errors.New("non-public lookup")
	}
	name, err := dnsmessage.NewName(host + ".")
	if err != nil || len(host) > 253 || !strings.Contains(host, ".") {
		return nil, errors.New("invalid public hostname")
	}
	for _, suffix := range []string{".local", ".internal", ".corp", ".lan", ".home", ".home.arpa", ".localhost", ".intranet", ".private"} {
		if strings.HasSuffix(host, suffix) {
			return nil, errors.New("local hostname needs local resolver")
		}
	}
	query := dnsmessage.Message{Header: dnsmessage.Header{ID: 0, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	wire, err := query.Pack()
	if err != nil {
		return nil, errors.New("DNS encoding failed")
	}
	remaining := 0
	for _, endpoint := range r.Policy.Resolvers {
		remaining += len(endpoint.IPv4)
	}
	for _, endpoint := range r.Policy.Resolvers {
		for _, ip := range endpoint.IPv4 {
			timeout := 2 * time.Second
			if deadline, bounded := ctx.Deadline(); bounded {
				timeout = min(timeout, time.Until(deadline)/time.Duration(remaining))
			}
			remaining--
			attempt, cancel := context.WithTimeout(ctx, timeout)
			addresses, err := r.exchange(attempt, endpoint, ip, wire, name)
			cancel()
			if err == nil && len(addresses) > 0 {
				return addresses, nil
			}
			if errors.Is(err, errNameNotFound) {
				return nil, err
			}
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
		}
	}
	return nil, errors.New("protected DNS unavailable")
}
func (r Resolver) exchange(ctx context.Context, e Endpoint, ip string, wire []byte, name dnsmessage.Name) ([]netip.Addr, error) {
	dial := r.Dial
	if dial == nil {
		dial = (&net.Dialer{Timeout: 4 * time.Second}).DialContext
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: e.Hostname}
	if r.TLS != nil {
		tlsConfig = r.TLS.Clone()
		tlsConfig.ServerName = e.Hostname
		if tlsConfig.InsecureSkipVerify {
			return nil, errors.New("TLS verification is required")
		}
	}
	address := net.JoinHostPort(ip, strconv.Itoa(e.Port))
	var body []byte
	var err error
	if e.Path == "" {
		body, err = exchangeTLS(ctx, dial, address, tlsConfig, wire)
	} else {
		body, err = exchangeHTTPS(ctx, dial, address, tlsConfig, e, wire)
	}
	if err != nil {
		return nil, err
	}
	return publicAddresses(body, name)
}

func exchangeTLS(ctx context.Context, dial DialContext, address string, config *tls.Config, wire []byte) ([]byte, error) {
	conn, err := dial(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	if err = conn.SetDeadline(deadline); err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	stream := tls.Client(conn, config)
	if err = stream.HandshakeContext(ctx); err != nil {
		return nil, err
	}
	frame := binary.BigEndian.AppendUint16(nil, uint16(len(wire)))
	if _, err = stream.Write(append(frame, wire...)); err != nil {
		return nil, err
	}
	var length [2]byte
	if _, err = io.ReadFull(stream, length[:]); err != nil {
		return nil, err
	}
	body := make([]byte, binary.BigEndian.Uint16(length[:]))
	_, err = io.ReadFull(stream, body)
	return body, err
}

func exchangeHTTPS(ctx context.Context, dial DialContext, address string, tlsConfig *tls.Config, e Endpoint, wire []byte) ([]byte, error) {
	transport := &http.Transport{Proxy: nil, ForceAttemptHTTP2: true, TLSClientConfig: tlsConfig, TLSHandshakeTimeout: 4 * time.Second, ResponseHeaderTimeout: 4 * time.Second, MaxConnsPerHost: 2, DisableKeepAlives: true, DialContext: func(c context.Context, n, _ string) (net.Conn, error) {
		return dial(c, "tcp", address)
	}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 6 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+e.Hostname+e.Path, bytes.NewReader(wire))
	if err != nil {
		return nil, errors.New("DNS request failed")
	}
	request.Header.Set("Content-Type", "application/dns-message")
	request.Header.Set("Accept", "application/dns-message")
	response, err := client.Do(request)
	if err != nil {
		return nil, errors.New("DNS transport failed")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 || strings.Split(response.Header.Get("Content-Type"), ";")[0] != "application/dns-message" {
		return nil, errors.New("invalid DNS HTTP response")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 65536))
	if err != nil || len(body) > 65535 {
		return nil, errors.New("invalid DNS response size")
	}
	return body, nil
}

func publicAddresses(body []byte, name dnsmessage.Name) ([]netip.Addr, error) {
	var message dnsmessage.Message
	if err := message.Unpack(body); err != nil || !message.Header.Response || message.Header.ID != 0 || message.Header.Truncated || len(message.Questions) != 1 || message.Questions[0].Name != name || message.Questions[0].Type != dnsmessage.TypeA || message.Questions[0].Class != dnsmessage.ClassINET {
		return nil, errors.New("invalid DNS response")
	}
	if message.Header.RCode == dnsmessage.RCodeNameError {
		return nil, errNameNotFound
	}
	if message.Header.RCode != dnsmessage.RCodeSuccess {
		return nil, errors.New("upstream DNS failed")
	}
	allowed := map[dnsmessage.Name]bool{name: true}
	for i := 0; i < 16; i++ {
		changed := false
		for _, answer := range message.Answers {
			if cname, ok := answer.Body.(*dnsmessage.CNAMEResource); ok && allowed[answer.Header.Name] && !allowed[cname.CNAME] {
				allowed[cname.CNAME] = true
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	var addresses []netip.Addr
	for _, answer := range message.Answers {
		if !allowed[answer.Header.Name] || answer.Header.Class != dnsmessage.ClassINET {
			continue
		}
		if record, ok := answer.Body.(*dnsmessage.AResource); ok {
			address := netip.AddrFrom4(record.A)
			if !Public(address) {
				return nil, errors.New("DNS rebinding answer rejected")
			}
			addresses = append(addresses, address)
		}
	}
	if len(addresses) == 0 {
		return nil, errors.New("DNS answer has no public IPv4")
	}
	return addresses, nil
}

func DefaultLookup(ctx context.Context, host string) ([]netip.Addr, error) {
	return (Resolver{Policy: Default()}).Lookup(ctx, host)
}
func JSON() string { body, _ := json.Marshal(Default()); return string(body) }
