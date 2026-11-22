package dropoandroid

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	xcommon "github.com/xtls/xray-core/common"
	xbuf "github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	xudp "github.com/xtls/xray-core/common/protocol/udp"
	xcore "github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
)

// The pinned XUDP codec reserves 666 bytes in its 8 KiB buffer (plain VLESS
// UDP reserves two). Use the stricter 7,526-byte limit for every destination,
// rejecting larger payloads explicitly instead of either silent-drop path.
const maxXHTTPUDPPayload = xbuf.Size - 666

type xhttpUDPRay struct {
	link   *transport.Link
	cancel context.CancelFunc
}

// One bounded ray per full destination preserves DNS/QUIC target changes.
// Upstream's public UDP convenience dispatcher reuses the first destination,
// which is not valid for VLESS plain UDP when the first port is 53 or 443.
type xhttpUDPConn struct {
	ctx        context.Context
	cancel     context.CancelFunc
	dispatcher routing.Dispatcher
	packets    chan *xudp.Packet
	done       chan struct{}
	mu         sync.Mutex
	closed     bool
	writeMu    sync.Mutex
	rays       map[string]*xhttpUDPRay
	workers    sync.WaitGroup
}

func newXHTTPUDPConn(ctx context.Context, instance *xcore.Instance) (*xhttpUDPConn, error) {
	feature, ok := instance.GetFeature(routing.DispatcherType()).(routing.Dispatcher)
	if !ok {
		return nil, errors.New("Android XHTTP UDP dispatcher is unavailable")
	}
	ctx, cancel := context.WithCancel(ctx)
	return &xhttpUDPConn{ctx: ctx, cancel: cancel, dispatcher: feature, packets: make(chan *xudp.Packet, 16), done: make(chan struct{}), rays: make(map[string]*xhttpUDPRay)}, nil
}

func (c *xhttpUDPConn) ReadFrom(data []byte) (int, net.Addr, error) {
	select {
	case <-c.done:
		return 0, nil, io.EOF
	case <-c.ctx.Done():
		return 0, nil, c.ctx.Err()
	case packet := <-c.packets:
		defer packet.Payload.Release()
		source := M.ParseSocksaddrHostPort(packet.Source.Address.String(), uint16(packet.Source.Port))
		return copy(data, packet.Payload.Bytes()), source, nil
	}
}

func (c *xhttpUDPConn) readRay(ray *xhttpUDPRay, target xnet.Destination) {
	defer c.workers.Done()
	for {
		buffers, err := ray.link.Reader.ReadMultiBuffer()
		for _, buffer := range buffers {
			source := target
			if buffer.UDP != nil {
				source = *buffer.UDP
			}
			c.mu.Lock()
			if c.closed {
				buffer.Release()
			} else {
				select {
				case c.packets <- &xudp.Packet{Payload: buffer, Source: source}:
				default:
					buffer.Release()
				}
			}
			c.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (c *xhttpUDPConn) WriteTo(data []byte, address net.Addr) (int, error) {
	if len(data) == 0 || len(data) > maxXHTTPUDPPayload {
		return 0, errors.New("Android XHTTP UDP datagram exceeds the supported size")
	}
	destination := M.SocksaddrFromNet(address)
	if !destination.IsValid() || destination.Port == 0 {
		return 0, errors.New("Android XHTTP UDP destination is invalid")
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.ctx.Err() != nil {
		return 0, c.ctx.Err()
	}
	target := xnet.UDPDestination(xnet.ParseAddress(destination.AddrString()), xnet.Port(destination.Port))
	key := destination.String()
	ray := c.rays[key]
	if ray == nil {
		if len(c.rays) >= 64 {
			return 0, errors.New("Android XHTTP UDP association destination limit reached")
		}
		ctx, cancel := context.WithCancel(c.ctx)
		link, err := c.dispatcher.Dispatch(ctx, target)
		if err != nil {
			cancel()
			return 0, errors.New("Android XHTTP UDP dispatch failed")
		}
		ray = &xhttpUDPRay{link: link, cancel: cancel}
		c.rays[key] = ray
		c.workers.Add(1)
		go c.readRay(ray, target)
	}
	buffer := xbuf.New()
	if _, err := buffer.Write(data); err != nil {
		buffer.Release()
		return 0, err
	}
	buffer.UDP = &target
	// Xray's buf.Writer owns/releases the supplied multibuffer, including on
	// error. Unlike its UDP convenience API, dispatch failure is returned and no
	// allocated payload can be stranded before writer ownership is transferred.
	if err := ray.link.Writer.WriteMultiBuffer(xbuf.MultiBuffer{buffer}); err != nil {
		return 0, errors.New("Android XHTTP UDP write failed")
	}
	return len(data), nil
}

func (c *xhttpUDPConn) Close() error {
	// Cancel before waiting for WriteTo: HTTP request cancellation interrupts
	// blocked transport writes. The write lock fences creation against teardown.
	c.cancel()
	c.writeMu.Lock()
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		c.writeMu.Unlock()
		return nil
	}
	c.closed = true
	close(c.done)
	for len(c.packets) > 0 {
		(<-c.packets).Payload.Release()
	}
	c.mu.Unlock()
	for _, ray := range c.rays {
		ray.cancel()
		xcommon.Interrupt(ray.link.Reader)
		xcommon.Interrupt(ray.link.Writer)
	}
	c.rays = nil
	c.writeMu.Unlock()
	c.workers.Wait()
	return nil
}

func (*xhttpUDPConn) LocalAddr() net.Addr              { return &net.UDPAddr{IP: net.IPv4zero} }
func (*xhttpUDPConn) SetDeadline(time.Time) error      { return nil }
func (*xhttpUDPConn) SetReadDeadline(time.Time) error  { return nil }
func (*xhttpUDPConn) SetWriteDeadline(time.Time) error { return nil }
