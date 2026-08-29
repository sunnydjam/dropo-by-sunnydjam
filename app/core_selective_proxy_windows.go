//go:build windows

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	traffic "dropo/trafficorchestrator"
	"golang.org/x/sys/windows/registry"
)

type registryStringState struct {
	value  string
	exists bool
}

type registryDWORDState struct {
	value  uint64
	exists bool
}

type windowsSelectiveProxyLease struct {
	mu          sync.Mutex
	server      *http.Server
	listener    net.Listener
	pacURL      string
	pacURLBase  string
	vpnProxy    string
	zapretProxy string
	script      string
	revision    uint64
	domainCount int
	autoConfig  registryStringState
	proxyEnable registryDWORDState
	autoDetect  registryDWORDState
	connection  windowsConnectionProxyState
	restored    bool
}

func prepareSelectiveProxyRouting(plan traffic.TrafficPlan, vpnProxyAddress, zapretProxyAddress string) (selectiveProxyRoutingLease, error) {
	script, domains, err := buildSelectiveProxyPAC(
		vpnProxyAddress, zapretProxyAddress,
		selectedVPNDomainSuffixes(plan), selectedZapretDomainSuffixes(plan), directDomainSuffixesForPlan(plan),
	)
	if err != nil {
		return nil, err
	}
	if script == "" {
		script = directOnlyProxyPAC
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listen for selective PAC: %w", err)
	}
	tokenBytes := make([]byte, 16)
	if _, err := rand.Read(tokenBytes); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("create selective PAC token: %w", err)
	}
	path := "/dropo-selective-" + hex.EncodeToString(tokenBytes) + ".pac"
	lease := &windowsSelectiveProxyLease{
		listener: listener, domainCount: len(domains), vpnProxy: vpnProxyAddress, zapretProxy: zapretProxyAddress, script: script, revision: 1,
		pacURLBase: "http://" + listener.Addr().String() + path,
	}
	lease.pacURL = lease.pacURLBase + "?revision=1"
	mux := http.NewServeMux()
	mux.HandleFunc(path, func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet && request.Method != http.MethodHead {
			response.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		response.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
		response.Header().Set("Cache-Control", "no-store, max-age=0")
		if request.Method == http.MethodGet {
			lease.mu.Lock()
			currentScript := lease.script
			lease.mu.Unlock()
			_, _ = response.Write([]byte(currentScript))
		}
	})
	server := &http.Server{
		Handler: mux, ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 2 * time.Second,
		WriteTimeout: 2 * time.Second, IdleTimeout: 5 * time.Second,
	}
	lease.server = server
	go func() {
		_ = server.Serve(listener)
	}()
	if err := lease.install(); err != nil {
		_ = server.Close()
		_ = listener.Close()
		return nil, err
	}
	return lease, nil
}

const directOnlyProxyPAC = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"

func (lease *windowsSelectiveProxyLease) Update(plan traffic.TrafficPlan) error {
	if lease == nil {
		return errors.New("selective PAC lease is not initialized")
	}
	script, domains, err := buildSelectiveProxyPAC(
		lease.vpnProxy, lease.zapretProxy,
		selectedVPNDomainSuffixes(plan), selectedZapretDomainSuffixes(plan), directDomainSuffixesForPlan(plan),
	)
	if err != nil {
		return err
	}
	if script == "" {
		script = directOnlyProxyPAC
	}
	lease.mu.Lock()
	if lease.restored {
		lease.mu.Unlock()
		return errors.New("selective PAC lease is already restored")
	}
	if lease.script == script {
		lease.domainCount = len(domains)
		lease.mu.Unlock()
		return nil
	}
	// Keep one PAC URL for the complete selective session. Changing the URL on
	// every immutable plan revision makes Chromium-based native applications
	// (notably Steam WebHelper) tear down their proxy resolver and active TLS
	// context. The response is explicitly non-cacheable, so a Windows settings
	// notification is sufficient to fetch the updated script at the same URL.
	lease.revision++
	lease.script = script
	lease.domainCount = len(domains)
	lease.mu.Unlock()
	notifyWindowsProxySettingsChanged()
	return nil
}

func (lease *windowsSelectiveProxyLease) install() error {
	connection, err := readWindowsConnectionProxyState()
	if err != nil {
		return fmt.Errorf("read effective Windows proxy profile: %w", err)
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsRegistryPath, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("open Windows proxy settings: %w", err)
	}
	defer key.Close()
	lease.autoConfig = readRegistryStringState(key, "AutoConfigURL")
	lease.proxyEnable = readRegistryDWORDState(key, "ProxyEnable")
	lease.autoDetect = readRegistryDWORDState(key, "AutoDetect")
	lease.connection = connection
	if err := key.SetStringValue("AutoConfigURL", lease.pacURL); err != nil {
		return fmt.Errorf("set selective PAC URL: %w", err)
	}
	if err := key.SetDWordValue("ProxyEnable", 0); err != nil {
		_ = restoreRegistryStringState(key, "AutoConfigURL", lease.autoConfig)
		return fmt.Errorf("disable unconditional Windows proxy: %w", err)
	}
	if err := key.SetDWordValue("AutoDetect", 0); err != nil {
		_ = restoreRegistryStringState(key, "AutoConfigURL", lease.autoConfig)
		_ = restoreRegistryDWORDState(key, "ProxyEnable", lease.proxyEnable)
		return fmt.Errorf("disable proxy autodetection: %w", err)
	}
	if err := applyWindowsConnectionProxyState(selectivePACConnectionState(lease.pacURL)); err != nil {
		_ = restoreRegistryStringState(key, "AutoConfigURL", lease.autoConfig)
		_ = restoreRegistryDWORDState(key, "ProxyEnable", lease.proxyEnable)
		_ = restoreRegistryDWORDState(key, "AutoDetect", lease.autoDetect)
		_ = applyWindowsConnectionProxyState(lease.connection)
		notifyWindowsProxySettingsChanged()
		return fmt.Errorf("activate selective PAC in Windows connection profile: %w", err)
	}
	notifyWindowsProxySettingsChanged()
	return nil
}

func (lease *windowsSelectiveProxyLease) PACURL() string {
	if lease == nil {
		return ""
	}
	lease.mu.Lock()
	defer lease.mu.Unlock()
	return lease.pacURL
}

func (lease *windowsSelectiveProxyLease) DomainCount() int {
	if lease == nil {
		return 0
	}
	lease.mu.Lock()
	defer lease.mu.Unlock()
	return lease.domainCount
}

func (lease *windowsSelectiveProxyLease) Restore() error {
	if lease == nil {
		return nil
	}
	lease.mu.Lock()
	if lease.restored {
		lease.mu.Unlock()
		return nil
	}
	lease.restored = true
	autoConfig := lease.autoConfig
	proxyEnable := lease.proxyEnable
	autoDetect := lease.autoDetect
	connection := lease.connection
	server := lease.server
	listener := lease.listener
	lease.mu.Unlock()
	var restoreErr error
	key, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsRegistryPath, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		restoreErr = fmt.Errorf("open Windows proxy settings for restore: %w", err)
	} else {
		restoreErr = errors.Join(
			restoreRegistryStringState(key, "AutoConfigURL", autoConfig),
			restoreRegistryDWORDState(key, "ProxyEnable", proxyEnable),
			restoreRegistryDWORDState(key, "AutoDetect", autoDetect),
		)
		_ = key.Close()
	}
	restoreErr = errors.Join(restoreErr, applyWindowsConnectionProxyState(connection))
	notifyWindowsProxySettingsChanged()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if server != nil {
		restoreErr = errors.Join(restoreErr, server.Shutdown(ctx))
	}
	if listener != nil {
		if err := listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			restoreErr = errors.Join(restoreErr, err)
		}
	}
	return restoreErr
}

func readRegistryStringState(key registry.Key, name string) registryStringState {
	value, _, err := key.GetStringValue(name)
	return registryStringState{value: value, exists: err == nil}
}

func readRegistryDWORDState(key registry.Key, name string) registryDWORDState {
	value, _, err := key.GetIntegerValue(name)
	return registryDWORDState{value: value, exists: err == nil}
}

func restoreRegistryStringState(key registry.Key, name string, state registryStringState) error {
	if !state.exists {
		err := key.DeleteValue(name)
		if errors.Is(err, registry.ErrNotExist) {
			return nil
		}
		return err
	}
	return key.SetStringValue(name, state.value)
}

func restoreRegistryDWORDState(key registry.Key, name string, state registryDWORDState) error {
	if !state.exists {
		err := key.DeleteValue(name)
		if errors.Is(err, registry.ErrNotExist) {
			return nil
		}
		return err
	}
	return key.SetDWordValue(name, uint32(state.value))
}

func notifyWindowsProxySettingsChanged() {
	_, _, _ = internetSetOption.Call(0, 39, 0, 0)
	_, _, _ = internetSetOption.Call(0, 37, 0, 0)
	broadcastWindowsProxySettingsChanged()
}

type noopSelectiveProxyLease struct{}

func (noopSelectiveProxyLease) Restore() error                   { return nil }
func (noopSelectiveProxyLease) PACURL() string                   { return "" }
func (noopSelectiveProxyLease) DomainCount() int                 { return 0 }
func (noopSelectiveProxyLease) Update(traffic.TrafficPlan) error { return nil }

func loopbackPACPort(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	request, err := http.NewRequest(http.MethodGet, value, nil)
	if err != nil || request.URL == nil {
		return 0
	}
	host, portText, err := net.SplitHostPort(request.URL.Host)
	if err != nil || (host != "127.0.0.1" && !strings.EqualFold(host, "localhost")) {
		return 0
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil || port < 1 || port > 65535 {
		return 0
	}
	return port
}
