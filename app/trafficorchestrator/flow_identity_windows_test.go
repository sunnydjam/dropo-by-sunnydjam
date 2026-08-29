//go:build windows

package trafficorchestrator

import (
	"encoding/binary"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseWindowsIPv4TCPOwnerTable(t *testing.T) {
	buffer := make([]byte, 4+24)
	binary.LittleEndian.PutUint32(buffer[:4], 1)
	row := buffer[4:]
	binary.LittleEndian.PutUint32(row[:4], 5)
	copy(row[4:8], netip.MustParseAddr("192.0.2.1").AsSlice())
	binary.BigEndian.PutUint16(row[8:10], 40000)
	copy(row[12:16], netip.MustParseAddr("203.0.113.9").AsSlice())
	binary.BigEndian.PutUint16(row[16:18], 443)
	binary.LittleEndian.PutUint32(row[20:24], 1234)
	owners, err := parseWindowsOwnerTable(buffer, ownerTableKind{network: NetworkTCP})
	if err != nil {
		t.Fatal(err)
	}
	tuple := FlowTuple{Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.1"), SourcePort: 40000, Destination: netip.MustParseAddr("203.0.113.9"), DestinationPort: 443}
	if owners[tuple] != 1234 {
		t.Fatalf("owner PID = %d, want 1234", owners[tuple])
	}
}

func TestWindowsFlowIdentityResolverFindsCurrentTCPProcess(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- connection
		}
		close(accepted)
	}()
	client, err := net.DialTimeout("tcp4", listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server := <-accepted
	if server == nil {
		t.Fatal("test TCP connection was not accepted")
	}
	defer server.Close()
	local := client.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := client.RemoteAddr().(*net.TCPAddr).AddrPort()
	tuple := FlowTuple{Network: NetworkTCP, Source: local.Addr().Unmap(), SourcePort: local.Port(), Destination: remote.Addr().Unmap(), DestinationPort: remote.Port()}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want := strings.ToLower(filepath.Base(executable))
	deadline := time.Now().Add(2 * time.Second)
	for {
		resolver := NewWindowsFlowIdentityResolver()
		if got := strings.ToLower(resolver.ResolveProcessName(tuple)); got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("TCP owner process was not resolved as %q", want)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestWindowsFlowIdentityResolverRefreshesFreshTableOnNewTCPMiss(t *testing.T) {
	now := time.Unix(100, 0)
	tuple := FlowTuple{
		Network: NetworkTCP, Source: netip.MustParseAddr("192.0.2.1"), SourcePort: 40000,
		Destination: netip.MustParseAddr("203.0.113.9"), DestinationPort: 443,
	}
	kind := ownerTableKind{network: NetworkTCP}
	loads := 0
	resolver := &windowsFlowIdentityResolver{
		now: func() time.Time { return now },
		loadTable: func(got ownerTableKind) (map[FlowTuple]uint32, error) {
			loads++
			if got != kind {
				t.Fatalf("owner table kind = %+v, want %+v", got, kind)
			}
			return map[FlowTuple]uint32{tuple: 77}, nil
		},
		processName: func(pid uint32) string {
			if pid != 77 {
				t.Fatalf("process PID = %d, want 77", pid)
			}
			return "Discord.exe"
		},
		tables: map[ownerTableKind]ownerTableSnapshot{
			kind: {loaded: now, owners: map[FlowTuple]uint32{}},
		},
		flows:     make(map[FlowTuple]cachedProcessIdentity),
		processes: make(map[uint32]cachedProcessIdentity),
	}
	if got := resolver.ResolveProcessName(tuple); got != "Discord.exe" {
		t.Fatalf("process name = %q, want Discord.exe", got)
	}
	if loads != 1 {
		t.Fatalf("owner table reloads = %d, want one bounded refresh", loads)
	}
}

func TestWindowsFlowIdentityResolverRefreshesFreshTableOnNewUDPMiss(t *testing.T) {
	now := time.Unix(101, 0)
	tuple := FlowTuple{
		Network: NetworkUDP, Source: netip.MustParseAddr("192.0.2.1"), SourcePort: 50001,
		Destination: netip.MustParseAddr("203.0.113.9"), DestinationPort: 50000,
	}
	kind := ownerTableKind{network: NetworkUDP}
	loads := 0
	resolver := &windowsFlowIdentityResolver{
		now: func() time.Time { return now },
		loadTable: func(got ownerTableKind) (map[FlowTuple]uint32, error) {
			loads++
			if got != kind {
				t.Fatalf("owner table kind = %+v, want %+v", got, kind)
			}
			return map[FlowTuple]uint32{ownerLookupTuple(tuple): 78}, nil
		},
		processName: func(pid uint32) string {
			if pid != 78 {
				t.Fatalf("process PID = %d, want 78", pid)
			}
			return "Discord.exe"
		},
		tables: map[ownerTableKind]ownerTableSnapshot{
			kind: {loaded: now, owners: map[FlowTuple]uint32{}},
		},
		flows: make(map[FlowTuple]cachedProcessIdentity), processes: make(map[uint32]cachedProcessIdentity),
	}
	if got := resolver.ResolveProcessName(tuple); got != "Discord.exe" {
		t.Fatalf("process name = %q, want Discord.exe", got)
	}
	if loads != 1 {
		t.Fatalf("owner table reloads = %d, want one bounded refresh", loads)
	}
}

func TestWindowsFlowIdentityResolverFindsCurrentUDPProcess(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	client, err := net.DialUDP("udp4", nil, server.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	local := client.LocalAddr().(*net.UDPAddr).AddrPort()
	remote := client.RemoteAddr().(*net.UDPAddr).AddrPort()
	tuple := FlowTuple{Network: NetworkUDP, Source: local.Addr().Unmap(), SourcePort: local.Port(), Destination: remote.Addr().Unmap(), DestinationPort: remote.Port()}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	want := strings.ToLower(filepath.Base(executable))
	deadline := time.Now().Add(2 * time.Second)
	for {
		resolver := NewWindowsFlowIdentityResolver()
		if got := strings.ToLower(resolver.ResolveProcessName(tuple)); got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("UDP owner process was not resolved as %q", want)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestParseWindowsUDPWildcardOwnerTables(t *testing.T) {
	ipv4 := make([]byte, 4+12)
	binary.LittleEndian.PutUint32(ipv4[:4], 1)
	binary.BigEndian.PutUint16(ipv4[8:10], 50000)
	binary.LittleEndian.PutUint32(ipv4[12:16], 4321)
	owners, err := parseWindowsOwnerTable(ipv4, ownerTableKind{network: NetworkUDP})
	if err != nil {
		t.Fatal(err)
	}
	key := FlowTuple{Network: NetworkUDP, Source: netip.IPv4Unspecified(), SourcePort: 50000}
	if owners[key] != 4321 {
		t.Fatalf("IPv4 UDP owner PID = %d, want 4321", owners[key])
	}

	ipv6 := make([]byte, 4+28)
	binary.LittleEndian.PutUint32(ipv6[:4], 1)
	binary.BigEndian.PutUint16(ipv6[24:26], 50001)
	binary.LittleEndian.PutUint32(ipv6[28:32], 8765)
	owners, err = parseWindowsOwnerTable(ipv6, ownerTableKind{network: NetworkUDP, ipv6: true})
	if err != nil {
		t.Fatal(err)
	}
	key = FlowTuple{Network: NetworkUDP, Source: netip.IPv6Unspecified(), SourcePort: 50001}
	if owners[key] != 8765 {
		t.Fatalf("IPv6 UDP owner PID = %d, want 8765", owners[key])
	}
}

func TestParseWindowsOwnerTableRejectsTruncatedRows(t *testing.T) {
	buffer := make([]byte, 10)
	binary.LittleEndian.PutUint32(buffer[:4], 2)
	if _, err := parseWindowsOwnerTable(buffer, ownerTableKind{network: NetworkTCP}); err == nil {
		t.Fatal("truncated owner table was accepted")
	}
}

func TestParseWindowsOwnerTableMarksSharedUDPEndpointAmbiguous(t *testing.T) {
	buffer := make([]byte, 4+2*12)
	binary.LittleEndian.PutUint32(buffer[:4], 2)
	for index, pid := range []uint32{100, 200} {
		row := buffer[4+index*12 : 4+(index+1)*12]
		copy(row[:4], netip.MustParseAddr("192.0.2.1").AsSlice())
		binary.BigEndian.PutUint16(row[4:6], 40000)
		binary.LittleEndian.PutUint32(row[8:12], pid)
	}
	owners, err := parseWindowsOwnerTable(buffer, ownerTableKind{network: NetworkUDP})
	if err != nil {
		t.Fatal(err)
	}
	key := FlowTuple{Network: NetworkUDP, Source: netip.MustParseAddr("192.0.2.1"), SourcePort: 40000}
	if owners[key] != 0 {
		t.Fatalf("ambiguous UDP endpoint owner PID = %d, want unknown", owners[key])
	}
}
