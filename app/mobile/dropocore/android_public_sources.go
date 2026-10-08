package dropocore

import (
	"context"
	"fmt"
	"net/netip"
	"net/url"
	"strings"
)

// Retained only to recognise previously saved sources, not offered by the
// managed catalog. No executable downloads or bundled private credentials.
const androidPublicSourceID = "vpn-checker-ru-part9"
const androidPublicSourceURL = "https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_part9.txt"
const androidPublicSourceName = "VPN Checker · RU"
const androidManagedFreeSourceID = "dropo-free"

func androidPublicProviders() string {
	return encode(map[string]interface{}{"success": true, "providers": []map[string]interface{}{{
		"id": androidManagedFreeSourceID, "name": "Dropo Free",
		"description": "Бесплатная подписка Dropo. Доступность проверяется после вашего согласия; скорость и наличие серверов не гарантируются.",
		"website":     "",
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

func parseAndroidSourceEntryContext(ctx context.Context, source androidVPNSource) ([]proxyConfig, error) {
	nodes, err := parseAndroidSourceContext(ctx, source.URI)
	if err == nil && source.PublicCatalogID == androidManagedFreeSourceID {
		return usableAndroidFreeNodes(nodes)
	}
	return nodes, err
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
	return usableAndroidFreeNodes(nodes)
}

func usableAndroidFreeNodes(nodes []proxyConfig) ([]proxyConfig, error) {
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

func validateAndroidManagedFreeURL(uri string) error {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
		return fmt.Errorf("Бесплатный источник должен содержать корректную HTTPS-ссылку без логина и пароля в адресе.")
	}
	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") || strings.HasSuffix(host, ".lan") {
		return fmt.Errorf("Бесплатный источник должен использовать публичный HTTPS-сервер.")
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		ip = ip.Unmap()
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) {
			return fmt.Errorf("Бесплатный источник должен использовать публичный HTTPS-сервер.")
		}
	} else if !strings.Contains(host, ".") {
		return fmt.Errorf("Бесплатный источник должен использовать публичный HTTPS-сервер.")
	}
	return validateAndroidSubscriptionLocally(uri)
}
