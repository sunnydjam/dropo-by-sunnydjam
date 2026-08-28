//go:build windows

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	traffic "dropo/trafficorchestrator"
	"golang.org/x/sys/windows"
)

var (
	selectiveDNSAPI             = windows.NewLazySystemDLL("dnsapi.dll")
	selectiveDNSFlushResolver   = selectiveDNSAPI.NewProc("DnsFlushResolverCache")
	selectiveHostsMutationMutex sync.Mutex
)

type windowsSelectiveNameResolutionLease struct {
	hostsPath string
	disabled  int
	primed    int
}

func prepareSelectiveNameResolution(plan traffic.TrafficPlan, directory *traffic.FakeIPDirectory) (selectiveNameResolutionLease, error) {
	lease := &windowsSelectiveNameResolutionLease{hostsPath: windowsHostsPath()}
	if err := lease.Update(selectiveNameResolutionPlan{Plan: plan, Directory: directory}); err != nil {
		return nil, err
	}
	return lease, nil
}

func (lease *windowsSelectiveNameResolutionLease) Update(update selectiveNameResolutionPlan) error {
	if lease == nil || strings.TrimSpace(lease.hostsPath) == "" {
		return errors.New("selective name-resolution lease is not initialized")
	}
	suffixes := selectedVPNDomainSuffixes(update.Plan)

	selectiveHostsMutationMutex.Lock()
	defer selectiveHostsMutationMutex.Unlock()

	input, err := os.ReadFile(lease.hostsPath)
	if err != nil {
		return fmt.Errorf("read Windows hosts file: %w", err)
	}
	withoutStaleFake, _ := removeSelectiveFakeHosts(input)
	output, disabled, conflicts := disableSelectedVPNHostsMappings(withoutStaleFake, suffixes)
	if conflicts > 0 {
		return fmt.Errorf("Windows hosts file has %d mixed selected/direct mapping(s)", conflicts)
	}
	output, primed := installSelectiveFakeHosts(output, selectedVPNFakeHostMappings(update.Plan, update.Directory))
	if !bytes.Equal(input, output) {
		if err := writeExistingFile(lease.hostsPath, output); err != nil {
			return fmt.Errorf("update selected-service hosts overlay: %w", err)
		}
	}
	if err := flushWindowsResolverCache(); err != nil {
		if !bytes.Equal(input, output) {
			_ = writeExistingFile(lease.hostsPath, input)
			_ = flushWindowsResolverCache()
		}
		return err
	}
	lease.disabled = disabled
	lease.primed = primed
	return nil
}

func (lease *windowsSelectiveNameResolutionLease) DisabledMappings() int {
	if lease == nil {
		return 0
	}
	return lease.disabled
}

func (lease *windowsSelectiveNameResolutionLease) PrimedMappings() int {
	if lease == nil {
		return 0
	}
	return lease.primed
}

func (lease *windowsSelectiveNameResolutionLease) Restore() error {
	if lease == nil || strings.TrimSpace(lease.hostsPath) == "" {
		return nil
	}
	selectiveHostsMutationMutex.Lock()
	defer selectiveHostsMutationMutex.Unlock()
	input, err := os.ReadFile(lease.hostsPath)
	if err != nil {
		return fmt.Errorf("read Windows hosts file for restore: %w", err)
	}
	output, _ := removeSelectiveFakeHosts(input)
	output, restored := restoreSelectedVPNHostsMappings(output)
	if restored > 0 && !bytes.Equal(input, output) {
		if err := writeExistingFile(lease.hostsPath, output); err != nil {
			return fmt.Errorf("restore selected-service hosts mappings: %w", err)
		}
	}
	if err := flushWindowsResolverCache(); err != nil {
		return err
	}
	return nil
}

func windowsHostsPath() string {
	root := strings.TrimSpace(os.Getenv("SystemRoot"))
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "drivers", "etc", "hosts")
}

func writeExistingFile(path string, data []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, info.Mode().Perm())
}

func flushWindowsResolverCache() error {
	if err := selectiveDNSFlushResolver.Find(); err != nil {
		return fmt.Errorf("resolve DnsFlushResolverCache: %w", err)
	}
	result, _, callErr := selectiveDNSFlushResolver.Call()
	if result == 0 {
		if callErr != nil && !errors.Is(callErr, syscall.Errno(0)) {
			return fmt.Errorf("flush Windows DNS cache: %w", callErr)
		}
		return errors.New("flush Windows DNS cache failed")
	}
	return nil
}
