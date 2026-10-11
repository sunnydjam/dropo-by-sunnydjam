package dropoandroid

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	xlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

type xhttpSessionKey struct{}

type xhttpSocketSession struct {
	ctx                 context.Context
	cancel              context.CancelFunc
	protect             func(int32) error
	dnsServers          func() []string
	mu                  sync.Mutex
	closed              bool
	connections         map[io.Closer]struct{}
	physicalConnections map[io.Closer]struct{}
	networkGeneration   uint64
}

func newXHTTPSocketSession(protect func(int32) error, dnsServers func() []string) *xhttpSocketSession {
	ctx, cancel := context.WithCancel(context.Background())
	s := &xhttpSocketSession{cancel: cancel, protect: protect, dnsServers: dnsServers, connections: make(map[io.Closer]struct{}), physicalConnections: make(map[io.Closer]struct{})}
	s.ctx = context.WithValue(ctx, xhttpSessionKey{}, s)
	return s
}

func (s *xhttpSocketSession) track(c io.Closer) bool {
	s.mu.Lock()
	if s.closed || s.ctx.Err() != nil || len(s.connections) >= 512 {
		s.mu.Unlock()
		c.Close()
		return false
	}
	s.connections[c] = struct{}{}
	s.mu.Unlock()
	return true
}

func (s *xhttpSocketSession) untrack(c io.Closer) {
	s.mu.Lock()
	delete(s.connections, c)
	delete(s.physicalConnections, c)
	s.mu.Unlock()
}

func (s *xhttpSocketSession) physicalGeneration() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.networkGeneration
}
func (s *xhttpSocketSession) physicalCurrent(generation uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closed && s.networkGeneration == generation
}
func (s *xhttpSocketSession) trackPhysical(c io.Closer, generation uint64) bool {
	s.mu.Lock()
	if s.closed || s.networkGeneration != generation || len(s.connections) >= 512 {
		s.mu.Unlock()
		c.Close()
		return false
	}
	s.connections[c] = struct{}{}
	s.physicalConnections[c] = struct{}{}
	s.mu.Unlock()
	return true
}
func (s *xhttpSocketSession) resetPhysical() {
	s.mu.Lock()
	s.networkGeneration++
	connections := s.physicalConnections
	s.physicalConnections = make(map[io.Closer]struct{})
	s.mu.Unlock()
	for c := range connections {
		c.Close()
	}
}

func (s *xhttpSocketSession) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.cancel()
	connections := s.connections
	s.connections = make(map[io.Closer]struct{})
	s.mu.Unlock()
	for c := range connections {
		c.Close()
	}
}

type trackedXHTTPConn struct {
	net.Conn
	session *xhttpSocketSession
	once    sync.Once
}

type trackedXHTTPPacketConn struct {
	net.PacketConn
	session *xhttpSocketSession
	once    sync.Once
}

// Go's resolver selects datagram versus TCP DNS framing by the PacketConn
// interface, not just the network string. Preserve it on connected UDP DNS
// sockets while retaining the session's tracked, idempotent Close.
type trackedXHTTPDNSPacketConn struct {
	*trackedXHTTPConn
	packet net.PacketConn
}

func (c *trackedXHTTPDNSPacketConn) ReadFrom(data []byte) (int, net.Addr, error) {
	return c.packet.ReadFrom(data)
}
func (c *trackedXHTTPDNSPacketConn) WriteTo(data []byte, address net.Addr) (int, error) {
	return c.packet.WriteTo(data, address)
}

func (c *trackedXHTTPPacketConn) Close() (err error) {
	c.once.Do(func() { c.session.untrack(c); err = c.PacketConn.Close() })
	return
}

func (c *trackedXHTTPConn) Close() (err error) {
	c.once.Do(func() {
		c.session.untrack(c)
		err = c.Conn.Close()
	})
	return
}

type silentXHTTPLog struct{}

func (silentXHTTPLog) Handle(xlog.Message) {}

func init() {
	// Installed once, never swapped at Start/Stop. The Xray request context
	// carries the owning immutable session, so a stale request cannot acquire
	// the next session's protection callback or recreate a closed socket.
	internet.UseAlternativeSystemDialer(protectedXHTTPDialer{})
	xlog.RegisterHandler(silentXHTTPLog{})
}

type protectedXHTTPDialer struct{}

func (protectedXHTTPDialer) DestIpAddress() xnet.IP { return nil }

func (protectedXHTTPDialer) Dial(ctx context.Context, _ xnet.Address, destination xnet.Destination, _ *internet.SocketConfig) (net.Conn, error) {
	session, ok := ctx.Value(xhttpSessionKey{}).(*xhttpSocketSession)
	if !ok || session == nil || session.ctx.Err() != nil || session.protect == nil {
		return nil, errors.New("Android XHTTP session is not active")
	}
	generation := session.physicalGeneration()
	// Upstream XHTTP deliberately uses WithoutCancel for HTTP requests. Restore
	// session cancellation and bound physical connection establishment here.
	dialCtx, cancel := context.WithTimeout(ctx, 16*time.Second)
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	defer cancel()
	network := destination.Network.SystemString()
	if network != "tcp" && network != "udp" {
		return nil, errors.New("Android XHTTP socket network is unsupported")
	}
	control := func(_, _ string, raw syscall.RawConn) error {
		if session.ctx.Err() != nil || !session.physicalCurrent(generation) {
			return context.Canceled
		}
		var protectedErr error
		if err := raw.Control(func(fd uintptr) { protectedErr = session.protect(int32(fd)) }); err != nil {
			return errors.New("Android XHTTP socket control failed")
		}
		if protectedErr != nil {
			// Xray's default controller ignores callback errors. This custom
			// dialer returns the error BEFORE connect, preventing tunnel loops.
			return errors.New("Android XHTTP socket protection failed")
		}
		if !session.physicalCurrent(generation) {
			return context.Canceled
		}
		return session.ctx.Err()
	}
	dialer := net.Dialer{Control: control, Timeout: 16 * time.Second, KeepAlive: 45 * time.Second}
	if destination.Address.Family().IsDomain() {
		var dnsAttempt atomic.Uint64
		dialer.Resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, dnsNetwork, _ string) (net.Conn, error) {
			if session.dnsServers == nil {
				return nil, errors.New("Android XHTTP physical DNS is unavailable")
			}
			servers := session.dnsServers()
			if len(servers) == 0 {
				return nil, errors.New("Android XHTTP physical DNS is unavailable")
			}
			start := int(dnsAttempt.Add(1)-1) % len(servers)
			for i := 0; i < len(servers); i++ {
				server := servers[(start+i)%len(servers)]
				ip, err := netip.ParseAddr(server)
				if err != nil || ip.IsUnspecified() || ip.IsMulticast() {
					continue
				}
				resolverDialer := net.Dialer{Control: control, Timeout: 5 * time.Second}
				conn, err := resolverDialer.DialContext(ctx, dnsNetwork, net.JoinHostPort(ip.String(), "53"))
				if err == nil {
					tracked := &trackedXHTTPConn{Conn: conn, session: session}
					if !session.trackPhysical(tracked, generation) {
						return nil, context.Canceled
					}
					if packet, ok := conn.(net.PacketConn); ok {
						return &trackedXHTTPDNSPacketConn{trackedXHTTPConn: tracked, packet: packet}, nil
					}
					return tracked, nil
				}
			}
			return nil, errors.New("Android XHTTP physical DNS is unavailable")
		}}
	}
	if network == "udp" {
		var ip net.IP
		if destination.Address.Family().IsDomain() {
			addresses, err := dialer.Resolver.LookupNetIP(dialCtx, "ip", destination.Address.Domain())
			if err != nil || len(addresses) == 0 {
				return nil, errors.New("Android XHTTP physical DNS is unavailable")
			}
			ip = net.IP(addresses[0].AsSlice())
		} else {
			ip = destination.Address.IP()
		}
		listenAddress := "0.0.0.0:0"
		if ip.To4() == nil {
			listenAddress = "[::]:0"
		}
		listener := net.ListenConfig{Control: control}
		packet, err := listener.ListenPacket(dialCtx, "udp", listenAddress)
		if err != nil {
			return nil, errors.New("Android XHTTP physical connection failed")
		}
		tracked := &trackedXHTTPPacketConn{PacketConn: packet, session: session}
		if !session.trackPhysical(tracked, generation) {
			return nil, context.Canceled
		}
		// Preserve Xray's recognized packet wrapper for HTTP/3. Returning a
		// generic net.Conn would lose UDP peer identity inside its QUIC dialer.
		return &internet.PacketConnWrapper{PacketConn: tracked, Dest: &net.UDPAddr{IP: ip, Port: int(destination.Port)}}, nil
	}
	conn, err := dialer.DialContext(dialCtx, network, net.JoinHostPort(destination.Address.String(), strconv.Itoa(int(destination.Port))))
	if err != nil {
		return nil, errors.New("Android XHTTP physical connection failed")
	}
	tracked := &trackedXHTTPConn{Conn: conn, session: session}
	if !session.trackPhysical(tracked, generation) {
		return nil, context.Canceled
	}
	return tracked, nil
}

func physicalXHTTPDNSServers(platform PlatformInterface) []string {
	interfaces, err := platform.GetInterfaces()
	if err != nil || interfaces == nil {
		return nil
	}
	var servers []string
	for interfaces.HasNext() {
		item := interfaces.Next()
		if item == nil || item.Type != InterfaceTypeWIFI && item.Type != InterfaceTypeCellular && item.Type != InterfaceTypeEthernet {
			continue
		}
		servers = collectStrings(item.DNSServer)
		if len(servers) > 0 {
			return servers
		}
	}
	return servers
}
