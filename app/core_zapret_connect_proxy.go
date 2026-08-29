package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	traffic "dropo/trafficorchestrator"
)

const (
	zapretConnectSourcePortFirst = 20000
	zapretConnectSourcePortLast  = 21999
	maxZapretProxyHeaderBytes    = 32 * 1024
	maxZapretProxyResolvedIPs    = 16
	zapretPerAddressDialTimeout  = 1500 * time.Millisecond
)

var zapretConnectSourcePorts = traffic.PortRange{First: zapretConnectSourcePortFirst, Last: zapretConnectSourcePortLast}
var dropoFakeIPv4Prefix = netip.MustParsePrefix("198.18.0.0/15")

type zapretConnectServiceScope struct {
	exactHosts map[string]struct{}
	suffixes   []string
	ports      map[int]struct{}
}

type zapretConnectScope struct {
	directSuffixes []string
	services       []zapretConnectServiceScope
}

type zapretSourcePortPool struct {
	mu     sync.Mutex
	next   int
	active map[int]struct{}
}

type zapretResolvedTarget struct {
	addresses []netip.Addr
	expires   time.Time
}

type zapretConnectProxy struct {
	listener  net.Listener
	logger    func(string)
	scope     atomic.Pointer[zapretConnectScope]
	ports     zapretSourcePortPool
	resolveMu sync.Mutex
	resolved  map[string]zapretResolvedTarget

	mu       sync.Mutex
	closed   bool
	tracked  map[net.Conn]struct{}
	closeOne sync.Once
}

func startZapretConnectProxy(plan traffic.TrafficPlan, logger func(string)) (*zapretConnectProxy, error) {
	scope, err := compileZapretConnectScope(plan)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listen for scoped Zapret CONNECT proxy: %w", err)
	}
	proxy := &zapretConnectProxy{
		listener: listener,
		logger:   logger,
		ports: zapretSourcePortPool{
			next: zapretConnectSourcePortFirst, active: make(map[int]struct{}),
		},
		tracked: make(map[net.Conn]struct{}), resolved: make(map[string]zapretResolvedTarget),
	}
	proxy.scope.Store(scope)
	go proxy.acceptLoop()
	return proxy, nil
}

func (proxy *zapretConnectProxy) Address() string {
	if proxy == nil || proxy.listener == nil {
		return ""
	}
	return proxy.listener.Addr().String()
}

func (proxy *zapretConnectProxy) Update(plan traffic.TrafficPlan) error {
	if proxy == nil {
		return errors.New("Zapret CONNECT proxy is nil")
	}
	scope, err := compileZapretConnectScope(plan)
	if err != nil {
		return err
	}
	proxy.scope.Store(scope)
	return nil
}

func (proxy *zapretConnectProxy) Close() error {
	if proxy == nil {
		return nil
	}
	var closeErr error
	proxy.closeOne.Do(func() {
		proxy.mu.Lock()
		proxy.closed = true
		connections := make([]net.Conn, 0, len(proxy.tracked))
		for connection := range proxy.tracked {
			connections = append(connections, connection)
		}
		proxy.mu.Unlock()
		if proxy.listener != nil {
			if err := proxy.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
				closeErr = errors.Join(closeErr, err)
			}
		}
		for _, connection := range connections {
			_ = connection.Close()
		}
	})
	return closeErr
}

func (proxy *zapretConnectProxy) acceptLoop() {
	for {
		connection, err := proxy.listener.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) && proxy.logger != nil {
				proxy.logger("scoped Zapret CONNECT accept error: " + err.Error())
			}
			return
		}
		if !proxy.track(connection) {
			_ = connection.Close()
			return
		}
		go proxy.serveConnection(connection)
	}
}

func (proxy *zapretConnectProxy) serveConnection(client net.Conn) {
	defer func() {
		proxy.untrack(client)
		_ = client.Close()
	}()
	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	request, err := readBoundedConnectRequest(client)
	if err != nil {
		writeConnectProxyError(client, http.StatusBadRequest)
		return
	}
	if request.Method != http.MethodConnect {
		writeConnectProxyError(client, http.StatusMethodNotAllowed)
		return
	}
	host, port, target, err := parseConnectTarget(request.Host)
	if err != nil || !proxy.allows(host, port) {
		writeConnectProxyError(client, http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	upstream, err := proxy.dialScoped(ctx, host, port)
	cancel()
	if err != nil {
		writeConnectProxyError(client, http.StatusBadGateway)
		return
	}
	if !proxy.track(upstream) {
		_ = upstream.Close()
		return
	}
	defer func() {
		proxy.untrack(upstream)
		_ = upstream.Close()
	}()
	_ = client.SetDeadline(time.Time{})
	_ = upstream.SetDeadline(time.Time{})
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\nProxy-Agent: Dropo\r\n\r\n"); err != nil {
		return
	}
	_ = target // retained for diagnostics without logging user hostnames
	copyDone := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, client)
		copyDone <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		copyDone <- struct{}{}
	}()
	<-copyDone
}

func (proxy *zapretConnectProxy) allows(host string, port int) bool {
	scope := proxy.scope.Load()
	return scope != nil && scope.allows(host, port)
}

func (proxy *zapretConnectProxy) dialScoped(ctx context.Context, host string, port int) (net.Conn, error) {
	host = normalizeProxyHost(host)
	addresses, err := proxy.lookupPublicAddresses(ctx, host)
	if err != nil {
		return nil, err
	}
	if len(addresses) > maxZapretProxyResolvedIPs {
		addresses = addresses[:maxZapretProxyResolvedIPs]
	}
	var dialErr error
	eligibleAddresses := 0
	for _, address := range addresses {
		address = address.Unmap()
		if !zapretPublicAddress(address) {
			continue
		}
		eligibleAddresses++
		network := "tcp4"
		localIP := net.IPv4zero
		if address.Is6() {
			network = "tcp6"
			localIP = net.IPv6zero
		}
		for attempt := 0; attempt < 8; attempt++ {
			sourcePort, ok := proxy.ports.acquire()
			if !ok {
				return nil, errors.New("scoped Zapret source port pool is exhausted")
			}
			dialer := net.Dialer{
				Timeout: zapretPerAddressDialTimeout, KeepAlive: 30 * time.Second,
				LocalAddr: &net.TCPAddr{IP: localIP, Port: sourcePort},
			}
			connection, err := dialer.DialContext(ctx, network, net.JoinHostPort(address.String(), strconv.Itoa(port)))
			if err == nil {
				proxy.promoteResolvedAddress(host, address)
				return &zapretPortLeaseConn{Conn: connection, release: func() { proxy.ports.release(sourcePort) }}, nil
			}
			proxy.ports.release(sourcePort)
			dialErr = err
			if !addressInUseError(err) {
				break
			}
		}
	}
	if dialErr == nil {
		dialErr = errors.New("Zapret target did not resolve to a public address")
	} else {
		dialErr = fmt.Errorf("dial %d public Zapret address(es): %w", eligibleAddresses, dialErr)
	}
	return nil, dialErr
}

// dialRedirected is used only after FakeIPDirectory positively identifies an
// exact selected Zapret host. It reuses the same bounded source-port channel as
// PAC traffic so the one packet engine applies the selected strategy to the
// original native TLS bytes.
func (proxy *zapretConnectProxy) dialRedirected(ctx context.Context, target traffic.TCPRedirectTarget) (net.Conn, error) {
	if proxy == nil || target.Route != traffic.ServiceRouteZapret || target.Host == "" {
		return nil, errors.New("typed Zapret redirect target is required")
	}
	port := int(target.Flow.DestinationPort)
	if !proxy.allows(target.Host, port) {
		return nil, errors.New("Zapret redirect target is outside the selected service scope")
	}
	connection, err := proxy.dialScoped(ctx, target.Host, port)
	if err != nil {
		return nil, err
	}
	if !proxy.track(connection) {
		_ = connection.Close()
		return nil, errors.New("Zapret redirect proxy is closed")
	}
	return &zapretTrackedRelayConn{Conn: connection, proxy: proxy}, nil
}

func (proxy *zapretConnectProxy) lookupPublicAddresses(ctx context.Context, host string) ([]netip.Addr, error) {
	host = normalizeProxyHost(host)
	if host == "" {
		return nil, errors.New("Zapret target host is invalid")
	}
	now := time.Now()
	proxy.resolveMu.Lock()
	if cached, ok := proxy.resolved[host]; ok && now.Before(cached.expires) && len(cached.addresses) > 0 {
		addresses := append([]netip.Addr(nil), cached.addresses...)
		proxy.resolveMu.Unlock()
		return addresses, nil
	}
	proxy.resolveMu.Unlock()

	addresses, err := lookupPublicHostWithoutHosts(ctx, host)
	if err != nil {
		return nil, err
	}
	if len(addresses) > maxZapretProxyResolvedIPs {
		addresses = addresses[:maxZapretProxyResolvedIPs]
	}
	proxy.resolveMu.Lock()
	proxy.resolved[host] = zapretResolvedTarget{addresses: append([]netip.Addr(nil), addresses...), expires: now.Add(5 * time.Minute)}
	proxy.resolveMu.Unlock()
	return addresses, nil
}

func (proxy *zapretConnectProxy) promoteResolvedAddress(host string, address netip.Addr) {
	host = normalizeProxyHost(host)
	address = address.Unmap()
	if host == "" || !address.IsValid() {
		return
	}
	proxy.resolveMu.Lock()
	defer proxy.resolveMu.Unlock()
	cached, ok := proxy.resolved[host]
	if !ok || len(cached.addresses) < 2 {
		return
	}
	for index, candidate := range cached.addresses {
		if candidate.Unmap() != address || index == 0 {
			continue
		}
		copy(cached.addresses[1:index+1], cached.addresses[:index])
		cached.addresses[0] = candidate
		proxy.resolved[host] = cached
		return
	}
}

func (proxy *zapretConnectProxy) track(connection net.Conn) bool {
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	if proxy.closed {
		return false
	}
	proxy.tracked[connection] = struct{}{}
	return true
}

func (proxy *zapretConnectProxy) untrack(connection net.Conn) {
	proxy.mu.Lock()
	delete(proxy.tracked, connection)
	proxy.mu.Unlock()
}

type zapretPortLeaseConn struct {
	net.Conn
	release func()
	once    sync.Once
}

type zapretTrackedRelayConn struct {
	net.Conn
	proxy *zapretConnectProxy
	once  sync.Once
}

func (connection *zapretTrackedRelayConn) Close() error {
	err := connection.Conn.Close()
	connection.once.Do(func() { connection.proxy.untrack(connection.Conn) })
	return err
}

func (connection *zapretPortLeaseConn) Close() error {
	err := connection.Conn.Close()
	connection.once.Do(connection.release)
	return err
}

func (pool *zapretSourcePortPool) acquire() (int, bool) {
	pool.mu.Lock()
	defer pool.mu.Unlock()
	capacity := zapretConnectSourcePortLast - zapretConnectSourcePortFirst + 1
	for offset := 0; offset < capacity; offset++ {
		port := pool.next
		pool.next++
		if pool.next > zapretConnectSourcePortLast {
			pool.next = zapretConnectSourcePortFirst
		}
		if _, active := pool.active[port]; active {
			continue
		}
		pool.active[port] = struct{}{}
		return port, true
	}
	return 0, false
}

func (pool *zapretSourcePortPool) release(port int) {
	pool.mu.Lock()
	delete(pool.active, port)
	pool.mu.Unlock()
}

func compileZapretConnectScope(plan traffic.TrafficPlan) (*zapretConnectScope, error) {
	routes := make(map[string]traffic.ServiceRouteKind, len(plan.Routes))
	for _, route := range plan.Routes {
		routes[route.ServiceID] = route.Kind
	}
	scope := &zapretConnectScope{}
	for _, rule := range plan.DirectRules {
		for _, suffix := range rule.DomainSuffixes {
			if normalized := normalizeProxyHost(suffix); normalized != "" {
				scope.directSuffixes = append(scope.directSuffixes, normalized)
			}
		}
	}
	for _, service := range plan.Services {
		if routes[service.ID] != traffic.ServiceRouteZapret {
			continue
		}
		if len(service.TCPPorts) == 0 {
			return nil, fmt.Errorf("Zapret CONNECT service %q has no bounded TCP ports", service.ID)
		}
		compiled := zapretConnectServiceScope{
			exactHosts: make(map[string]struct{}, len(service.ExactHosts)),
			ports:      make(map[int]struct{}, len(service.TCPPorts)),
		}
		for _, host := range service.ExactHosts {
			if normalized := normalizeProxyHost(host); normalized != "" {
				compiled.exactHosts[normalized] = struct{}{}
			}
		}
		for _, suffix := range service.DomainSuffixes {
			if normalized := normalizeProxyHost(suffix); normalized != "" {
				compiled.suffixes = append(compiled.suffixes, normalized)
			}
		}
		for _, port := range service.TCPPorts {
			if port < 1 || port > 65535 {
				return nil, fmt.Errorf("Zapret CONNECT service %q has invalid TCP port %d", service.ID, port)
			}
			compiled.ports[port] = struct{}{}
		}
		if len(compiled.exactHosts)+len(compiled.suffixes) > 0 {
			scope.services = append(scope.services, compiled)
		}
	}
	return scope, nil
}

func (scope *zapretConnectScope) allows(host string, port int) bool {
	host = normalizeProxyHost(host)
	if host == "" || port < 1 || port > 65535 {
		return false
	}
	for _, suffix := range scope.directSuffixes {
		if proxyHostMatches(host, suffix) {
			return false
		}
	}
	for _, service := range scope.services {
		if _, allowed := service.ports[port]; !allowed {
			continue
		}
		if _, exact := service.exactHosts[host]; exact {
			return true
		}
		for _, suffix := range service.suffixes {
			if proxyHostMatches(host, suffix) {
				return true
			}
		}
	}
	return false
}

func readBoundedConnectRequest(connection net.Conn) (*http.Request, error) {
	reader := bufio.NewReaderSize(connection, 4096)
	var header bytes.Buffer
	for header.Len() <= maxZapretProxyHeaderBytes {
		line, err := reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		header.WriteString(line)
		if line == "\r\n" || line == "\n" {
			request, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(header.Bytes())))
			if err != nil {
				return nil, err
			}
			return request, nil
		}
	}
	return nil, errors.New("CONNECT header exceeds safe limit")
}

func parseConnectTarget(value string) (string, int, string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", 0, "", errors.New("CONNECT target is empty")
	}
	host, portText, err := net.SplitHostPort(value)
	if err != nil {
		host = value
		portText = "443"
	}
	host = normalizeProxyHost(host)
	port, err := strconv.Atoi(portText)
	if err != nil || host == "" || port < 1 || port > 65535 || net.ParseIP(host) != nil {
		return "", 0, "", errors.New("CONNECT target is invalid")
	}
	return host, port, net.JoinHostPort(host, strconv.Itoa(port)), nil
}

func normalizeProxyHost(value string) string {
	value = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
	value = strings.TrimPrefix(value, ".")
	if value == "" || len(value) > 253 || strings.ContainsAny(value, " /\\\t\r\n") {
		return ""
	}
	return value
}

func proxyHostMatches(host, suffix string) bool {
	return host == suffix || strings.HasSuffix(host, "."+suffix)
}

func zapretPublicAddress(address netip.Addr) bool {
	return address.IsValid() && address.IsGlobalUnicast() && !dropoFakeIPv4Prefix.Contains(address.Unmap()) && !address.IsPrivate() && !address.IsLoopback() && !address.IsLinkLocalUnicast() && !address.IsUnspecified() && !address.IsMulticast()
}

func addressInUseError(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "address already in use")
}

func writeConnectProxyError(connection net.Conn, status int) {
	text := http.StatusText(status)
	_, _ = io.WriteString(connection, fmt.Sprintf("HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", status, text))
}
