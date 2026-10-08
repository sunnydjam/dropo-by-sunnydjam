package dropocore

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	androidKnownDomainRegex = "^.+$"
	androidConfigSchema     = "android-package-routing-v10-source-pool"
)

const androidSingBoxVersion = "1.13.14"

var safeTagChars = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)

func BuildSingBoxConfig() string {
	mu.Lock()
	if current.sourceWorkCancelled {
		mu.Unlock()
		return androidSourceError("VPN configuration was cancelled")
	}
	if androidBuildCancel != nil {
		androidBuildCancel()
	}
	buildCtx, cancel := context.WithCancel(context.Background())
	androidBuildCancel = cancel
	defer cancel()
	migrateAndroidSourcesLocked()
	for _, source := range current.VPNSources {
		if !source.Disabled && len(source.Nodes) > 0 {
			mu.Unlock()
			return buildPreparedAndroidSourcePool(buildCtx)
		}
	}
	selectedNodeID := ""
	if source := primaryAndroidSourceLocked(); source != nil {
		selectedNodeID = source.SelectedNodeID
	}
	revision := current.sourcesRevision
	subscription := strings.TrimSpace(current.Subscription)
	enableLogging := current.Config.EnableLogging
	logLevel := effectiveAndroidLogLevel(enableLogging, current.Config.LogLevel)
	routingMode := normalizeAndroidRoutingMode(current.Config.RoutingMode)
	hideRuTraffic := current.Config.HideRuTraffic
	ruProxyAddress := strings.TrimSpace(current.Config.RuProxyAddress)
	autoUpdateSub := current.Config.AutoUpdateSub
	routePolicies := androidRoutePoliciesLocked()
	cachedConfig := current.CachedSingBoxConfig
	cachedProxyCount := current.CachedProxyCount
	cachedSubscription := current.CachedConfigSubscription
	cachedSignature := current.CachedConfigSignature
	signature := androidConfigSignature(subscription, enableLogging, logLevel, routingMode, hideRuTraffic, ruProxyAddress, routePolicies)
	if selectedNodeID != "" {
		signature += "|node=" + selectedNodeID
	}
	if !autoUpdateSub && cachedConfig != "" && subscription != "" && subscription == cachedSubscription && signature == cachedSignature {
		appendLogIfChangedLocked("android sing-box config cache reused (auto-update disabled)")
		current.SubscriptionProxyCount = cachedProxyCount
		_ = saveLocked()
		mu.Unlock()
		return encode(map[string]interface{}{
			"success":    true,
			"config":     cachedConfig,
			"proxyCount": cachedProxyCount,
			"version":    androidSingBoxVersion,
			"cached":     true,
		})
	}
	mu.Unlock()

	config, proxies, err := buildAndroidSingBoxConfigForNodeContext(buildCtx, subscription, logLevel, routingMode, hideRuTraffic, ruProxyAddress, routePolicies, selectedNodeID)

	mu.Lock()
	defer mu.Unlock()
	liveSignature := androidConfigSignature(current.Subscription, current.Config.EnableLogging,
		effectiveAndroidLogLevel(current.Config.EnableLogging, current.Config.LogLevel), current.Config.RoutingMode,
		current.Config.HideRuTraffic, strings.TrimSpace(current.Config.RuProxyAddress), androidRoutePoliciesLocked())
	if selectedNodeID != "" {
		liveSignature += "|node=" + selectedNodeID
	}
	if strings.TrimSpace(current.Subscription) != subscription || current.sourcesRevision != revision || liveSignature != signature {
		return encode(map[string]interface{}{
			"success": false,
			"error":   "VPN settings changed while Android configuration was being built",
		})
	}
	if err != nil {
		if cachedConfig != "" && subscription != "" && subscription == cachedSubscription && signature == cachedSignature {
			appendLogLocked("android sing-box config failed, using cached config: " + err.Error())
			current.Version.SingboxVersion = androidSingBoxVersion
			current.LastError = ""
			current.SubscriptionProxyCount = cachedProxyCount
			_ = saveLocked()
			return encode(map[string]interface{}{
				"success":    true,
				"config":     cachedConfig,
				"proxyCount": cachedProxyCount,
				"version":    androidSingBoxVersion,
				"cached":     true,
				"warning":    err.Error(),
			})
		}
		current.Connected = false
		current.StartedAt = ""
		current.LastError = err.Error()
		appendLogLocked("android sing-box config failed: " + err.Error())
		emitLocked("vpn-error", map[string]interface{}{"error": err.Error()})
		_ = saveLocked()
		return encode(map[string]interface{}{"success": false, "error": err.Error()})
	}

	appendLogLocked(fmt.Sprintf("android sing-box config ready (%d proxy/proxies)", len(proxies)))
	current.Version.SingboxVersion = androidSingBoxVersion
	current.LastError = ""
	current.CachedSingBoxConfig = config
	current.CachedProxyCount = len(proxies)
	current.SubscriptionProxyCount = len(proxies)
	current.CachedConfigSubscription = subscription
	current.CachedConfigSignature = signature
	current.CachedConfigUpdatedAt = currentTimeRFC3339()
	if source := primaryAndroidSourceLocked(); source != nil {
		source.Nodes, source.UpdatedAt = proxies, current.CachedConfigUpdatedAt
		selected := androidSelectedNode(*source)
		if selected >= 0 && selected < len(proxies) {
			current.preparedSources = []androidSourceCandidate{{ID: source.ID,
				Tag: proxies[selected].Tag, NodeID: androidNodeID(proxies[selected])}}
		}
	}
	_ = saveLocked()
	return encode(map[string]interface{}{
		"success":    true,
		"config":     config,
		"proxyCount": len(proxies),
		"version":    androidSingBoxVersion,
		"cached":     false,
	})
}

func currentTimeRFC3339() string {
	return time.Now().Format(time.RFC3339)
}

func buildAndroidSingBoxConfig(subscription, logLevel, routingMode string, hideRuTraffic bool, ruProxyAddress string, routePolicies map[string]string) (string, []proxyConfig, error) {
	return buildAndroidSingBoxConfigForNode(subscription, logLevel, routingMode, hideRuTraffic, ruProxyAddress, routePolicies, "")
}

func buildAndroidSingBoxConfigForNode(subscription, logLevel, routingMode string, hideRuTraffic bool, ruProxyAddress string, routePolicies map[string]string, selectedNodeID string) (string, []proxyConfig, error) {
	return buildAndroidSingBoxConfigForNodeContext(context.Background(), subscription, logLevel, routingMode, hideRuTraffic, ruProxyAddress, routePolicies, selectedNodeID)
}

func buildAndroidSingBoxConfigForNodeContext(ctx context.Context, subscription, logLevel, routingMode string, hideRuTraffic bool, ruProxyAddress string, routePolicies map[string]string, selectedNodeID string) (string, []proxyConfig, error) {
	if subscription == "" {
		return "", nil, fmt.Errorf("VPN subscription is empty")
	}
	if logLevel == "" {
		logLevel = "info"
	}

	filtered, err := parseAndroidSourceContext(ctx, subscription)
	if err != nil {
		return "", nil, err
	}
	if len(filtered) == 0 {
		return "", nil, fmt.Errorf("Подписка не содержит поддерживаемых серверов.")
	}

	selected := 0
	if selectedNodeID != "" {
		selected = androidSelectedNode(androidVPNSource{Nodes: filtered, SelectedNodeID: selectedNodeID})
		if selected < 0 {
			return "", nil, fmt.Errorf("Выбранный сервер исчез из подписки. Выберите другой сервер.")
		}
	}
	outbounds, proxyTags := buildAndroidOutbounds(filtered[selected : selected+1])
	effectiveRoutePolicies := androidEffectiveRoutePoliciesForMode(routePolicies, len(proxyTags) > 0, routingMode)
	ruOutbound := "proxy"
	ruProxyAddress = strings.TrimSpace(ruProxyAddress)
	if hideRuTraffic && ruProxyAddress != "" {
		fetcher := newSubscriptionFetcher()
		fetcher.ctx = ctx
		ruProxies, err := parseAndroidProxyCandidatesWithFetcher(ruProxyAddress, fetcher)
		if err != nil {
			return "", nil, fmt.Errorf("RU proxy address is invalid: %w", err)
		}
		outbounds, ruOutbound = appendAndroidProxyOutbounds(outbounds, ruProxies, "ru-proxy")
	}
	config, err := marshalAndroidSingBoxConfig(outbounds, proxyTags, logLevel, routingMode, hideRuTraffic, ruOutbound, effectiveRoutePolicies)
	return config, filtered, err
}

func marshalAndroidSingBoxConfig(outbounds []interface{}, proxyTags []string, logLevel, routingMode string, hideRuTraffic bool, ruOutbound string, effectiveRoutePolicies map[string]string) (string, error) {
	dnsServers := buildAndroidDNSServers(proxyTags)
	dnsRules := buildAndroidDNSRules(routingMode, hideRuTraffic, effectiveRoutePolicies)
	finalOutbound := androidFinalOutbound(routingMode)
	finalDNSServer := androidFinalDNSServer(routingMode)
	config := map[string]interface{}{
		"log": map[string]interface{}{
			"level":     logLevel,
			"timestamp": true,
		},
		"dns": map[string]interface{}{
			"servers":           dnsServers,
			"rules":             dnsRules,
			"final":             finalDNSServer,
			"strategy":          "ipv4_only",
			"reverse_mapping":   true,
			"independent_cache": true,
		},
		"inbounds": []interface{}{
			map[string]interface{}{
				"type":         "tun",
				"tag":          "tun-in",
				"address":      []string{"172.19.0.1/30", "fdfe:dcba:9876::1/126"},
				"mtu":          1500,
				"auto_route":   true,
				"strict_route": true,
				"stack":        "mixed",
			},
		},
		"outbounds": outbounds,
		"route": map[string]interface{}{
			"rules":                   buildAndroidRouteRules(routingMode, hideRuTraffic, ruOutbound, effectiveRoutePolicies),
			"final":                   finalOutbound,
			"auto_detect_interface":   true,
			"default_domain_resolver": map[string]interface{}{"server": "dns-direct", "strategy": "ipv4_only"},
		},
		"experimental": map[string]interface{}{
			"cache_file": map[string]interface{}{"enabled": false},
		},
	}

	data, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// Current subscriptions already carry parsed nodes in private storage. Build
// their bootstrap plan without waiting for subscription servers to respond.
// Only the legacy (unparsed) migration above needs an initial download.
func buildPreparedAndroidSourcePool(ctx context.Context) string {
	mu.Lock()
	defer mu.Unlock()
	if ctx.Err() != nil {
		return androidSourceError("VPN configuration was cancelled")
	}
	sources := current.VPNSources
	outbounds := make([]interface{}, 0, len(sources)+2)
	proxyTags := make([]string, 0, len(sources))
	candidates := make([]androidSourceCandidate, 0, len(sources))
	for _, source := range sources {
		if source.Disabled {
			continue
		}
		selected := androidSelectedNode(source)
		if selected < 0 || selected >= len(source.Nodes) {
			continue
		}
		node := source.Nodes[selected]
		node.Tag = "vpn-" + source.ID
		outbounds = append(outbounds, proxyToSingBoxOutbound(node))
		proxyTags = append(proxyTags, node.Tag)
		candidates = append(candidates, androidSourceCandidate{ID: source.ID, Tag: node.Tag, NodeID: androidNodeID(node)})
	}
	if len(candidates) == 0 {
		return androidSourceError("Включённые источники не содержат выбранных серверов. Обновите подписки или выберите сервер.")
	}
	outbounds = append(outbounds, map[string]interface{}{"type": "selector", "tag": "proxy", "outbounds": proxyTags,
		"default": proxyTags[0], "interrupt_exist_connections": false})
	outbounds = append(outbounds, map[string]interface{}{"type": "direct", "tag": "direct"})
	// The optional RU source was validated when it was saved; a network download
	// for it must not hold the connection gate or this state lock.
	ruOutbound := "proxy"
	if current.Config.HideRuTraffic && strings.TrimSpace(current.Config.RuProxyAddress) != "" {
		ruAddress, revision, settings := current.Config.RuProxyAddress, current.sourcesRevision, current.Config
		mu.Unlock()
		fetcher := newSubscriptionFetcher()
		fetcher.ctx = ctx
		nodes, err := parseAndroidProxyCandidatesWithFetcher(ruAddress, fetcher)
		mu.Lock()
		if revision != current.sourcesRevision || settings != current.Config {
			return androidSourceError("VPN settings changed while Android configuration was being built")
		}
		if err != nil {
			return androidSourceError("RU proxy address is invalid")
		}
		outbounds, ruOutbound = appendAndroidProxyOutbounds(outbounds, nodes, "ru-proxy")
	}
	routingMode := normalizeAndroidRoutingMode(current.Config.RoutingMode)
	policies := androidEffectiveRoutePoliciesForMode(androidRoutePoliciesLocked(), true, routingMode)
	config, err := marshalAndroidSingBoxConfig(outbounds, proxyTags,
		effectiveAndroidLogLevel(current.Config.EnableLogging, current.Config.LogLevel), routingMode,
		current.Config.HideRuTraffic, ruOutbound, policies)
	if err != nil {
		return androidSourceError("Не удалось подготовить Android VPN.")
	}
	current.preparedSources = candidates
	current.Version.SingboxVersion = androidSingBoxVersion
	current.LastError = ""
	current.CachedSingBoxConfig = config
	current.CachedProxyCount = len(candidates)
	current.SubscriptionProxyCount = len(primaryAndroidSourceLocked().Nodes)
	current.CachedConfigSubscription = current.Subscription
	fingerprint := sha256.Sum256([]byte(config))
	current.CachedConfigSignature = fmt.Sprintf("%s|%x", androidConfigSchema, fingerprint)
	current.CachedConfigUpdatedAt = currentTimeRFC3339()
	_ = saveLocked()
	return encode(map[string]interface{}{"success": true, "config": config,
		"proxyCount": current.SubscriptionProxyCount, "version": androidSingBoxVersion,
		"cached": false, "sourcesCached": true, "candidates": candidates, "bootstrapSourceId": candidates[0].ID})
}

func effectiveAndroidLogLevel(enableLogging bool, logLevel string) string {
	if !enableLogging {
		return "error"
	}
	switch strings.ToLower(strings.TrimSpace(logLevel)) {
	case "trace", "debug", "info", "warn", "error":
		return strings.ToLower(strings.TrimSpace(logLevel))
	default:
		return "info"
	}
}

func parseAndroidProxyCandidates(subscription string) ([]proxyConfig, error) {
	return parseAndroidProxyCandidatesWithFetcher(subscription, newSubscriptionFetcher())
}

func parseAndroidProxyCandidatesWithFetcher(subscription string, fetcher *subscriptionFetcher) ([]proxyConfig, error) {
	if fetcher == nil {
		return nil, fmt.Errorf("subscription checker is unavailable")
	}
	var proxies []proxyConfig
	var err error
	if isDirectProxyLink(subscription) {
		proxy, parseErr := parseAndroidDirectProxyCandidate(subscription)
		err = parseErr
		proxies = []proxyConfig{proxy}
	} else {
		proxies, err = fetcher.fetchAndParse(subscription)
	}
	if err != nil {
		return nil, err
	}

	filtered := make([]proxyConfig, 0, len(proxies))
	for _, proxy := range proxies {
		proxy.Network = normalizeTransport(proxy.Network)
		if !isTransportSupported(proxy.Network) {
			continue
		}
		if proxy.Tag == "" {
			proxy.Tag = generateProxyTag(proxy, len(filtered))
		}
		filtered = append(filtered, proxy)
	}
	if len(filtered) == 0 {
		return nil, fmt.Errorf("subscription does not contain supported Android sing-box proxies")
	}
	return filtered, nil
}

func parseAndroidDirectProxyCandidate(value string) (proxy proxyConfig, err error) {
	defer func() {
		if recover() != nil {
			proxy = proxyConfig{}
			err = fmt.Errorf("invalid VPN key")
		}
	}()
	return (&subscriptionFetcher{}).parseSingleLink(value)
}

func buildAndroidOutbounds(proxies []proxyConfig) ([]interface{}, []string) {
	// A subscription is one source. Never automatically race its sibling nodes.
	if len(proxies) > 1 {
		proxies = proxies[:1]
	}
	outbounds := make([]interface{}, 0, len(proxies)+3)
	proxyTags := make([]string, 0, len(proxies))
	for _, proxy := range proxies {
		outbounds = append(outbounds, proxyToSingBoxOutbound(proxy))
		proxyTags = append(proxyTags, proxy.Tag)
	}
	if len(proxyTags) == 1 {
		outbounds = append(outbounds, map[string]interface{}{
			"type":      "selector",
			"tag":       "proxy",
			"outbounds": proxyTags,
			"default":   proxyTags[0],
		})
	}
	outbounds = append(outbounds, map[string]interface{}{"type": "direct", "tag": "direct"})
	return outbounds, proxyTags
}

func appendAndroidProxyOutbounds(outbounds []interface{}, proxies []proxyConfig, selectorTag string) ([]interface{}, string) {
	if len(proxies) > 1 {
		proxies = proxies[:1]
	}
	proxyTags := make([]string, 0, len(proxies))
	for i, proxy := range proxies {
		proxy.Tag = fmt.Sprintf("%s-%d", selectorTag, i+1)
		outbounds = append(outbounds, proxyToSingBoxOutbound(proxy))
		proxyTags = append(proxyTags, proxy.Tag)
	}
	if len(proxyTags) == 0 {
		return outbounds, "proxy"
	}
	return outbounds, proxyTags[0]
}

func proxyToSingBoxOutbound(proxy proxyConfig) map[string]interface{} {
	out := map[string]interface{}{
		"type":        proxy.Type,
		"tag":         proxy.Tag,
		"server":      proxy.Server,
		"server_port": proxy.ServerPort,
	}
	switch proxy.Type {
	case "vless":
		out["uuid"] = proxy.UUID
		if proxy.Flow != "" {
			out["flow"] = proxy.Flow
		}
		addTLS(out, proxy)
		addTransport(out, proxy)
	case "trojan":
		out["password"] = proxy.Password
		if proxy.Security == "" {
			proxy.Security = "tls"
		}
		addTLS(out, proxy)
		addTransport(out, proxy)
	case "shadowsocks":
		out["method"] = proxy.Method
		out["password"] = proxy.Password
	case "vmess":
		out["uuid"] = proxy.UUID
		out["security"] = "auto"
		addTLS(out, proxy)
		addTransport(out, proxy)
	case "hysteria2":
		out["password"] = proxy.Password
		addTLS(out, proxyConfig{
			Security: "tls",
			SNI:      firstNonEmpty(proxy.SNI, proxy.Server),
			ALPN:     proxy.ALPN,
		})
		if proxy.Obfs != "" && proxy.ObfsPassword != "" {
			out["obfs"] = map[string]interface{}{"type": proxy.Obfs, "password": proxy.ObfsPassword}
		}
		if proxy.UpMbps > 0 {
			out["up_mbps"] = proxy.UpMbps
		}
		if proxy.DownMbps > 0 {
			out["down_mbps"] = proxy.DownMbps
		}
	case "tuic":
		out["uuid"] = proxy.UUID
		out["password"] = proxy.Password
		out["congestion_control"] = firstNonEmpty(proxy.CongestionControl, "cubic")
		out["udp_relay_mode"] = firstNonEmpty(proxy.UDPRelayMode, "native")
		addTLS(out, proxyConfig{Security: "tls", SNI: firstNonEmpty(proxy.SNI, proxy.Server), ALPN: proxy.ALPN})
	}
	return out
}

func addTLS(out map[string]interface{}, proxy proxyConfig) {
	if proxy.Security != "tls" && proxy.Security != "reality" {
		return
	}
	tls := map[string]interface{}{"enabled": true}
	if proxy.SNI != "" {
		tls["server_name"] = proxy.SNI
	}
	if proxy.Fingerprint != "" && proxy.Security != "hysteria2" {
		tls["utls"] = map[string]interface{}{"enabled": true, "fingerprint": proxy.Fingerprint}
	}
	if alpn := splitCSV(proxy.ALPN); len(alpn) > 0 {
		tls["alpn"] = alpn
	}
	if proxy.Security == "reality" {
		reality := map[string]interface{}{"enabled": true, "public_key": proxy.PublicKey}
		if proxy.ShortID != "" {
			reality["short_id"] = proxy.ShortID
		}
		tls["reality"] = reality
	}
	out["tls"] = tls
}

func addTransport(out map[string]interface{}, proxy proxyConfig) {
	if proxy.Network == "" || proxy.Network == "tcp" {
		return
	}
	transport := map[string]interface{}{"type": proxy.Network}
	switch proxy.Network {
	case "ws":
		if proxy.Path != "" {
			transport["path"] = proxy.Path
		}
		if proxy.Host != "" {
			transport["headers"] = map[string]interface{}{"Host": proxy.Host}
		}
	case "grpc":
		if proxy.Path != "" {
			transport["service_name"] = strings.TrimPrefix(proxy.Path, "/")
		}
	case "http":
		if proxy.Path != "" {
			transport["path"] = proxy.Path
		}
		if proxy.Host != "" {
			transport["host"] = []string{proxy.Host}
		}
	case "httpupgrade":
		if proxy.Path != "" {
			transport["path"] = proxy.Path
		}
		if proxy.Host != "" {
			transport["host"] = proxy.Host
		}
	}
	out["transport"] = transport
}

func buildAndroidDNSServers(proxyTags []string) []interface{} {
	servers := []interface{}{
		map[string]interface{}{"type": "local", "tag": "dns-local"},
		map[string]interface{}{
			"type":        "https",
			"tag":         "dns-direct",
			"server":      "8.8.4.4",
			"server_port": 443,
			"path":        "/dns-query",
			"tls":         map[string]interface{}{"server_name": "dns.google"},
		},
	}
	remote := map[string]interface{}{
		"type":        "https",
		"tag":         "dns-remote",
		"server":      "8.8.8.8",
		"server_port": 443,
		"path":        "/dns-query",
		"tls":         map[string]interface{}{"server_name": "dns.google"},
	}
	if len(proxyTags) > 0 {
		remote["detour"] = "proxy"
	}
	servers = append(servers, remote)
	return servers
}

func buildAndroidDNSRules(routingMode string, hideRuTraffic bool, routePolicies map[string]string) []interface{} {
	rules := []interface{}{
		map[string]interface{}{
			"domain_suffix": []string{"local", "internal", "corp", "lan", "home", "intranet", "private"},
			"action":        "route",
			"server":        "dns-local",
		},
	}
	if routingMode != "all_traffic" {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": androidLatencySensitiveDirectDomainSuffixes(),
			"action":        "route",
			"server":        "dns-direct",
		})
	}
	if directDomains := androidServiceDomainSuffixesByPolicy(routePolicies, androidRoutePolicyDirect); len(directDomains) > 0 {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": directDomains,
			"action":        "route",
			"server":        "dns-direct",
		})
	}
	if vpnDomains := androidServiceDomainSuffixesByPolicy(routePolicies, androidRoutePolicyVPN); len(vpnDomains) > 0 {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": vpnDomains,
			"action":        "route",
			"server":        "dns-remote",
		})
	}
	if routingMode != "all_traffic" {
		ruServer := "dns-direct"
		if hideRuTraffic {
			ruServer = "dns-remote"
		}
		rules = append(rules,
			map[string]interface{}{"domain_suffix": androidDirectDomainSuffixes(), "action": "route", "server": ruServer},
			map[string]interface{}{"domain_keyword": androidDirectDomainKeywords(), "action": "route", "server": ruServer},
		)
	}
	return rules
}

func buildAndroidRouteRules(routingMode string, hideRuTraffic bool, ruOutbound string, routePolicies map[string]string) []interface{} {
	rules := []interface{}{
		map[string]interface{}{"action": "sniff"},
		map[string]interface{}{"protocol": "dns", "action": "hijack-dns"},
		map[string]interface{}{"ip_is_private": true, "action": "route", "outbound": "direct"},
		map[string]interface{}{
			"domain_suffix": []string{"local", "internal", "corp", "lan", "home", "intranet", "private"},
			"action":        "route",
			"outbound":      "direct",
		},
	}
	if routingMode != "all_traffic" {
		rules = append(rules,
			map[string]interface{}{
				"domain_suffix": androidLatencySensitiveDirectDomainSuffixes(),
				"action":        "route",
				"outbound":      "direct",
			},
			map[string]interface{}{
				"package_name": androidLatencySensitiveDirectPackageNames(),
				"action":       "route",
				"outbound":     "direct",
			},
		)
	}
	if directDomains := androidServiceDomainSuffixesByPolicy(routePolicies, androidRoutePolicyDirect); len(directDomains) > 0 {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": directDomains,
			"action":        "route",
			"outbound":      "direct",
		})
	}
	if directPackages := androidServicePackageNamesByPolicy(routePolicies, androidRoutePolicyDirect); len(directPackages) > 0 {
		rules = append(rules, map[string]interface{}{
			"package_name": directPackages,
			"action":       "route",
			"outbound":     "direct",
		})
	}
	// Service CIDRs are intentionally not emitted as hostless direct rules.
	// Shared Meta/CDN addresses can serve multiple services with conflicting
	// policies; domain or Android package evidence above must select the route.
	if vpnDomains := androidServiceDomainSuffixesByPolicy(routePolicies, androidRoutePolicyVPN); len(vpnDomains) > 0 {
		rules = append(rules, map[string]interface{}{
			"domain_suffix": vpnDomains,
			"action":        "route",
			"outbound":      "proxy",
		})
	}
	if vpnPackages := androidServicePackageNamesByPolicy(routePolicies, androidRoutePolicyVPN); len(vpnPackages) > 0 {
		rules = append(rules, map[string]interface{}{
			"package_name": vpnPackages,
			"action":       "route",
			"outbound":     "proxy",
		})
	}
	if routingMode != "all_traffic" {
		ruRouteOutbound := "direct"
		if hideRuTraffic {
			ruRouteOutbound = ruOutbound
		}
		rules = append(rules,
			map[string]interface{}{"domain_suffix": androidDirectDomainSuffixes(), "action": "route", "outbound": ruRouteOutbound},
			map[string]interface{}{"domain_keyword": androidDirectDomainKeywords(), "action": "route", "outbound": ruRouteOutbound},
			// Terminal boundary for every hostname not positively identified by a
			// blocked-service domain or package rule above. Service IP ranges are
			// metadata/diagnostics only and must never capture another application.
			map[string]interface{}{"domain_regex": []string{androidKnownDomainRegex}, "action": "route", "outbound": "direct"},
		)
	}
	return rules
}

func androidFinalOutbound(routingMode string) string {
	switch routingMode {
	case "all_traffic":
		return "proxy"
	default:
		return "direct"
	}
}

func androidFinalDNSServer(routingMode string) string {
	if androidFinalOutbound(routingMode) == "proxy" {
		return "dns-remote"
	}
	return "dns-direct"
}

func androidDirectDomainSuffixes() []string {
	return []string{
		"ru", "su", "xn--p1ai",
		"yandex.com", "yandex.net", "yandex.ru", "ya.ru",
		"google.com", "google.ru", "gstatic.com", "googleusercontent.com",
		"mail.ru", "vk.com", "vkontakte.ru", "ok.ru",
		"sberbank.ru", "sber.ru", "tinkoff.ru", "vtb.ru",
		"gazprom.ru", "mos.ru", "gosuslugi.ru", "nalog.ru",
		"government.ru", "kremlin.ru", "duma.gov.ru", "cbr.ru",
		"ria.ru", "rbc.ru", "interfax.ru", "tass.ru", "kommersant.ru",
		"lenta.ru", "gazeta.ru", "kp.ru", "mk.ru",
		"rutube.ru", "ivi.ru", "okko.tv", "more.tv", "kinopoisk.ru",
		"dzen.ru", "2gis.ru", "avito.ru", "ozon.ru", "wildberries.ru",
		"mts.ru", "megafon.ru", "beeline.ru", "tele2.ru", "rostelecom.ru",
	}
}

func androidDirectDomainKeywords() []string {
	return []string{"yandex", "sber", "tinkoff", "gosuslugi", "rutube", "vkontakte", "mailru", "rambler", "wildberries", "ozon"}
}

func androidLatencySensitiveDirectDomainSuffixes() []string {
	return []string{
		"steam.com", "steampowered.com", "steamcommunity.com", "steamstatic.com",
		"steamcontent.com", "steamserver.net", "steamgames.com", "steam-chat.com",
		"valvesoftware.com", "valvesoftware.net", "valvecdn.com", "counter-strike.net",
		"riotgames.com", "riotcdn.net", "pvp.net", "leagueoflegends.com",
	}
}

func androidLatencySensitiveDirectPackageNames() []string {
	return []string{
		"com.valvesoftware.android.steam.community",
		"com.valvesoftware.steamlink",
		"com.riotgames.league.wildrift",
		"com.riotgames.league.teamfighttactics",
	}
}

func androidConfigSignature(subscription string, enableLogging bool, logLevel, routingMode string, hideRuTraffic bool, ruProxyAddress string, routePolicies map[string]string) string {
	parts := []string{
		"singbox=" + androidSingBoxVersion,
		"schema=" + androidConfigSchema,
		"subscription=" + strings.TrimSpace(subscription),
		"log=" + effectiveAndroidLogLevel(enableLogging, logLevel),
		"routing=" + normalizeAndroidRoutingMode(routingMode),
		fmt.Sprintf("hideRu=%v", hideRuTraffic),
		"ruProxy=" + strings.TrimSpace(ruProxyAddress),
	}
	keys := make([]string, 0, len(routePolicies))
	for key := range routePolicies {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		parts = append(parts, "route."+key+"="+normalizeAndroidRoutePolicy(routePolicies[key]))
	}
	return strings.Join(parts, "\n")
}

func generateProxyTag(proxy proxyConfig, index int) string {
	base := proxy.Name
	if base == "" {
		base = proxy.Server
	}
	base = strings.Trim(safeTagChars.ReplaceAllString(base, "-"), "-")
	if base == "" {
		base = proxy.Type
	}
	return fmt.Sprintf("%s-%d", strings.ToLower(base), index+1)
}

func splitCSV(value string) []string {
	var result []string
	for _, part := range strings.Split(value, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}
