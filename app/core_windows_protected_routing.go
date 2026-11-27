package main

import (
	"bufio"
	"crypto/rand"
	"dropocore/dnspolicy"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	windowsProtectedRouterInterface = "Dropo Protected Routing"
	windowsProtectedLinkInbound     = "protected-router-link"
	windowsProtectedLinkOutbound    = "protected-vpn"
	windowsProtectedRouterDNS       = "protected-local"
	windowsProtectedFakeIPv4        = "198.19.0.0/16"
	windowsProtectedFakeIPv6        = "fc00:db80:aaaa::/96"
	windowsProtectedFakeTTL         = 3
)

type protectedRouterLink struct {
	Port     int
	Password string
}

type windowsProtectedRouter struct {
	mu              sync.Mutex
	link            protectedRouterLink
	process         *exec.Cmd
	done            chan struct{}
	failure         string
	offlineRequests atomic.Uint64
	lastNotice      atomic.Int64
}

func (r *windowsProtectedRouter) linkSnapshot() (protectedRouterLink, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.link.Port == 0 {
		port, err := findAvailableTCPPort("127.0.0.1")
		if err != nil {
			return protectedRouterLink{}, err
		}
		var secret [32]byte
		if _, err := rand.Read(secret[:]); err != nil {
			return protectedRouterLink{}, err
		}
		r.link = protectedRouterLink{Port: port, Password: hex.EncodeToString(secret[:])}
	}
	return r.link, nil
}

func (a *App) startWindowsProtectedRouter() (startErr error) {
	if runtime.GOOS != "windows" || a.storage == nil || a.isShuttingDown() {
		return nil
	}
	router := &a.protectedRouter
	link, err := router.linkSnapshot()
	if err != nil {
		return err
	}
	router.mu.Lock()
	defer router.mu.Unlock()
	defer func() {
		if startErr != nil {
			router.failure = startErr.Error()
		}
	}()
	if a.isShuttingDown() || router.process != nil {
		return nil
	}
	if !bundledRuntimeEnabled() || !a.DependenciesStatus().Ready {
		return fmt.Errorf("не удалось подтвердить встроенный сетевой runtime")
	}
	access := newClashAPIAccess()
	customPath := customVPNRuleSetPath(a.storage.GetResourcesPath())
	settings := a.storage.GetAppSettings()
	if err := writeCustomVPNRuleSet(customPath, settings.CustomVPNServices, settings.ApplicationBindings...); err != nil {
		return err
	}
	config := buildWindowsProtectedRouterConfig(link, customPath)
	if !windowsPhysicalIPv6Available() {
		config["dns"].(map[string]any)["strategy"] = "ipv4_only"
	}
	if err := access.apply(config); err != nil {
		return err
	}
	path := filepath.Join(a.storage.GetResourcesPath(), "protected-router.json")
	if err := writeJSONConfig(path, config); err != nil {
		return err
	}
	defer os.Remove(path)
	cmd := newBackgroundCommand(a.singBoxPathSnapshot(), "run", "-c", path)
	cmd.Dir = a.storage.GetResourcesPath()
	reader, writer := io.Pipe()
	defer func() {
		if startErr != nil {
			_ = reader.Close()
			_ = writer.Close()
		}
	}()
	cmd.Stdout, cmd.Stderr = writer, writer
	if err := cmd.Start(); err != nil {
		return err
	}
	attachManagedCmdToJob(cmd, "protected-router", a.writeLog)
	exited := make(chan error, 1)
	done := make(chan struct{})
	go a.readProtectedRouterEvents(reader, showSystemNotice)
	go func() {
		exited <- cmd.Wait()
		_ = writer.Close()
		close(exited)
		close(done)
	}()
	if err := waitForSingBoxReady(access, exited, func() bool { return !a.isShuttingDown() }, 8*time.Second); err != nil {
		terminateProcessTree(cmd)
		<-done
		return err
	}
	router.process = cmd
	router.done = done
	router.failure = ""
	go func() {
		<-done
		router.mu.Lock()
		if router.process == cmd {
			router.process = nil
			router.done = nil
			router.failure = "Локальный сетевой маршрутизатор остановился"
		}
		router.mu.Unlock()
	}()
	return nil
}

func (a *App) readProtectedRouterEvents(reader io.ReadCloser, notify func(string, string) bool) {
	defer reader.Close()
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "FATAL") {
			a.writeLog("[ProtectedRouting] " + line)
			continue
		}
		_, destination, found := strings.Cut(line, "outbound/socks["+windowsProtectedLinkOutbound+"]:")
		if !found || a.isVPNRunning() || a.isShuttingDown() {
			continue
		}
		_, address, found := strings.Cut(destination, " connection to ")
		host, _, err := net.SplitHostPort(strings.TrimSpace(address))
		if !found || err != nil || host == "" {
			continue
		}
		settings := a.storage.GetAppSettings()
		if settings.DisableProtectedRouting {
			continue
		}
		a.protectedRouter.offlineRequests.Add(1)
		if !settings.Notifications || !isSystrayReady() {
			continue
		}
		now := time.Now().Unix()
		last := a.protectedRouter.lastNotice.Load()
		if now-last >= 30 && a.protectedRouter.lastNotice.CompareAndSwap(last, now) {
			if !notify("Включите VPN в Dropo", "Чтобы открыть "+host+", включите VPN.") {
				a.protectedRouter.lastNotice.CompareAndSwap(now, last)
			}
		}
	}
}

func (r *windowsProtectedRouter) stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.process != nil {
		terminateProcessTree(r.process)
		<-r.done
	}
	r.process, r.done, r.failure = nil, nil, ""
}

func (r *windowsProtectedRouter) status() (int, string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.process != nil {
		select {
		case <-r.done:
			return 0, "Локальный сетевой маршрутизатор остановился"
		default:
			return r.process.Process.Pid, ""
		}
	}
	return 0, r.failure
}

func (a *App) configureWindowsProtectedLink(path string, selective bool) error {
	link, err := a.protectedRouter.linkSnapshot()
	if err != nil {
		return err
	}
	config, err := readJSONConfig(path)
	if err != nil {
		return err
	}
	if !windowsPhysicalIPv6Available() {
		if dns, ok := config["dns"].(map[string]any); ok {
			// Wintun can acknowledge a local connect before an IPv6 upstream
			// exists. Publishing unusable AAAA answers stalls clients that
			// would otherwise have fallen back to IPv4 at socket connect.
			dns["strategy"] = "ipv4_only"
		}
	}
	inbounds, _ := config["inbounds"].([]any)
	for _, raw := range inbounds {
		inbound, _ := raw.(map[string]any)
		if inbound["type"] != "tun" {
			continue
		}
		// An alias issued while disconnected belongs to the stable router,
		// including after the transport becomes ready.
		excluded := interfaceStringSlice(inbound["route_exclude_address"])
		inbound["route_exclude_address"] = uniqueStrings(append(excluded, windowsProtectedFakeIPv4, windowsProtectedFakeIPv6))
		if !selective && len(interfaceStringSlice(inbound["route_address"])) == 0 {
			// A healthy full session takes precedence over the router's two /0 routes.
			inbound["route_address"] = []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"}
		}
	}
	inbounds = append(inbounds, map[string]any{
		"type": "socks", "tag": windowsProtectedLinkInbound,
		"listen": "127.0.0.1", "listen_port": link.Port,
		"users": []map[string]string{{"username": windowsProtectedLinkInbound, "password": link.Password}},
	})
	config["inbounds"] = inbounds
	route, _ := config["route"].(map[string]any)
	if route == nil {
		return fmt.Errorf("VPN routing policy is missing")
	}
	outbounds, _ := config["outbounds"].([]any)
	terminal := NoRouteOutboundTag
	if protectedLinkUsesVPN(outbounds, "auto-select", map[string]bool{}) {
		terminal = "auto-select"
	}
	if terminal == NoRouteOutboundTag && !outboundTagExists(outbounds, terminal) {
		config["outbounds"] = append(outbounds, map[string]any{"type": "block", "tag": terminal})
	}
	inboundMatch := []string{windowsProtectedLinkInbound}
	head := []any{map[string]any{"inbound": inboundMatch, "action": "route", "outbound": terminal}}
	rules, _ := route["rules"].([]any)
	route["rules"] = append(head, rules...)
	return writeJSONConfig(path, config)
}

func protectedLinkUsesVPN(outbounds []any, tag string, visiting map[string]bool) bool {
	if visiting[tag] {
		return false
	}
	outbound := configOutboundByTag(outbounds, tag)
	switch outbound["type"] {
	case "selector", "urltest":
		candidates := interfaceStringSlice(outbound["outbounds"])
		if len(candidates) == 0 {
			return false
		}
		visiting[tag] = true
		defer delete(visiting, tag)
		for _, candidate := range candidates {
			if !protectedLinkUsesVPN(outbounds, candidate, visiting) {
				return false
			}
		}
		return true
	case "vless", "vmess", "hysteria2", "tuic", "trojan", "shadowsocks", "wireguard", "socks", "http", "block":
		return true
	default:
		return false
	}
}

// buildWindowsProtectedRouterConfig is the policy for an independent Wintun
// ingress. It receives no subscription data and cannot choose a VPN provider.
// The protected outbound has exactly one authenticated loopback destination.
// A missing transport listener therefore fails the connection locally.
func buildWindowsProtectedRouterConfig(link protectedRouterLink, customPath ...string) map[string]any {
	const direct = "direct"
	domains := protectedServiceRules(GlobalAppSettings{}, true, true)
	routeRules := []any{
		map[string]any{"action": "sniff"},
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
		map[string]any{"ip_is_private": true, "outbound": direct},
		map[string]any{"domain_suffix": LocalDomainSuffixes, "outbound": direct},
	}
	dnsRules := []any{
		map[string]any{"domain_suffix": LocalDomainSuffixes, "server": "network-dns"},
	}
	var ruleSets []any
	if len(customPath) != 0 {
		match := []string{customVPNRuleSet}
		ruleSets = append(ruleSets, customVPNRuleSetConfig(customPath[0]))
		routeRules = append(routeRules, map[string]any{"rule_set": match, "outbound": windowsProtectedLinkOutbound})
		dnsRules = append(dnsRules, map[string]any{"rule_set": match, "server": windowsProtectedRouterDNS, "rewrite_ttl": windowsProtectedFakeTTL})
	}
	for _, raw := range domains {
		rule := raw.(map[string]any)
		rule["outbound"] = windowsProtectedLinkOutbound
		routeRules = append(routeRules, rule)
		for _, key := range []string{"domain", "domain_suffix"} {
			if names, ok := rule[key]; ok {
				dnsRules = append(dnsRules, map[string]any{key: names, "server": windowsProtectedRouterDNS, "rewrite_ttl": windowsProtectedFakeTTL})
			}
		}
	}
	// Corporate domains keep the network resolver. A short evaluation for
	// ordinary Internet names leaves a stock direct DoH fallback for networks
	// where the adapter resolver cannot be reached from the Wintun runtime.
	dnsRules = append(dnsRules,
		map[string]any{"action": "evaluate", "server": "network-dns", "tag": "network-result", "timeout": "1s"},
		map[string]any{"action": "respond", "match_response": "network-result", "response_rcode": "NOERROR"},
		map[string]any{"action": "respond", "match_response": "network-result", "response_rcode": "NXDOMAIN"},
	)
	dns := map[string]any{
		"servers": []any{
			map[string]any{"type": "local", "tag": "network-dns", "prefer_go": true},
			map[string]any{"type": "fakeip", "tag": windowsProtectedRouterDNS,
				"inet4_range": windowsProtectedFakeIPv4, "inet6_range": windowsProtectedFakeIPv6},
			dnspolicy.Server("dns-direct", false),
		},
		"final": "dns-direct", "rules": dnsRules, "reverse_mapping": true, "strategy": "prefer_ipv4",
	}
	resolver := dnspolicy.EnsurePreferredDialResolver(dns, "dns-direct")
	dnspolicy.ConfigureRuntimeFailover(dns)
	return map[string]any{
		"log": map[string]any{"level": "info", "disabled": false},
		"inbounds": []any{map[string]any{
			"type": "tun", "tag": "protected-tun", "interface_name": windowsProtectedRouterInterface,
			"address":    []string{"172.23.250.1/30", "fdfe:dcba:9877::1/126"},
			"auto_route": true, "stack": "system", "mtu": 1500,
		}},
		"outbounds": []any{
			map[string]any{"type": "direct", "tag": direct},
			map[string]any{
				"type": "socks", "tag": windowsProtectedLinkOutbound,
				"server": "127.0.0.1", "server_port": link.Port, "version": "5",
				"username": windowsProtectedLinkInbound, "password": link.Password,
			},
		},
		"route": map[string]any{"auto_detect_interface": true, "final": direct, "rules": routeRules,
			"default_domain_resolver": resolver, "rule_set": ruleSets},
		"dns": dns,
	}
}
