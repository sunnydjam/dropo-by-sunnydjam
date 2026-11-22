package trafficorchestrator

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

const maxConcurrentUDPRelays = 128

type udpRelaySession struct {
	key    udpRedirectKey
	target UDPRedirectTarget
	peer   *net.UDPAddr
	input  chan []byte
}

type UDPRelay struct {
	listener *net.UDPConn
	registry *UDPRedirectRegistry
	proxy    string
	logger   func(string)
	ctx      context.Context
	cancel   context.CancelFunc
	mu       sync.Mutex
	sessions map[udpRedirectKey]*udpRelaySession
	wg       sync.WaitGroup
	once     sync.Once
}

func StartUDPRelay(registry *UDPRedirectRegistry, proxyAddress string, port int, logger func(string)) (*UDPRelay, error) {
	if registry == nil || port < 1 || port > 65535 {
		return nil, errors.New("UDP redirect registry and relay port are required")
	}
	if err := validateLoopbackProxyAddress(proxyAddress); err != nil {
		return nil, err
	}
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: port})
	if err != nil {
		return nil, fmt.Errorf("listen UDP redirect relay: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	relay := &UDPRelay{
		listener: listener, registry: registry, proxy: proxyAddress, logger: logger,
		ctx: ctx, cancel: cancel, sessions: make(map[udpRedirectKey]*udpRelaySession),
	}
	relay.wg.Add(1)
	go relay.readLoop()
	return relay, nil
}

func (relay *UDPRelay) Close() error {
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

func (relay *UDPRelay) readLoop() {
	defer relay.wg.Done()
	buffer := make([]byte, 65535)
	for {
		length, peer, err := relay.listener.ReadFromUDP(buffer)
		if err != nil {
			if relay.ctx.Err() == nil {
				relay.log("read failed: " + err.Error())
			}
			return
		}
		target, ok := relay.registry.ResolvePeer(peer)
		if !ok || length == 0 {
			continue
		}
		key := udpRedirectKey{remoteIP: target.Flow.Destination.Unmap(), clientPort: target.Flow.SourcePort}
		session := relay.session(key, target, peer)
		if session == nil {
			continue
		}
		payload := append([]byte(nil), buffer[:length]...)
		select {
		case session.input <- payload:
		default:
			relay.log("datagram dropped: per-flow queue is full")
		}
	}
}

func (relay *UDPRelay) session(key udpRedirectKey, target UDPRedirectTarget, peer *net.UDPAddr) *udpRelaySession {
	relay.mu.Lock()
	defer relay.mu.Unlock()
	if session := relay.sessions[key]; session != nil {
		if sameUDPRedirectIdentity(session.target, target) {
			return session
		}
		return nil
	}
	if len(relay.sessions) >= maxConcurrentUDPRelays {
		relay.log("datagram rejected: UDP relay session limit reached")
		return nil
	}
	session := &udpRelaySession{
		key: key, target: target,
		peer:  &net.UDPAddr{IP: append(net.IP(nil), peer.IP...), Port: peer.Port, Zone: peer.Zone},
		input: make(chan []byte, 32),
	}
	relay.sessions[key] = session
	relay.wg.Add(1)
	go relay.runSession(session)
	return session
}

func (relay *UDPRelay) runSession(session *udpRelaySession) {
	defer relay.wg.Done()
	defer func() {
		relay.mu.Lock()
		if relay.sessions[session.key] == session {
			delete(relay.sessions, session.key)
		}
		relay.mu.Unlock()
	}()
	association, err := OpenLoopbackSOCKS5UDP(relay.ctx, relay.proxy)
	if err != nil {
		relay.log(fmt.Sprintf("service=%s UDP associate failed: %v", session.target.ServiceID, err))
		return
	}
	defer association.Close()
	responses := make(chan []byte, 8)
	receiveErrors := make(chan error, 1)
	receiveDone := make(chan struct{})
	defer close(receiveDone)
	go func() {
		buffer := make([]byte, 65535)
		for {
			length, receiveErr := association.Receive(buffer)
			if receiveErr != nil {
				select {
				case receiveErrors <- receiveErr:
				case <-receiveDone:
				}
				return
			}
			payload := append([]byte(nil), buffer[:length]...)
			select {
			case responses <- payload:
			case <-receiveDone:
				return
			}
		}
	}()
	idle := time.NewTimer(udpRedirectTTL)
	defer idle.Stop()
	host := session.target.Host
	if host == "" {
		host = session.target.Flow.Destination.String()
	}
	port := session.target.Flow.DestinationPort
	for {
		select {
		case payload := <-session.input:
			if !idle.Stop() {
				select {
				case <-idle.C:
				default:
				}
			}
			idle.Reset(udpRedirectTTL)
			if err := association.Send(host, port, payload); err != nil {
				relay.log(fmt.Sprintf("service=%s UDP send failed: %v", session.target.ServiceID, err))
				return
			}
		case payload := <-responses:
			if _, err := relay.listener.WriteToUDP(payload, session.peer); err != nil && relay.ctx.Err() == nil {
				relay.log(fmt.Sprintf("service=%s UDP response failed: %v", session.target.ServiceID, err))
				return
			}
		case err := <-receiveErrors:
			if relay.ctx.Err() == nil && !errors.Is(err, net.ErrClosed) {
				relay.log(fmt.Sprintf("service=%s UDP receive failed: %v", session.target.ServiceID, err))
			}
			return
		case <-idle.C:
			return
		case <-relay.ctx.Done():
			return
		}
	}
}

func (relay *UDPRelay) log(message string) {
	if relay != nil && relay.logger != nil {
		relay.logger("[UDPRelay] " + message)
	}
}
