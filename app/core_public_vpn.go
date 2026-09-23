package main

import (
	"fmt"
	"net/netip"
	"net/url"
	"strings"
)

// Public feeds are opt-in data sources, not bundled credentials or executable
// dependencies. Never put a user's subscription URL in this catalog.
type PublicVPNProvider struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Website     string `json:"website"`
	URL         string `json:"url"`
}

func publicVPNProviders() []PublicVPNProvider {
	return []PublicVPNProvider{{
		ID:          "vpn-checker-ru-part9",
		Name:        "VPN Checker · RU",
		Description: "Публичный список серверов kort0881. Скорость и доступность зависят от оператора и нагрузки; приоритет задаёте вы.",
		Website:     "https://github.com/kort0881/vpn-checker-backend",
		URL:         "https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_part9.txt",
	}}
}

func publicVPNProviderByID(id string) (PublicVPNProvider, bool) {
	for _, provider := range publicVPNProviders() {
		if provider.ID == id {
			return provider, true
		}
	}
	return PublicVPNProvider{}, false
}

func publicVPNProviderForURI(uri string) (PublicVPNProvider, bool) {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil || parsed.Scheme != "https" || parsed.User != nil {
		return PublicVPNProvider{}, false
	}
	// The supplied ts parameter is only a cache buster, not a separate source.
	query := parsed.Query()
	query.Del("ts")
	parsed.RawQuery = query.Encode()
	parsed.Fragment = ""
	for _, provider := range publicVPNProviders() {
		if parsed.String() == provider.URL {
			return provider, true
		}
	}
	return PublicVPNProvider{}, false
}

// Derive public identity from the URI without changing the saved source order.
// New sources are appended; a user's subsequent priority choice is authoritative.
func normalizePublicVPNSourceMetadata(sources []VPNSource) {
	for index := range sources {
		source := &sources[index]
		source.PublicCatalogID = ""
		if provider, ok := publicVPNProviderForURI(source.URI); ok {
			source.PublicCatalogID = provider.ID
			source.URI = provider.URL
		}
	}
}

func addPublicVPNSource(profile *ProfileData, providerID string, consent bool) error {
	if !consent {
		return fmt.Errorf("подтвердите использование сторонних бесплатных VPN-серверов")
	}
	provider, ok := publicVPNProviderByID(providerID)
	if !ok {
		return fmt.Errorf("неизвестный бесплатный VPN-источник")
	}
	for _, source := range profile.VPNSources {
		if existing, matched := publicVPNProviderForURI(source.URI); matched && existing.ID == provider.ID {
			return fmt.Errorf("бесплатный источник уже добавлен; включите его в списке")
		}
	}
	source, err := newVPNSource(nextVPNSourceID(profile.VPNSources), provider.Name, provider.URL)
	if err != nil {
		return err
	}
	source.PublicCatalogID = provider.ID
	profile.VPNSources = append(profile.VPNSources, source)
	return nil
}

// Keep provider order, but do not offer transports this core cannot run or
// literal LAN/loopback endpoints from an untrusted public list.
func usablePublicVPNNodes(nodes []ProxyConfig) []ProxyConfig {
	result := make([]ProxyConfig, 0, len(nodes))
	seen := map[string]bool{}
	for _, node := range nodes {
		if node.Server == "" || node.ServerPort < 1 || node.ServerPort > 65535 {
			continue
		}
		host := strings.ToLower(strings.TrimSuffix(node.Server, "."))
		if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
			continue
		}
		if address, err := netip.ParseAddr(node.Server); err == nil {
			address = address.Unmap()
			if !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() {
				continue
			}
		}
		if !RequiresXrayBridge(node) && !IsTransportSupported(node.Network) {
			continue
		}
		id := vpnNodeFingerprint(node)
		if !seen[id] {
			seen[id] = true
			result = append(result, node)
		}
	}
	return result
}

func (a *App) GetPublicVPNProviders() map[string]interface{} {
	return map[string]interface{}{"success": true, "providers": publicVPNProviders()}
}

func (a *App) AddPublicVPNSource(providerID string, consent bool) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		return addPublicVPNSource(profile, providerID, consent)
	})
}
