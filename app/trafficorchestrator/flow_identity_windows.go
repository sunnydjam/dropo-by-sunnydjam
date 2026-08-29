//go:build windows

package trafficorchestrator

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	ownerTableRefreshInterval = 250 * time.Millisecond
	flowIdentityTTL           = 30 * time.Second
	missingFlowIdentityTTL    = 500 * time.Millisecond
	processIdentityTTL        = 5 * time.Second
	missingProcessIdentityTTL = time.Second
	maxOwnerTableBytes        = 16 * 1024 * 1024
	maxOwnerTableEntries      = 32768
	maxFlowIdentityEntries    = 4096
	maxProcessIdentityEntries = 512

	tcpTableOwnerPIDAll = 5
	udpTableOwnerPID    = 1
)

var (
	flowIdentityIPHelper    = windows.NewLazySystemDLL("iphlpapi.dll")
	flowIdentityGetTCPTable = flowIdentityIPHelper.NewProc("GetExtendedTcpTable")
	flowIdentityGetUDPTable = flowIdentityIPHelper.NewProc("GetExtendedUdpTable")
)

type ownerTableKind struct {
	network Network
	ipv6    bool
}

type ownerTableSnapshot struct {
	loaded time.Time
	owners map[FlowTuple]uint32
}

type cachedProcessIdentity struct {
	name    string
	expires time.Time
}

// windowsFlowIdentityResolver is bounded and fail-safe. It refreshes at most
// four small owner-table snapshots (TCP/UDP x IPv4/IPv6), caches only process
// basenames, and treats every API/permission/race failure as unknown traffic.
type windowsFlowIdentityResolver struct {
	mu          sync.Mutex
	now         func() time.Time
	loadTable   func(ownerTableKind) (map[FlowTuple]uint32, error)
	processName func(uint32) string
	tables      map[ownerTableKind]ownerTableSnapshot
	flows       map[FlowTuple]cachedProcessIdentity
	processes   map[uint32]cachedProcessIdentity
}

// NewWindowsFlowIdentityResolver returns the production resolver used by the
// single in-process Windows traffic engine.
func NewWindowsFlowIdentityResolver() FlowIdentityResolver {
	return &windowsFlowIdentityResolver{
		now:         time.Now,
		loadTable:   loadWindowsOwnerTable,
		processName: windowsProcessName,
		tables:      make(map[ownerTableKind]ownerTableSnapshot, 4),
		flows:       make(map[FlowTuple]cachedProcessIdentity),
		processes:   make(map[uint32]cachedProcessIdentity),
	}
}

func (resolver *windowsFlowIdentityResolver) ResolveProcessName(tuple FlowTuple) string {
	if resolver == nil || !tuple.valid() {
		return ""
	}
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	now := resolver.now()
	if cached, ok := resolver.flows[tuple]; ok && now.Before(cached.expires) {
		return cached.name
	}

	kind := ownerTableKind{network: tuple.Network, ipv6: tuple.Source.Is6()}
	table := resolver.tables[kind]
	refreshed := false
	if table.owners == nil || now.Sub(table.loaded) >= ownerTableRefreshInterval {
		owners, err := resolver.loadOwnerTable(kind)
		if err != nil {
			resolver.cacheFlow(tuple, "", now.Add(missingFlowIdentityTTL))
			return ""
		}
		table = ownerTableSnapshot{loaded: now, owners: owners}
		resolver.tables[kind] = table
		refreshed = true
	}

	pid := ownerPID(table.owners, tuple)
	// A just-created TCP or UDP flow may not exist in a still-valid owner-table
	// snapshot. TCP needs its initial SYN for selective relay setup, while a
	// Discord voice discovery exchange may contain only a few UDP datagrams.
	// Refresh once immediately for either transport. This is bounded, does not
	// sleep, and a second miss still passes unchanged.
	if pid == 0 && (tuple.Network == NetworkTCP || tuple.Network == NetworkUDP) && !refreshed {
		owners, err := resolver.loadOwnerTable(kind)
		if err == nil {
			table = ownerTableSnapshot{loaded: now, owners: owners}
			resolver.tables[kind] = table
			pid = ownerPID(table.owners, tuple)
		}
	}
	if pid == 0 {
		resolver.cacheFlow(tuple, "", now.Add(missingFlowIdentityTTL))
		return ""
	}
	if cached, ok := resolver.processes[pid]; ok && now.Before(cached.expires) {
		resolver.cacheFlow(tuple, cached.name, now.Add(flowIdentityTTL))
		return cached.name
	}

	name := resolver.resolveProcessName(pid)
	processExpiry := now.Add(processIdentityTTL)
	flowExpiry := now.Add(flowIdentityTTL)
	if name == "" {
		processExpiry = now.Add(missingProcessIdentityTTL)
		flowExpiry = now.Add(missingFlowIdentityTTL)
	}
	resolver.cacheProcess(pid, name, processExpiry)
	resolver.cacheFlow(tuple, name, flowExpiry)
	return name
}

func (resolver *windowsFlowIdentityResolver) loadOwnerTable(kind ownerTableKind) (map[FlowTuple]uint32, error) {
	if resolver.loadTable != nil {
		return resolver.loadTable(kind)
	}
	return loadWindowsOwnerTable(kind)
}

func (resolver *windowsFlowIdentityResolver) resolveProcessName(pid uint32) string {
	if resolver.processName != nil {
		return resolver.processName(pid)
	}
	return windowsProcessName(pid)
}

func ownerPID(owners map[FlowTuple]uint32, tuple FlowTuple) uint32 {
	pid := owners[ownerLookupTuple(tuple)]
	if pid == 0 && tuple.Network == NetworkUDP {
		pid = owners[ownerWildcardTuple(tuple)]
	}
	return pid
}

func (resolver *windowsFlowIdentityResolver) cacheFlow(tuple FlowTuple, name string, expires time.Time) {
	if len(resolver.flows) >= maxFlowIdentityEntries {
		clear(resolver.flows)
	}
	resolver.flows[tuple] = cachedProcessIdentity{name: name, expires: expires}
}

func (resolver *windowsFlowIdentityResolver) cacheProcess(pid uint32, name string, expires time.Time) {
	if len(resolver.processes) >= maxProcessIdentityEntries {
		clear(resolver.processes)
	}
	resolver.processes[pid] = cachedProcessIdentity{name: name, expires: expires}
}

func ownerLookupTuple(tuple FlowTuple) FlowTuple {
	if tuple.Network == NetworkUDP {
		tuple.Destination = netip.Addr{}
		tuple.DestinationPort = 0
	}
	return tuple
}

func ownerWildcardTuple(tuple FlowTuple) FlowTuple {
	tuple = ownerLookupTuple(tuple)
	if tuple.Source.Is4() {
		tuple.Source = netip.IPv4Unspecified()
	} else {
		tuple.Source = netip.IPv6Unspecified()
	}
	return tuple
}

func loadWindowsOwnerTable(kind ownerTableKind) (map[FlowTuple]uint32, error) {
	proc := flowIdentityGetTCPTable
	tableClass := uintptr(tcpTableOwnerPIDAll)
	if kind.network == NetworkUDP {
		proc = flowIdentityGetUDPTable
		tableClass = udpTableOwnerPID
	}
	af := uintptr(windows.AF_INET)
	if kind.ipv6 {
		af = windows.AF_INET6
	}
	var size uint32
	result, _, _ := proc.Call(0, uintptr(unsafe.Pointer(&size)), 0, af, tableClass, 0)
	if result != 0 && result != uintptr(windows.ERROR_INSUFFICIENT_BUFFER) {
		return nil, syscall.Errno(result)
	}
	if size < 4 || size > maxOwnerTableBytes {
		return nil, errors.New("Windows owner table size is outside the safe limit")
	}
	buffer := make([]byte, size)
	result, _, _ = proc.Call(uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)), 0, af, tableClass, 0)
	if result != 0 {
		return nil, syscall.Errno(result)
	}
	if size < 4 || int(size) > len(buffer) {
		return nil, errors.New("Windows owner table returned an invalid size")
	}
	return parseWindowsOwnerTable(buffer[:size], kind)
}

func parseWindowsOwnerTable(buffer []byte, kind ownerTableKind) (map[FlowTuple]uint32, error) {
	if len(buffer) < 4 {
		return nil, errors.New("truncated Windows owner table")
	}
	count := int(binary.LittleEndian.Uint32(buffer[:4]))
	if count < 0 || count > maxOwnerTableEntries {
		return nil, errors.New("Windows owner table entry count is outside the safe limit")
	}
	rowSize := ownerRowSize(kind)
	if rowSize == 0 || count > (len(buffer)-4)/rowSize {
		return nil, errors.New("truncated Windows owner table rows")
	}
	owners := make(map[FlowTuple]uint32, count)
	for index := 0; index < count; index++ {
		row := buffer[4+index*rowSize : 4+(index+1)*rowSize]
		tuple, pid, ok := parseWindowsOwnerRow(row, kind)
		if ok && pid != 0 {
			if existing, exists := owners[tuple]; !exists {
				owners[tuple] = pid
			} else if existing != pid {
				// Reused UDP endpoints are weak evidence. Preserve ambiguity even
				// if a later row happens to repeat one of the earlier PIDs.
				owners[tuple] = 0
			}
		}
	}
	return owners, nil
}

func ownerRowSize(kind ownerTableKind) int {
	switch {
	case kind.network == NetworkTCP && !kind.ipv6:
		return 24
	case kind.network == NetworkUDP && !kind.ipv6:
		return 12
	case kind.network == NetworkTCP && kind.ipv6:
		return 56
	case kind.network == NetworkUDP && kind.ipv6:
		return 28
	default:
		return 0
	}
}

func parseWindowsOwnerRow(row []byte, kind ownerTableKind) (FlowTuple, uint32, bool) {
	if len(row) != ownerRowSize(kind) {
		return FlowTuple{}, 0, false
	}
	if !kind.ipv6 {
		if kind.network == NetworkUDP {
			local := netip.AddrFrom4([4]byte(row[:4]))
			return FlowTuple{Network: NetworkUDP, Source: local, SourcePort: binary.BigEndian.Uint16(row[4:6])}, binary.LittleEndian.Uint32(row[8:12]), true
		}
		local := netip.AddrFrom4([4]byte(row[4:8]))
		remote := netip.AddrFrom4([4]byte(row[12:16]))
		return FlowTuple{
			Network: NetworkTCP, Source: local, SourcePort: binary.BigEndian.Uint16(row[8:10]),
			Destination: remote, DestinationPort: binary.BigEndian.Uint16(row[16:18]),
		}, binary.LittleEndian.Uint32(row[20:24]), true
	}
	local := netip.AddrFrom16([16]byte(row[:16]))
	if kind.network == NetworkUDP {
		return FlowTuple{Network: NetworkUDP, Source: local, SourcePort: binary.BigEndian.Uint16(row[20:22])}, binary.LittleEndian.Uint32(row[24:28]), true
	}
	remote := netip.AddrFrom16([16]byte(row[24:40]))
	return FlowTuple{
		Network: NetworkTCP, Source: local, SourcePort: binary.BigEndian.Uint16(row[20:22]),
		Destination: remote, DestinationPort: binary.BigEndian.Uint16(row[44:46]),
	}, binary.LittleEndian.Uint32(row[52:56]), true
}

func windowsProcessName(pid uint32) string {
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(process)
	buffer := make([]uint16, 32768)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(process, 0, &buffer[0], &size); err != nil || size == 0 || size > uint32(len(buffer)) {
		return ""
	}
	return filepath.Base(windows.UTF16ToString(buffer[:size]))
}

var _ FlowIdentityResolver = (*windowsFlowIdentityResolver)(nil)
