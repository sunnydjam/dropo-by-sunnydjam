package main

import (
	"dropocore/ownedprofile"
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
	URL         string `json:"-"`
}

const managedFreeVPNProviderID = "dropo-free"

func publicVPNProviders() []PublicVPNProvider {
	return []PublicVPNProvider{{
		ID: managedFreeVPNProviderID, Name: "Dropo Free",
		Description: "Бесплатная подписка Dropo. Доступность проверяется после вашего согласия; скорость и наличие серверов не гарантируются.",
	}}
}

// Only retained to identify saved legacy data. This provider is no longer
// offered or recreatable through AddPublicVPNSource.
func retiredPublicVPNProvider() PublicVPNProvider {
	return PublicVPNProvider{ID: "vpn-checker-ru-part9", Name: "VPN Checker · RU",
		URL: "https://raw.githubusercontent.com/kort0881/vpn-checker-backend/main/checked/RU_Best/ru_white_all_part9.txt"}
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
	for _, provider := range []PublicVPNProvider{retiredPublicVPNProvider()} {
		if parsed.String() == provider.URL {
			return provider, true
		}
	}
	return PublicVPNProvider{}, false
}

func removeRetiredPublicVPNSource(profile *ProfileData) {
	_, removed := publicVPNProviderForURI(profile.SubscriptionURL)
	kept := profile.VPNSources[:0]
	for _, source := range profile.VPNSources {
		if _, retired := publicVPNProviderForURI(source.URI); retired {
			removed = true
			continue
		}
		kept = append(kept, source)
	}
	if removed {
		clear(profile.VPNSources[len(kept):])
		profile.VPNSources = kept
		profile.SubscriptionURL = ""
		profile.SingboxConfig, profile.XrayConfig, profile.XrayConfigReady = nil, nil, false
	}
}

// Managed identity is explicit and is never derived from a personal URI.
func normalizePublicVPNSourceMetadata(sources []VPNSource) {
	for index := range sources {
		source := &sources[index]
		if isRegionalProvider(source.PublicCatalogID) || ownedprofile.IsReserve(source.PublicCatalogID) {
			// Only a matching, validated primary may supply a managed fast route.
			live := false
			for _, parent := range sources {
				if parent.PublicCatalogID != windowsOwnedFamily(source.PublicCatalogID) || parent.URI == "" {
					continue
				}
				_, relay, err := ownedprofile.Pair(parent.PublicCatalogID, parent.URI)
				if err == nil {
					if isRegionalProvider(source.PublicCatalogID) {
						live = source.URI == parent.URI
					} else {
						live = source.URI == relay
					}
				}
				break
			}
			if !live {
				source.URI, source.CachedNodes = "", nil
			}
			continue
		}
		if ownedprofile.IsProvider(source.PublicCatalogID) {
			if source.URI == "" {
				continue
			} // Persisted reference; never a usable credential.
			if _, err := ownedprofile.Validate(source.PublicCatalogID, source.URI); err != nil {
				source.URI, source.CachedNodes = "", nil
			}
			continue
		}
		if source.PublicCatalogID == managedFreeVPNProviderID && validateManagedFreeVPNURL(source.URI) == nil {
			continue
		}
		source.PublicCatalogID = ""
	}
}

func addPublicVPNSource(profile *ProfileData, providerID string, consent bool) error {
	return fmt.Errorf("бесплатный источник добавляется через сервис Dropo после подтверждения; старый публичный каталог больше не предлагается")
}

func validateManagedFreeVPNURL(uri string) error {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
		return fmt.Errorf("бесплатный источник должен содержать корректную HTTPS-ссылку без логина и пароля в адресе")
	}
	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") || strings.HasSuffix(host, ".lan") {
		return fmt.Errorf("бесплатный источник должен использовать публичный HTTPS-сервер")
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		ip = ip.Unmap()
		if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) {
			return fmt.Errorf("бесплатный источник должен использовать публичный HTTPS-сервер")
		}
	} else if !strings.Contains(host, ".") {
		return fmt.Errorf("бесплатный источник должен использовать публичный HTTPS-сервер")
	}
	return validateSubscriptionURL(uri)
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
	return map[string]interface{}{"success": false, "error": addPublicVPNSource(nil, providerID, consent).Error()}
}

func (a *App) AddManagedVPNSource(providerID, name, uri string, consent bool) map[string]interface{} {
	if ownedprofile.IsProvider(providerID) {
		return a.addOwnedVPNSource(providerID, uri, consent)
	}
	return map[string]interface{}{"success": false, "error": "Для Dropo Free нужен индивидуальный профиль Латвии."}
}
