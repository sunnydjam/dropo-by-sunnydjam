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

func TestLoopbackSOCKS5UDPAssociationRelaysDatagram(t *testing.T) {
	udpServer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer udpServer.Close()
	tcpServer, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcpServer.Close()
	destination := make(chan string, 1)
	go func() {
		connection, acceptErr := tcpServer.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		greeting := make([]byte, 3)
		_, _ = io.ReadFull(connection, greeting)
		_, _ = connection.Write([]byte{0x05, 0x00})
		request := make([]byte, 10)
		_, _ = io.ReadFull(connection, request)
		port := udpServer.LocalAddr().(*net.UDPAddr).Port
		reply := []byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0}
		binary.BigEndian.PutUint16(reply[8:10], uint16(port))
		_, _ = connection.Write(reply)
		_, _ = io.Copy(io.Discard, connection)
	}()
	go func() {
		buffer := make([]byte, 2048)
		length, peer, readErr := udpServer.ReadFromUDP(buffer)
		if readErr != nil || length < 8 || buffer[3] != 0x03 {
			return
		}
		domainLength := int(buffer[4])
		domain := string(buffer[5 : 5+domainLength])
		portOffset := 5 + domainLength
		port := binary.BigEndian.Uint16(buffer[portOffset : portOffset+2])
		destination <- net.JoinHostPort(domain, strconv.Itoa(int(port)))
		_, _ = udpServer.WriteToUDP(buffer[:length], peer)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	association, err := OpenLoopbackSOCKS5UDP(ctx, tcpServer.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer association.Close()
	if err := association.Send("gateway.discord.com", 50000, []byte("voice")); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 32)
	length, err := association.Receive(buffer)
	if err != nil || string(buffer[:length]) != "voice" {
		t.Fatalf("UDP reply = %q, err=%v", buffer[:length], err)
	}
	select {
	case got := <-destination:
		if got != "gateway.discord.com:50000" {
			t.Fatalf("SOCKS UDP destination = %q", got)
		}
	case <-ctx.Done():
		t.Fatal("SOCKS UDP server did not receive a datagram")
	}
}
