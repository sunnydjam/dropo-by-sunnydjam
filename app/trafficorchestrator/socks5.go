package trafficorchestrator

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

const socksHandshakeTimeout = 10 * time.Second

// DialLoopbackSOCKS5 opens one bounded CONNECT stream through the local
// sing-box mixed inbound. Remote proxy addresses and authentication negotiation
// are intentionally unsupported: the endpoint is Dropo-owned session state.
func DialLoopbackSOCKS5(ctx context.Context, proxyAddress, destination string) (net.Conn, error) {
	if ctx == nil {
		return nil, errors.New("SOCKS context is required")
	}
	if err := validateLoopbackProxyAddress(proxyAddress); err != nil {
		return nil, err
	}
	host, portText, err := net.SplitHostPort(destination)
	if err != nil {
		return nil, fmt.Errorf("parse SOCKS destination: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("SOCKS destination port is outside 1..65535")
	}
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	address, err := encodeSOCKSAddress(host, uint16(port))
	if err != nil {
		return nil, err
	}

	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddress)
	if err != nil {
		return nil, fmt.Errorf("connect local SOCKS endpoint: %w", err)
	}
	success := false
	defer func() {
		if !success {
			_ = connection.Close()
		}
	}()
	stopCancellation := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stopCancellation()
	deadline := time.Now().Add(socksHandshakeTimeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := connection.SetDeadline(deadline); err != nil {
		return nil, err
	}
	if err := writeFull(connection, []byte{0x05, 0x01, 0x00}); err != nil {
		return nil, fmt.Errorf("write SOCKS greeting: %w", err)
	}
	greeting := make([]byte, 2)
	if _, err := io.ReadFull(connection, greeting); err != nil {
		return nil, fmt.Errorf("read SOCKS greeting: %w", err)
	}
	if greeting[0] != 0x05 || greeting[1] != 0x00 {
		return nil, fmt.Errorf("local SOCKS endpoint rejected no-auth method: %x", greeting)
	}
	request := append([]byte{0x05, 0x01, 0x00}, address...)
	if err := writeFull(connection, request); err != nil {
		return nil, fmt.Errorf("write SOCKS CONNECT: %w", err)
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(connection, header); err != nil {
		return nil, fmt.Errorf("read SOCKS CONNECT response: %w", err)
	}
	if header[0] != 0x05 || header[2] != 0x00 {
		return nil, errors.New("invalid SOCKS CONNECT response")
	}
	if header[1] != 0x00 {
		return nil, fmt.Errorf("SOCKS CONNECT failed with status 0x%02x", header[1])
	}
	if err := discardSOCKSAddress(connection, header[3]); err != nil {
		return nil, err
	}
	if err := connection.SetDeadline(time.Time{}); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	success = true
	return connection, nil
}

func validateLoopbackProxyAddress(value string) error {
	host, portText, err := net.SplitHostPort(strings.TrimSpace(value))
	if err != nil {
		return fmt.Errorf("parse local SOCKS endpoint: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return errors.New("local SOCKS port is outside 1..65535")
	}
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	address, err := netip.ParseAddr(host)
	if err != nil || !address.IsLoopback() {
		return errors.New("SOCKS endpoint must be a numeric loopback address or localhost")
	}
	return nil
}

func encodeSOCKSAddress(host string, port uint16) ([]byte, error) {
	if host == "" || port == 0 {
		return nil, errors.New("SOCKS destination host and port are required")
	}
	result := make([]byte, 0, 1+1+255+2)
	if address, err := netip.ParseAddr(host); err == nil {
		if address.Is4() {
			value := address.As4()
			result = append(result, 0x01)
			result = append(result, value[:]...)
		} else {
			value := address.As16()
			result = append(result, 0x04)
			result = append(result, value[:]...)
		}
	} else {
		host = normalizeHost(host)
		if host == "" || len(host) > 255 {
			return nil, errors.New("SOCKS destination domain is invalid or too long")
		}
		result = append(result, 0x03, byte(len(host)))
		result = append(result, host...)
	}
	portBytes := [2]byte{}
	binary.BigEndian.PutUint16(portBytes[:], port)
	return append(result, portBytes[:]...), nil
}

func discardSOCKSAddress(reader io.Reader, addressType byte) error {
	length := 0
	switch addressType {
	case 0x01:
		length = 4
	case 0x04:
		length = 16
	case 0x03:
		size := []byte{0}
		if _, err := io.ReadFull(reader, size); err != nil {
			return fmt.Errorf("read SOCKS bound domain length: %w", err)
		}
		length = int(size[0])
	default:
		return fmt.Errorf("unsupported SOCKS bound address type 0x%02x", addressType)
	}
	buffer := make([]byte, length+2)
	if _, err := io.ReadFull(reader, buffer); err != nil {
		return fmt.Errorf("read SOCKS bound address: %w", err)
	}
	return nil
}

func writeFull(writer io.Writer, value []byte) error {
	for len(value) > 0 {
		written, err := writer.Write(value)
		if err != nil {
			return err
		}
		if written <= 0 || written > len(value) {
			return io.ErrShortWrite
		}
		value = value[written:]
	}
	return nil
}
