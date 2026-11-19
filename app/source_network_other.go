//go:build !windows

package main

func vpnSourceNetworkKey() string { return currentNetworkFingerprint() }
