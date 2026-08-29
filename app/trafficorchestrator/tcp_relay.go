package trafficorchestrator

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"time"
)

const (
	maxPendingTCPRedirects = 4096
	maxActiveTCPRedirects  = 4096
	tcpRedirectPendingTTL  = 15 * time.Second
	tcpRedirectActiveTTL   = 10 * time.Minute
	maxConcurrentTCPRelays = 128
)

// TCPRedirectTarget is immutable metadata registered before a reflected SYN is
// injected. The accepted relay peer encodes Destination.Addr plus the original
// client source port, following WinDivert's documented stream reflection model.
type TCPRedirectTarget struct {
	Flow      FlowTuple
	Host      string
	ServiceID string
	Route     ServiceRouteKind
}

// TCPRelayDialer chooses the terminal path from already validated, immutable
// redirect metadata. It is intentionally typed so the relay cannot execute or
// compose an external strategy command.
type TCPRelayDialer func(context.Context, TCPRedirectTarget) (net.Conn, error)

type tcpRedirectKey struct {
	localIP          netip.Addr
	originalRemoteIP netip.Addr
	clientPort       uint16
}

type pendingTCPRedirect struct {
	target  TCPRedirectTarget
	expires time.Time
}

type TCPRedirectRegistry struct {
	mu      sync.Mutex
	now     func() time.Time
	pending map[tcpRedirectKey]pendingTCPRedirect
	active  map[tcpRedirectKey]pendingTCPRedirect
}

func NewTCPRedirectRegistry() *TCPRedirectRegistry {
	return &TCPRedirectRegistry{
		now: time.Now, pending: make(map[tcpRedirectKey]pendingTCPRedirect), active: make(map[tcpRedirectKey]pendingTCPRedirect),
	}
}

func (registry *TCPRedirectRegistry) Register(target TCPRedirectTarget) error {
	if registry == nil || !target.Flow.valid() || target.Flow.Network != NetworkTCP {
		return errors.New("valid TCP redirect flow is required")
	}
	if (target.Route != ServiceRouteVPN && target.Route != ServiceRouteZapret) || target.ServiceID == "" {
		return errors.New("TCP redirect target must be a named VPN or Zapret service")
	}
	if target.Host != "" && normalizeHost(target.Host) == "" {
		return errors.New("TCP redirect host is invalid")
	}
	key := tcpRedirectKey{
		localIP:          target.Flow.Source.Unmap(),
		originalRemoteIP: target.Flow.Destination.Unmap(),
		clientPort:       target.Flow.SourcePort,
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	target.Host = normalizeHost(target.Host)
	if existing, ok := registry.active[key]; ok {
		if sameTCPRedirectIdentity(existing.target, target) {
			return nil
		}
		return errors.New("active TCP redirect tuple belongs to a different target")
	}
	if existing, ok := registry.pending[key]; ok {
		if sameTCPRedirectIdentity(existing.target, target) {
			return nil
		}
		return errors.New("TCP redirect tuple already belongs to a different target")
	}
	if len(registry.pending) >= maxPendingTCPRedirects {
		return errors.New("TCP redirect registry is full")
	}
	registry.pending[key] = pendingTCPRedirect{target: target, expires: now.Add(tcpRedirectPendingTTL)}
	return nil
}

func sameTCPRedirectIdentity(left, right TCPRedirectTarget) bool {
	// Host is evidence recovered after the TCP handshake. It cannot change the
	// already reflected destination tuple and is not registry ownership.
	return left.Flow == right.Flow && left.ServiceID == right.ServiceID && left.Route == right.Route
}

func (registry *TCPRedirectRegistry) contains(target TCPRedirectTarget) bool {
	if registry == nil || !target.Flow.valid() || target.Flow.Network != NetworkTCP {
		return false
	}
	key := tcpRedirectKey{
		localIP:          target.Flow.Source.Unmap(),
		originalRemoteIP: target.Flow.Destination.Unmap(),
		clientPort:       target.Flow.SourcePort,
	}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	if entry, ok := registry.active[key]; ok {
		return sameTCPRedirectIdentity(entry.target, target)
	}
	if entry, ok := registry.pending[key]; ok {
		return sameTCPRedirectIdentity(entry.target, target)
	}
	return false
}

// ConsumeAccepted resolves one reflected connection exactly once. A normal LAN
// connection to the listener has no matching registration and is rejected.
func (registry *TCPRedirectRegistry) ConsumeAccepted(local, remote net.Addr) (TCPRedirectTarget, bool) {
	if registry == nil {
		return TCPRedirectTarget{}, false
	}
	localTCP, localOK := local.(*net.TCPAddr)
	remoteTCP, remoteOK := remote.(*net.TCPAddr)
	if !localOK || !remoteOK || localTCP.Port < 1 || remoteTCP.Port < 1 {
		return TCPRedirectTarget{}, false
	}
	localAddr, localOK := netip.AddrFromSlice(localTCP.IP)
	remoteAddr, remoteOK := netip.AddrFromSlice(remoteTCP.IP)
	if !localOK || !remoteOK {
		return TCPRedirectTarget{}, false
	}
	key := tcpRedirectKey{localIP: localAddr.Unmap(), originalRemoteIP: remoteAddr.Unmap(), clientPort: uint16(remoteTCP.Port)}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	entry, ok := registry.pending[key]
	if !ok {
		return TCPRedirectTarget{}, false
	}
	delete(registry.pending, key)
	if len(registry.active) >= maxActiveTCPRedirects {
		return TCPRedirectTarget{}, false
	}
	entry.expires = now.Add(tcpRedirectActiveTTL)
	registry.active[key] = entry
	return entry.target, true
}

func (registry *TCPRedirectRegistry) lookupReflected(localIP, originalRemoteIP netip.Addr, clientPort uint16) (TCPRedirectTarget, bool) {
	if registry == nil || !localIP.IsValid() || !originalRemoteIP.IsValid() || clientPort == 0 {
		return TCPRedirectTarget{}, false
	}
	key := tcpRedirectKey{localIP: localIP.Unmap(), originalRemoteIP: originalRemoteIP.Unmap(), clientPort: clientPort}
	registry.mu.Lock()
	defer registry.mu.Unlock()
	now := registry.now()
	registry.pruneLocked(now)
	entry, ok := registry.active[key]
	if ok {
		entry.expires = now.Add(tcpRedirectActiveTTL)
		registry.active[key] = entry
		return entry.target, true
	}
	// The listener emits SYN-ACK before Accept can promote the flow to active.
	// A short-lived pending lookup is required to complete that handshake.
	entry, ok = registry.pending[key]
	if !ok {
		return TCPRedirectTarget{}, false
	}
	entry.expires = now.Add(tcpRedirectPendingTTL)
	registry.pending[key] = entry
	return entry.target, true
}

func (registry *TCPRedirectRegistry) pruneLocked(now time.Time) {
	for key, entry := range registry.pending {
		if !now.Before(entry.expires) {
			delete(registry.pending, key)
		}
	}
	for key, entry := range registry.active {
		if !now.Before(entry.expires) {
			delete(registry.active, key)
		}
	}
}

// TCPRelay accepts only reflected, pre-registered flows and forwards each one
// through its bounded typed terminal dialer. It does not own WinDivert.
type TCPRelay struct {
	listener net.Listener
	registry *TCPRedirectRegistry
	dialer   TCPRelayDialer
	logger   func(string)
	ctx      context.Context
	cancel   context.CancelFunc
	sem      chan struct{}
	wg       sync.WaitGroup
	once     sync.Once
}

func StartTCPRelay(registry *TCPRedirectRegistry, proxyAddress string, logger func(string)) (*TCPRelay, error) {
	if registry == nil {
		return nil, errors.New("TCP redirect registry is required")
	}
	if err := validateLoopbackProxyAddress(proxyAddress); err != nil {
		return nil, err
	}
	return StartTCPRelayWithDialer(registry, func(ctx context.Context, target TCPRedirectTarget) (net.Conn, error) {
		host := target.Host
		if host == "" {
			host = target.Flow.Destination.String()
		}
		destination := net.JoinHostPort(host, strconv.Itoa(int(target.Flow.DestinationPort)))
		return DialLoopbackSOCKS5(ctx, proxyAddress, destination)
	}, logger)
}

// StartTCPRelayWithDialer starts the same pre-registered reflection relay with
// an in-process terminal selector. The caller must reject every unsupported
// route; no implicit direct fallback is performed here.
func StartTCPRelayWithDialer(registry *TCPRedirectRegistry, dialer TCPRelayDialer, logger func(string)) (*TCPRelay, error) {
	if registry == nil {
		return nil, errors.New("TCP redirect registry is required")
	}
	if dialer == nil {
		return nil, errors.New("TCP relay dialer is required")
	}
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		return nil, fmt.Errorf("listen TCP redirect relay: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	relay := &TCPRelay{
		listener: listener, registry: registry, dialer: dialer, logger: logger,
		ctx: ctx, cancel: cancel, sem: make(chan struct{}, maxConcurrentTCPRelays),
	}
	relay.wg.Add(1)
	go relay.acceptLoop()
	return relay, nil
}

func (relay *TCPRelay) Port() int {
	if relay == nil || relay.listener == nil {
		return 0
	}
	if address, ok := relay.listener.Addr().(*net.TCPAddr); ok {
		return address.Port
	}
	return 0
}

func (relay *TCPRelay) Close() error {
	if relay == nil {
		return nil
	}
	var closeErr error
	relay.once.Do(func() {
		relay.cancel()
		closeErr = relay.listener.Close()
		relay.wg.Wait()
	})
	return closeErr
}

func (relay *TCPRelay) acceptLoop() {
	defer relay.wg.Done()
	for {
		connection, err := relay.listener.Accept()
		if err != nil {
			if relay.ctx.Err() == nil {
				relay.log("accept failed: " + err.Error())
			}
			return
		}
		target, ok := relay.registry.ConsumeAccepted(connection.LocalAddr(), connection.RemoteAddr())
		if !ok {
			_ = connection.Close()
			continue
		}
		select {
		case relay.sem <- struct{}{}:
			relay.wg.Add(1)
			go func() {
				defer relay.wg.Done()
				defer func() { <-relay.sem }()
				if err := relayTCPConnection(relay.ctx, connection, target, relay.dialer); err != nil && relay.ctx.Err() == nil {
					relay.log(fmt.Sprintf("service=%s destination=%s failed: %v", target.ServiceID, target.Flow.Destination, err))
				}
			}()
		default:
			_ = connection.Close()
			relay.log("connection rejected: relay concurrency limit reached")
		}
	}
}

func relayTCPConnection(ctx context.Context, client net.Conn, target TCPRedirectTarget, dialer TCPRelayDialer) error {
	defer client.Close()
	upstream, err := dialer(ctx, target)
	if err != nil {
		return err
	}
	defer upstream.Close()
	errorsChannel := make(chan error, 2)
	copyStream := func(destination, source net.Conn) {
		_, copyErr := io.Copy(destination, source)
		if tcp, ok := destination.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		errorsChannel <- copyErr
	}
	go copyStream(upstream, client)
	go copyStream(client, upstream)
	for completed := 0; completed < 2; completed++ {
		select {
		case err := <-errorsChannel:
			if err != nil && !errors.Is(err, net.ErrClosed) {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

func (relay *TCPRelay) log(message string) {
	if relay != nil && relay.logger != nil {
		relay.logger("[TCPRelay] " + message)
	}
}
