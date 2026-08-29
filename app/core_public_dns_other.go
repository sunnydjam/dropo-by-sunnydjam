//go:build !windows

package main

import "net/netip"

func systemDNSServers() []netip.Addr {
	return nil
}

func allowDefaultDNSFallback() bool { return true }
