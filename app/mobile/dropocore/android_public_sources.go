package dropocore

import (
	"context"
	"fmt"
	"net/netip"
	"net/url"
	"strings"
)

// Same opt-in data feed as the Windows catalog. No executable downloads.
const androidPublicSourceID = "vpn-checker-ru-part9"
const androidPublicSourceURL = "https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_part9.txt"
const androidPublicSourceName = "VPN Checker · RU"

func androidPublicProviders() string {
	return encode(map[string]interface{}{"success": true, "providers": []map[string]interface{}{{
		"id": androidPublicSourceID, "name": androidPublicSourceName,
		"description": "Сторонние публичные серверы kort0881. Скорость и доступность не гарантированы.",
		"website":     "https://github.com/kort0881/vpn-checker-backend",
	}}})
}

func isAndroidPublicSource(uri string) bool {
	parsed, err := url.Parse(uri)
	if err != nil || parsed.User != nil {
		return false
	}
	query := parsed.Query()
	query.Del("ts")
	parsed.RawQuery, parsed.Fragment = query.Encode(), ""
	return parsed.String() == androidPublicSourceURL
}

func parseAndroidSource(uri string) ([]proxyConfig, error) {
	return parseAndroidSourceContext(context.Background(), uri)
}

func parseAndroidSourceContext(ctx context.Context, uri string) ([]proxyConfig, error) {
	var nodes []proxyConfig
	var err error
	if androidSourceParser != nil {
		nodes, err = androidSourceParser(uri)
	} else {
		fetcher := newSubscriptionFetcher()
		fetcher.ctx = ctx
		nodes, err = parseAndroidProxyCandidatesWithFetcher(uri, fetcher)
	}
	if err != nil || !isAndroidPublicSource(uri) {
		return nodes, err
	}
	filtered := make([]proxyConfig, 0, len(nodes))
	seen := map[string]bool{}
	for _, node := range nodes {
		host := strings.ToLower(strings.TrimSuffix(node.Server, "."))
		if host == "" || host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || node.ServerPort < 1 || node.ServerPort > 65535 {
			continue
		}
		if ip, err := netip.ParseAddr(host); err == nil {
			ip = ip.Unmap()
			if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
		}
		id := androidNodeID(node)
		if !seen[id] {
			filtered = append(filtered, node)
			seen[id] = true
		}
	}
	if len(filtered) == 0 {
		return nil, fmt.Errorf("В публичном списке нет поддерживаемых серверов.")
	}
	return filtered, nil
}
