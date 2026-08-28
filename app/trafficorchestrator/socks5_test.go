package trafficorchestrator

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"testing"
	"time"
)

func TestDialLoopbackSOCKS5UsesDomainAndRelaysBytes(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan string, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		greeting := make([]byte, 3)
		_, _ = io.ReadFull(connection, greeting)
		_, _ = connection.Write([]byte{0x05, 0x00})
		header := make([]byte, 5)
		_, _ = io.ReadFull(connection, header)
		domain := make([]byte, int(header[4]))
		_, _ = io.ReadFull(connection, domain)
		port := make([]byte, 2)
		_, _ = io.ReadFull(connection, port)
		received <- string(domain) + ":" + strconv.Itoa(int(binary.BigEndian.Uint16(port)))
		_, _ = connection.Write([]byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 1})
		payload := make([]byte, 4)
		_, _ = io.ReadFull(connection, payload)
		_, _ = connection.Write(payload)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	connection, err := DialLoopbackSOCKS5(ctx, listener.Addr().String(), "gateway.discord.com:443")
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if err := writeFull(connection, []byte("ping")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err := io.ReadFull(connection, reply); err != nil || string(reply) != "ping" {
		t.Fatalf("relay reply = %q, err=%v", reply, err)
	}
	if got := <-received; got != "gateway.discord.com:443" {
		t.Fatalf("SOCKS destination = %q", got)
	}
}

func TestDialLoopbackSOCKS5RejectsRemoteProxy(t *testing.T) {
	if _, err := DialLoopbackSOCKS5(context.Background(), "192.0.2.1:1080", "example.com:443"); err == nil {
		t.Fatal("remote SOCKS endpoint was accepted")
	}
}

func TestEncodeSOCKSAddressRejectsOversizedDomain(t *testing.T) {
	domain := make([]byte, 256)
	for index := range domain {
		domain[index] = 'a'
	}
	if _, err := encodeSOCKSAddress(string(domain), 443); err == nil {
		t.Fatal("oversized SOCKS domain was accepted")
	}
}
