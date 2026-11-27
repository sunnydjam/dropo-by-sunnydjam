//go:build !windows

package main

func resetStaleDropoPAC() (bool, string, error) {
	return false, "", nil
}

func killWindowsDropoManagedSidecarsNative(_ []string, _ []string, _ int) ([]int, error) {
	return nil, nil
}
