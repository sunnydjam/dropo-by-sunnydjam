package main

import (
	"crypto/rand"
	"dropocore/blockedlist"
	"encoding/binary"
	"fmt"
	"net/netip"
	"path/filepath"
	"strings"

	traffic "dropo/trafficorchestrator"
)

const (
	commonBlockedServiceTag = "blocked-catch-all"
	blockedDomainsFileName  = "domains_all.lst"
	blockedIPsFileName      = "ipsum.lst"
	commonBlockedProbeCount = 4
)

type blockedCatalog = blockedlist.Catalog

func loadBlockedCatalog(runtimeBasePath string) (blockedCatalog, error) {
	filtersPath := filepath.Join(runtimeBasePath, "bin", FiltersFolder)
	domains, err := blockedlist.ReadLines(filepath.Join(filtersPath, blockedDomainsFileName), true)
	if err != nil {
		return blockedCatalog{}, err
	}
	cidrs, err := blockedlist.ReadLines(filepath.Join(filtersPath, blockedIPsFileName), false)
	if err != nil {
		return blockedCatalog{}, err
	}
	domains = excludeNamedServiceDomains(domains)
	domains = excludeDirectDomains(domains)
	cidrs = excludeNamedServiceCIDRs(cidrs)
	if len(domains) < commonBlockedProbeCount {
		return blockedCatalog{}, fmt.Errorf("blocked domain catalog has only %d usable entries", len(domains))
	}
	return blockedCatalog{Domains: domains, IPCIDRs: cidrs}, nil
}

// loadBlockedCatalogCached avoids reparsing the signed multi-megabyte catalog
// on every immutable plan revision. Runtime files do not change in place, and
// callers receive fresh slices so plan assembly cannot mutate the cache.
func (a *App) loadBlockedCatalogCached() (blockedCatalog, error) {
	if a == nil {
		return blockedCatalog{}, fmt.Errorf("app is nil")
	}
	path := a.runtimeBasePath()
	a.blockedCatalogMu.Lock()
	defer a.blockedCatalogMu.Unlock()
	if a.blockedCatalogReady && a.blockedCatalogPath == path {
		return cloneBlockedCatalog(a.blockedCatalogValue), nil
	}
	catalog, err := loadBlockedCatalog(path)
	if err != nil {
		return blockedCatalog{}, err
	}
	a.blockedCatalogPath = path
	a.blockedCatalogValue = cloneBlockedCatalog(catalog)
	a.blockedCatalogReady = true
	return cloneBlockedCatalog(catalog), nil
}

// Only ten entries cross the desktop bridge. Files are immutable within a verified runtime.
func (a *App) SearchBlockedCatalog(query string) map[string]any {
	a.waitForInit()
	base := a.runtimeBasePath()
	if base != "" {
		base = filepath.Join(base, "bin", FiltersFolder)
	}
	var personal blockedlist.Personal
	if a.storage != nil {
		personal = a.storage.GetAppSettings().PersonalAddresses
	}
	return a.applicationIndex.Search(base, query, personal)
}

func cloneBlockedCatalog(catalog blockedCatalog) blockedCatalog {
	return blockedCatalog{
		Domains: append([]string(nil), catalog.Domains...),
		IPCIDRs: append([]string(nil), catalog.IPCIDRs...),
	}
}

func excludeDirectDomains(domains []string) []string {
	result := domains[:0]
	for _, domain := range domains {
		direct := false
		for _, suffix := range DirectDomainSuffixes {
			suffix = strings.ToLower(strings.TrimSpace(suffix))
			if suffix != "" && (domain == suffix || strings.HasSuffix(domain, "."+suffix)) {
				direct = true
				break
			}
		}
		if !direct {
			result = append(result, domain)
		}
	}
	return result
}

func excludeNamedServiceDomains(domains []string) []string {
	suffixes := make([]string, 0)
	for _, service := range DefaultFreeAccessServices {
		for _, suffix := range service.DomainSuffixes {
			if suffix = strings.ToLower(strings.TrimSpace(suffix)); suffix != "" {
				suffixes = append(suffixes, suffix)
			}
		}
	}
	result := domains[:0]
	for _, domain := range domains {
		// Shared ECH names and public hosting suffixes cannot identify a tenant.
		switch domain {
		case "cloudflare-ech.com", "pages.dev", "workers.dev":
			continue
		}
		named := false
		for _, suffix := range suffixes {
			if domain == suffix || strings.HasSuffix(domain, "."+suffix) {
				named = true
				break
			}
		}
		if !named {
			result = append(result, domain)
		}
	}
	return result
}

func excludeNamedServiceCIDRs(cidrs []string) []string {
	named := make([]netip.Prefix, 0)
	for _, service := range DefaultFreeAccessServices {
		for _, raw := range service.IPCIDRs {
			if prefix, err := netip.ParsePrefix(raw); err == nil {
				named = append(named, prefix.Masked())
			}
		}
	}
	result := cidrs[:0]
	for _, raw := range cidrs {
		prefix, _ := netip.ParsePrefix(raw)
		overlaps := false
		for _, reserved := range named {
			if prefix.Contains(reserved.Addr()) || reserved.Contains(prefix.Addr()) {
				overlaps = true
				break
			}
		}
		if !overlaps {
			result = append(result, raw)
		}
	}
	return result
}

func commonBlockedMethods() []ServiceBypassMethod {
	strategies := traffic.BuiltinStrategies()
	methods := make([]ServiceBypassMethod, 0, len(strategies))
	for _, strategy := range strategies {
		if strings.HasPrefix(strategy.ID, "native-discord-") {
			continue
		}
		methods = append(methods, ServiceBypassMethod{
			Tag: strategy.ID, Label: strategy.Label, NativeStrategyID: strategy.ID,
		})
	}
	return methods
}

func findCommonBlockedMethod(tag string) (ServiceBypassMethod, bool) {
	for _, method := range commonBlockedMethods() {
		if method.Tag == tag {
			return method, true
		}
	}
	return ServiceBypassMethod{}, false
}

func randomBlockedProbeTargets(domains []string, count int) ([]traffic.ProbeTarget, error) {
	if count < 1 || len(domains) < count {
		return nil, fmt.Errorf("need %d probe domains, catalog contains %d", count, len(domains))
	}
	indexes := make([]int, len(domains))
	for index := range indexes {
		indexes[index] = index
	}
	for index := 0; index < count; index++ {
		var bytes [8]byte
		if _, err := rand.Read(bytes[:]); err != nil {
			return nil, fmt.Errorf("select random blocked probes: %w", err)
		}
		selected := index + int(binary.LittleEndian.Uint64(bytes[:])%uint64(len(indexes)-index))
		indexes[index], indexes[selected] = indexes[selected], indexes[index]
	}
	targets := make([]traffic.ProbeTarget, 0, count)
	for index := 0; index < count; index++ {
		domain := domains[indexes[index]]
		targets = append(targets, traffic.ProbeTarget{
			ID: fmt.Sprintf("blocked-sample-%d", index+1), Network: traffic.NetworkTCP,
			Kind: traffic.ProbeHTTP, URL: "https://" + domain + "/", Port: 443, TimeoutMS: 5000,
		})
	}
	return targets, nil
}
