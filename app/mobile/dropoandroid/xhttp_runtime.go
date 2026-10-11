package dropoandroid

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/varbin"
	"github.com/sagernet/sing/protocol/socks/socks5"
	xbuf "github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/internet/splithttp"
)

var liveXHTTPBridges = struct {
	sync.Mutex
	items   map[*xhttpBridge]struct{}
	epoch   uint64
	enabled bool
}{items: make(map[*xhttpBridge]struct{}), epoch: 1, enabled: true}

var androidRuntimeLifecycleMu sync.Mutex

func currentXHTTPEpoch() uint64 {
	liveXHTTPBridges.Lock()
	defer liveXHTTPBridges.Unlock()
	if !liveXHTTPBridges.enabled {
		return 0
	}
	return liveXHTTPBridges.epoch
}
func xHTTPEpochCurrent(epoch uint64) bool {
	liveXHTTPBridges.Lock()
	defer liveXHTTPBridges.Unlock()
	return epoch != 0 && liveXHTTPBridges.enabled && liveXHTTPBridges.epoch == epoch
}
func rearmXHTTPRuntime() {
	liveXHTTPBridges.Lock()
	defer liveXHTTPBridges.Unlock()
	if !liveXHTTPBridges.enabled {
		liveXHTTPBridges.epoch++
		liveXHTTPBridges.enabled = true
	}
}

func registerXHTTPBridge(bridge *xhttpBridge, epoch uint64) bool {
	liveXHTTPBridges.Lock()
	defer liveXHTTPBridges.Unlock()
	if !liveXHTTPBridges.enabled || liveXHTTPBridges.epoch != epoch {
		return false
	}
	bridge.workers.Add(1)
	liveXHTTPBridges.items[bridge] = struct{}{}
	return true
}

func shutdownXHTTPInstances() {
	liveXHTTPBridges.Lock()
	liveXHTTPBridges.enabled = false
	liveXHTTPBridges.epoch++
	bridges := make([]*xhttpBridge, 0, len(liveXHTTPBridges.items))
	for bridge := range liveXHTTPBridges.items {
		bridges = append(bridges, bridge)
	}
	liveXHTTPBridges.Unlock()
	for _, bridge := range bridges {
		bridge.close()
	}
}

type xhttpBridge struct {
	instance           *xcore.Instance
	session            *xhttpSocketSession
	listener           net.Listener
	username, password string
	workers            sync.WaitGroup
	slots              chan struct{}
	managedSession     *splithttp.ManagedSession
	stopOnce           sync.Once
	lifecycleMu        sync.Mutex
}

func newXHTTPBridge(config *xcore.Config, protect func(int32) error, dnsServers func() []string, ownerEpochs ...uint64) (*xhttpBridge, error) {
	epoch := currentXHTTPEpoch()
	if len(ownerEpochs) > 0 {
		epoch = ownerEpochs[0]
	}
	if !xHTTPEpochCurrent(epoch) {
		return nil, errors.New("Android XHTTP runtime session was cancelled")
	}
	session := newXHTTPSocketSession(protect, dnsServers)
	managed := splithttp.NewManagedSession(session.ctx)
	session.ctx = splithttp.ContextWithManagedSession(session.ctx, managed)
	instance, err := xcore.NewWithContext(session.ctx, config)
	if err != nil {
		managed.Close()
		session.close()
		return nil, errXHTTPConfig
	}
	if err = instance.Start(); err != nil {
		managed.Close()
		session.close()
		instance.Close()
		return nil, errors.New("Android XHTTP runtime could not start")
	}
	failed := true
	defer func() {
		if failed {
			managed.Close()
			session.close()
			instance.Close()
		}
	}()
	credentials := make([]byte, 32)
	if _, err = rand.Read(credentials); err != nil {
		return nil, errors.New("Android XHTTP local authentication failed")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("Android XHTTP local transport is unavailable")
	}
	bridge := &xhttpBridge{
		instance: instance, listener: listener,
		session: session, managedSession: managed,
		username: hex.EncodeToString(credentials[:16]), password: hex.EncodeToString(credentials[16:]),
		slots: make(chan struct{}, 256),
	}
	if !registerXHTTPBridge(bridge, epoch) {
		listener.Close()
		return nil, errors.New("Android XHTTP runtime session was cancelled")
	}
	go bridge.accept()
	failed = false
	return bridge, nil
}

func (b *xhttpBridge) close() {
	b.stop()
	b.workers.Wait()
}

func (b *xhttpBridge) stop() {
	b.stopOnce.Do(func() {
		b.lifecycleMu.Lock()
		defer b.lifecycleMu.Unlock()
		b.listener.Close()
		b.managedSession.Close()
		b.session.close()
		b.instance.Close()
		liveXHTTPBridges.Lock()
		delete(liveXHTTPBridges.items, b)
		liveXHTTPBridges.Unlock()
	})
}

func (b *xhttpBridge) resetNetwork() {
	b.lifecycleMu.Lock()
	defer b.lifecycleMu.Unlock()
	if b.session.ctx.Err() != nil {
		return
	}
	b.managedSession.ResetNetwork()
	b.session.resetPhysical()
}

func (b *xhttpBridge) accept() {
	defer b.workers.Done()
	for {
		conn, err := b.listener.Accept()
		if err != nil {
			return
		}
		if !b.session.track(conn) {
			continue
		}
		select {
		case b.slots <- struct{}{}:
			b.workers.Add(1)
			go func() {
				defer b.workers.Done()
				defer func() { <-b.slots; b.session.untrack(conn); conn.Close() }()
				b.handle(conn)
			}()
		default:
			b.session.untrack(conn)
			conn.Close()
		}
	}
}

func (b *xhttpBridge) handle(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(6 * time.Second))
	reader := varbin.StubReader(conn)
	auth, err := socks5.ReadAuthRequest(reader)
	if err != nil {
		return
	}
	accepted := false
	for _, method := range auth.Methods {
		accepted = accepted || method == socks5.AuthTypeUsernamePassword
	}
	if !accepted {
		socks5.WriteAuthResponse(conn, socks5.AuthResponse{Method: socks5.AuthTypeNoAcceptedMethods})
		return
	}
	if socks5.WriteAuthResponse(conn, socks5.AuthResponse{Method: socks5.AuthTypeUsernamePassword}) != nil {
		return
	}
	credentials, err := socks5.ReadUsernamePasswordAuthRequest(reader)
	if err != nil {
		return
	}
	if subtle.ConstantTimeCompare([]byte(credentials.Username), []byte(b.username)) != 1 || subtle.ConstantTimeCompare([]byte(credentials.Password), []byte(b.password)) != 1 {
		socks5.WriteUsernamePasswordAuthResponse(conn, socks5.UsernamePasswordAuthResponse{Status: socks5.UsernamePasswordStatusFailure})
		return
	}
	if socks5.WriteUsernamePasswordAuthResponse(conn, socks5.UsernamePasswordAuthResponse{Status: socks5.UsernamePasswordStatusSuccess}) != nil {
		return
	}
	request, err := socks5.ReadRequest(reader)
	if err != nil {
		return
	}
	conn.SetDeadline(time.Time{})
	switch request.Command {
	case socks5.CommandConnect:
		if !request.Destination.IsValid() || request.Destination.Port == 0 {
			return
		}
		connection, err := xcore.Dial(b.session.ctx, b.instance, xnet.TCPDestination(xnet.ParseAddress(request.Destination.AddrString()), xnet.Port(request.Destination.Port)))
		if err != nil {
			socks5.WriteResponse(conn, socks5.Response{ReplyCode: socks5.ReplyCodeFailure})
			return
		}
		remote := &trackedXHTTPConn{Conn: connection, session: b.session}
		if !b.session.track(remote) {
			return
		}
		defer func() { b.session.untrack(remote); remote.Close() }()
		if socks5.WriteResponse(conn, socks5.Response{ReplyCode: socks5.ReplyCodeSuccess, Bind: M.SocksaddrFromNet(b.listener.Addr())}) != nil {
			return
		}
		done := make(chan struct{})
		go func() { io.Copy(remote, conn); remote.Close(); conn.Close(); close(done) }()
		io.Copy(conn, remote)
		remote.Close()
		conn.Close()
		<-done
	case socks5.CommandUDPAssociate:
		b.handleUDP(conn, request.Destination)
	default:
		socks5.WriteResponse(conn, socks5.Response{ReplyCode: socks5.ReplyCodeUnsupported})
	}
}

// Each authenticated association gets its own atomically reserved loopback
// UDP port. The first local sender is pinned; unrelated packets and SOCKS
// fragments are dropped. Closing its control connection tears down both
// directions and its Xray dispatch, without relying on Xray's no-op deadlines.
func (b *xhttpBridge) handleUDP(control net.Conn, expected M.Socksaddr) {
	local, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return
	}
	if !b.session.track(local) {
		return
	}
	defer func() { b.session.untrack(local); local.Close() }()
	ctx, cancel := context.WithCancel(b.session.ctx)
	defer cancel()
	remote, err := newXHTTPUDPConn(ctx, b.instance)
	if err != nil {
		return
	}
	if !b.session.track(remote) {
		return
	}
	defer func() { b.session.untrack(remote); remote.Close() }()
	if socks5.WriteResponse(control, socks5.Response{ReplyCode: socks5.ReplyCodeSuccess, Bind: M.SocksaddrFromNet(local.LocalAddr())}) != nil {
		return
	}
	var endpointMu sync.Mutex
	var endpoint net.Addr
	if expected.Port != 0 {
		// SOCKS clients that know their UDP endpoint get strict source binding.
		// A zero-address request otherwise pins its first loopback datagram.
		if expected.IsDomain() || !expected.Addr.IsLoopback() {
			return
		}
		endpoint = expected.UDPAddr()
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		data := make([]byte, xbuf.Size+512)
		for {
			n, source, err := remote.ReadFrom(data[512:])
			if err != nil {
				local.Close()
				control.Close()
				return
			}
			endpointMu.Lock()
			peer := endpoint
			endpointMu.Unlock()
			if peer == nil {
				continue
			}
			packet := buf.NewSize(n + 512)
			packet.WriteZeroN(3)
			if M.SocksaddrSerializer.WriteAddrPort(packet, M.SocksaddrFromNet(source)) == nil {
				packet.Write(data[512 : 512+n])
				local.WriteTo(packet.Bytes(), peer)
			}
			packet.Release()
		}
	}()
	controlDone := make(chan struct{})
	go func() { io.Copy(io.Discard, control); cancel(); local.Close(); remote.Close(); close(controlDone) }()
	data := make([]byte, xbuf.Size+512)
	for {
		local.SetReadDeadline(time.Now().Add(2 * time.Minute))
		n, source, err := local.ReadFrom(data)
		if err != nil {
			break
		}
		if address, ok := source.(*net.UDPAddr); !ok || !address.IP.IsLoopback() {
			continue
		}
		if n < 4 || data[0] != 0 || data[1] != 0 || data[2] != 0 {
			continue
		}
		reader := bytes.NewReader(data[3:n])
		destination, err := M.SocksaddrSerializer.ReadAddrPort(reader)
		if err != nil || !destination.IsValid() || destination.Port == 0 || reader.Len() > maxXHTTPUDPPayload {
			continue
		}
		endpointMu.Lock()
		if endpoint == nil {
			endpoint = source
		}
		matches := endpoint.String() == source.String()
		endpointMu.Unlock()
		if !matches {
			continue
		}
		_, err = remote.WriteTo(data[n-reader.Len():n], destination)
		if err != nil {
			break
		}
	}
	cancel()
	remote.Close()
	local.Close()
	control.Close()
	<-controlDone
	<-done
}

type xhttpRuntime struct{ bridges []*xhttpBridge }

func (r *xhttpRuntime) close() {
	if r != nil {
		for _, bridge := range r.bridges {
			bridge.close()
		}
	}
}
func (r *xhttpRuntime) stop() {
	if r != nil {
		for _, bridge := range r.bridges {
			bridge.stop()
		}
	}
}

func (r *xhttpRuntime) resetNetwork() {
	if r != nil {
		for _, bridge := range r.bridges {
			bridge.resetNetwork()
		}
	}
}

// CheckConfig and Start use exactly the same normalization/validation. Check
// only builds protobuf and substitutes a syntactic localhost SOCKS endpoint:
// it never instantiates Xray, reserves a port, or reaches the network.
func normalizeXHTTPConfig(content string, platform PlatformInterface, start bool, ownerEpochs ...uint64) (string, *xhttpRuntime, error) {
	var config map[string]json.RawMessage
	if json.Unmarshal([]byte(content), &config) != nil {
		return "", nil, errXHTTPConfig
	}
	var outbounds []json.RawMessage
	if json.Unmarshal(config["outbounds"], &outbounds) != nil {
		return content, nil, nil
	}
	runtime := &xhttpRuntime{}
	failed := true
	defer func() {
		if failed {
			runtime.close()
		}
	}()
	var roots []string
	count := 0
	for i, raw := range outbounds {
		var placeholder struct {
			Type         string          `json:"type"`
			Tag          string          `json:"tag"`
			XrayOutbound json.RawMessage `json:"xray_outbound"`
		}
		if json.Unmarshal(raw, &placeholder) != nil || placeholder.Type != xhttpOutboundType {
			continue
		}
		count++
		if count > 64 || placeholder.Tag == "" {
			return "", nil, errXHTTPConfig
		}
		if start {
			if platform == nil || !platform.UsePlatformAutoDetectInterfaceControl() {
				return "", nil, errors.New("Android XHTTP socket protection is unavailable")
			}
			if roots == nil {
				roots = collectStrings(platform.SystemCertificates())
			}
			if len(roots) == 0 {
				return "", nil, errors.New("Android XHTTP certificate store is unavailable")
			}
		}
		built, err := buildXHTTPConfig(placeholder.XrayOutbound, roots)
		if err != nil {
			return "", nil, err
		}
		port, username, password := 1, "dropo-check", "dropo-check"
		if start {
			bridge, err := newXHTTPBridge(built, platform.AutoDetectInterfaceControl, func() []string { return physicalXHTTPDNSServers(platform) }, ownerEpochs...)
			if err != nil {
				return "", nil, err
			}
			runtime.bridges = append(runtime.bridges, bridge)
			port = bridge.listener.Addr().(*net.TCPAddr).Port
			username, password = bridge.username, bridge.password
		}
		outbounds[i], _ = json.Marshal(map[string]any{"type": "socks", "tag": placeholder.Tag, "server": "127.0.0.1", "server_port": port, "version": "5", "username": username, "password": password, "network": []string{"tcp", "udp"}})
	}
	config["outbounds"], _ = json.Marshal(outbounds)
	encoded, err := json.Marshal(config)
	if err != nil {
		return "", nil, errXHTTPConfig
	}
	failed = false
	return string(encoded), runtime, nil
}
