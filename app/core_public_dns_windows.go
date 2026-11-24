//go:build windows

package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net/netip"
	"unsafe"

	"golang.org/x/sys/windows"
)

func systemDNSServers() []netip.Addr {
	size := uint32(15 * 1024)
	for attempt := 0; attempt < 3; attempt++ {
		buffer := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		flags := uint32(windows.GAA_FLAG_SKIP_UNICAST | windows.GAA_FLAG_SKIP_ANYCAST | windows.GAA_FLAG_SKIP_MULTICAST)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, first, &size)
		if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			continue
		}
		if err != nil {
			return nil
		}
		result := make([]netip.Addr, 0, 4)
		seen := make(map[netip.Addr]struct{})
		for adapter := first; adapter != nil; adapter = adapter.Next {
			if adapter.OperStatus != windows.IfOperStatusUp || adapter.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK {
				continue
			}
			for server := adapter.FirstDnsServerAddress; server != nil; server = server.Next {
				address, ok := netip.AddrFromSlice(server.Address.IP())
				if !ok {
					continue
				}
				address = address.Unmap()
				if !address.IsValid() || address.IsUnspecified() || address.IsMulticast() || address.IsLoopback() {
					continue
				}
				if _, exists := seen[address]; exists {
					continue
				}
				seen[address] = struct{}{}
				result = append(result, address)
			}
		}
		return result
	}
	return nil
}

func allowDefaultDNSFallback() bool { return false }

// Windows network GUIDs distinguish physical networks with identical LAN prefixes.
func vpnSourceNetworkKey() string {
	id, _ := residentialPhysicalNetwork()
	if id == (windows.GUID{}) {
		return ""
	}
	return fmt.Sprintf("%x", sha256.Sum256([]byte(id.String())))
}

func residentialPhysicalNetwork() (windows.GUID, uint32) {
	size := uint32(15 * 1024)
	for attempt := 0; attempt < 3; attempt++ {
		buf := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0]))
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, windows.GAA_FLAG_INCLUDE_GATEWAYS, 0, first, &size)
		if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			continue
		}
		if err != nil {
			return windows.GUID{}, 0
		}
		best := uint32(^uint32(0))
		var id windows.GUID
		var index uint32
		for a := first; a != nil; a = a.Next {
			if a.OperStatus != windows.IfOperStatusUp || a.FirstGatewayAddress == nil || a.NetworkGuid == (windows.GUID{}) || (a.IfType != 6 && a.IfType != 71 && a.IfType != 243 && a.IfType != 244) {
				continue
			}
			if a.Ipv4Metric < best {
				best = a.Ipv4Metric
				id = a.NetworkGuid
				index = a.IfIndex
			}
		}
		return id, index
	}
	return windows.GUID{}, 0
}
