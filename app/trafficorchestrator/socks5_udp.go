package trafficorchestrator

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

type SOCKS5UDPAssociation struct {
	control net.Conn
	udp     *net.UDPConn
	relay   *net.UDPAddr
}

func OpenLoopbackSOCKS5UDP(ctx context.Context, proxyAddress string) (*SOCKS5UDPAssociation, error) {
	if ctx == nil {
		return nil, errors.New("SOCKS context is required")
	}
	if err := validateLoopbackProxyAddress(proxyAddress); err != nil {
		return nil, err
	}
	control, err := (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddress)
	if err != nil {
		return nil, fmt.Errorf("connect local SOCKS UDP endpoint: %w", err)
	}
	stopCancellation := context.AfterFunc(ctx, func() {
		_ = control.Close()
	})
	defer stopCancellation()
	success := false
	defer func() {
		if !success {
			_ = control.Close()
		}
	}()
	deadline := time.Now().Add(socksHandshakeTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	_ = control.SetDeadline(deadline)
	if err := writeFull(control, []byte{0x05, 0x01, 0x00}); err != nil {
		return nil, err
	}
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(control, greeting); err != nil || greeting[0] != 0x05 || greeting[1] != 0x00 {
		return nil, errors.New("local SOCKS endpoint rejected UDP no-auth negotiation")
	}
	// UDP ASSOCIATE with an unspecified client endpoint.
	if err := writeFull(control, []byte{0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return nil, err
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(control, header); err != nil {
		return nil, err
	}
	if header[0] != 0x05 || header[1] != 0 || header[2] != 0 {
		return nil, fmt.Errorf("SOCKS UDP ASSOCIATE failed: %x", header)
	}
	host, port, err := readSOCKSAddress(control, header[3])
	if err != nil {
		return nil, err
	}
	proxyHost, _, _ := net.SplitHostPort(proxyAddress)
	if address, parseErr := netip.ParseAddr(strings.Trim(host, "[]")); parseErr == nil && address.IsUnspecified() {
		host = strings.Trim(proxyHost, "[]")
	}
	relay, err := net.ResolveUDPAddr("udp", net.JoinHostPort(host, strconv.Itoa(int(port))))
	if err != nil {
		return nil, fmt.Errorf("resolve SOCKS UDP relay: %w", err)
	}
	relayAddress, relayOK := netip.AddrFromSlice(relay.IP)
	if !relayOK || !relayAddress.Unmap().IsLoopback() {
		return nil, errors.New("SOCKS UDP relay must remain on loopback")
	}
	network := "udp4"
	if relay.IP.To4() == nil {
		network = "udp6"
	}
	udp, err := net.ListenUDP(network, nil)
	if err != nil {
		return nil, err
	}
	_ = control.SetDeadline(time.Time{})
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	success = true
	return &SOCKS5UDPAssociation{control: control, udp: udp, relay: relay}, nil
}

func (association *SOCKS5UDPAssociation) Send(host string, port uint16, payload []byte) error {
	if association == nil || association.udp == nil || association.relay == nil {
		return errors.New("SOCKS UDP association is closed")
	}
	address, err := encodeSOCKSAddress(host, port)
	if err != nil {
		return err
	}
	packet := make([]byte, 3, 3+len(address)+len(payload))
	packet = append(packet, address...)
	packet = append(packet, payload...)
	_, err = association.udp.WriteToUDP(packet, association.relay)
	return err
}

func (association *SOCKS5UDPAssociation) Receive(buffer []byte) (int, error) {
	if association == nil || association.udp == nil || len(buffer) == 0 {
		return 0, errors.New("SOCKS UDP association is closed or buffer is empty")
	}
	packet := make([]byte, len(buffer)+300)
	length, source, err := association.udp.ReadFromUDP(packet)
	if err != nil {
		return 0, err
	}
	if !udpAddressEqual(source, association.relay) || length < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
		return 0, errors.New("invalid SOCKS UDP datagram")
	}
	offset, err := socksAddressLength(packet[3:length])
	if err != nil {
		return 0, err
	}
	payloadOffset := 3 + offset
	if payloadOffset > length || length-payloadOffset > len(buffer) {
		return 0, errors.New("SOCKS UDP payload exceeds buffer")
	}
	copy(buffer, packet[payloadOffset:length])
	return length - payloadOffset, nil
}

func (association *SOCKS5UDPAssociation) Close() error {
	if association == nil {
		return nil
	}
	if association.control != nil {
		_ = association.control.Close()
	}
	if association.udp != nil {
		return association.udp.Close()
	}
	return nil
}

func readSOCKSAddress(reader io.Reader, addressType byte) (string, uint16, error) {
	length := 0
	switch addressType {
	case 0x01:
		length = 4
	case 0x04:
		length = 16
	case 0x03:
		size := []byte{0}
		if _, err := io.ReadFull(reader, size); err != nil || size[0] == 0 {
			return "", 0, errors.New("invalid SOCKS domain length")
		}
		length = int(size[0])
	default:
		return "", 0, fmt.Errorf("unsupported SOCKS address type 0x%02x", addressType)
	}
	value := make([]byte, length+2)
	if _, err := io.ReadFull(reader, value); err != nil {
		return "", 0, err
	}
	host := ""
	if addressType == 0x03 {
		host = string(value[:length])
	} else if address, ok := netip.AddrFromSlice(value[:length]); ok {
		host = address.String()
	}
	port := uint16(value[length])<<8 | uint16(value[length+1])
	if host == "" || port == 0 {
		return "", 0, errors.New("SOCKS relay returned an invalid address")
	}
	return host, port, nil
}

func socksAddressLength(value []byte) (int, error) {
	if len(value) < 1 {
		return 0, errors.New("SOCKS address is truncated")
	}
	length := 0
	switch value[0] {
	case 0x01:
		length = 1 + 4 + 2
	case 0x04:
		length = 1 + 16 + 2
	case 0x03:
		if len(value) < 2 || value[1] == 0 {
			return 0, errors.New("SOCKS domain is truncated")
		}
		length = 1 + 1 + int(value[1]) + 2
	default:
		return 0, errors.New("SOCKS address type is unsupported")
	}
	if len(value) < length {
		return 0, errors.New("SOCKS address is truncated")
	}
	return length, nil
}

func udpAddressEqual(left, right *net.UDPAddr) bool {
	if left == nil || right == nil || left.Port != right.Port {
		return false
	}
	leftAddr, leftOK := netip.AddrFromSlice(left.IP)
	rightAddr, rightOK := netip.AddrFromSlice(right.IP)
	return leftOK && rightOK && leftAddr.Unmap() == rightAddr.Unmap()
}
