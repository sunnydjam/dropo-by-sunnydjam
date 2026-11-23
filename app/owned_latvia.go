package main

import (
	"dropocore/ownedprofile"
	"fmt"
	"slices"
	"strings"
	"time"
)

const latviaSuffix = "-lv-quic"

func isLatviaProvider(id string) bool {
	return id == ownedprofile.Free+latviaSuffix || id == ownedprofile.Boost+latviaSuffix
}

const finlandSuffix = "-fi-tcp"

func isMainIngress(id string) bool {
	return id == ownedprofile.Free+ownedprofile.MainSuffix || id == ownedprofile.Boost+ownedprofile.MainSuffix
}
func isExtraIngress(id string) bool {
	return id == ownedprofile.Free+ownedprofile.ExtraSuffix || id == ownedprofile.Boost+ownedprofile.ExtraSuffix
}

func isRegionalProvider(id string) bool {
	return isLatviaProvider(id) || ownedprofile.IsFinlandReserveID(id)
}

func windowsOwnedFamily(id string) string {
	if isExtraIngress(id) {
		return strings.TrimSuffix(id, ownedprofile.ExtraSuffix)
	}
	if isMainIngress(id) {
		return strings.TrimSuffix(id, ownedprofile.MainSuffix)
	}
	if ownedprofile.IsFinlandReserveID(id) {
		return strings.TrimSuffix(id, finlandSuffix)
	}
	if isLatviaProvider(id) {
		return strings.TrimSuffix(id, latviaSuffix)
	}
	return ownedprofile.Family(id)
}
func sameWindowsOwnedFamily(a, b string) bool {
	family := windowsOwnedFamily(a)
	return family != "" && family == windowsOwnedFamily(b)
}

func windowsRouteIngress(provider string) string {
	if isMainIngress(provider) {
		return ownedprofile.XHTTP
	}
	if isExtraIngress(provider) {
		return ownedprofile.ExtraIngress(windowsOwnedFamily(provider))
	}
	return ownedprofile.RegionalIngress(provider)
}

// The stored key authorizes the tier. Only its scoped regional transport may dial.
func windowsRegionalURI(source VPNSource) (string, error) {
	ingress := windowsRouteIngress(source.PublicCatalogID)
	for _, route := range ownedprofile.DirectReserves(windowsOwnedFamily(source.PublicCatalogID), source.URI, time.Now()) {
		if route.Ingress == ingress {
			return route.URI, nil
		}
	}
	return "", fmt.Errorf("региональный вход Dropo недоступен")
}

func upsertWindowsOwnedSources(p *ProfileData, owner, raw string) error {
	if err := upsertWindowsRegionalSource(p, owner, raw); err != nil {
		return err
	}
	routes := ownedprofile.DirectReserves(owner, raw, time.Now())
	if len(routes) == 0 {
		return nil
	}
	disabled := slices.ContainsFunc(p.VPNSources, func(source VPNSource) bool {
		return source.PublicCatalogID == owner && source.Disabled
	})
	for _, route := range routes[1:] {
		index := slices.IndexFunc(p.VPNSources, func(source VPNSource) bool { return source.PublicCatalogID == route.ID })
		if index >= 0 {
			source := &p.VPNSources[index]
			if source.URI != raw {
				*source = VPNSource{ID: source.ID, Name: route.Name, PublicCatalogID: route.ID, URI: raw, Kind: VPNSourceDirect}
			}
			source.Disabled = disabled
			continue
		}
		p.VPNSources = append(p.VPNSources, VPNSource{ID: nextVPNSourceID(p.VPNSources), Name: route.Name, PublicCatalogID: route.ID, URI: raw, Kind: VPNSourceDirect, Disabled: disabled})
	}
	return nil
}
func upsertWindowsRegionalSource(p *ProfileData, owner, raw string) error {
	if _, err := ownedprofile.Validate(owner, raw); err != nil || !ownedprofile.IsPrimary(owner) {
		return fmt.Errorf("Некорректный профиль Dropo")
	}
	for i, s := range p.VPNSources {
		if s.PublicCatalogID == owner {
			p.VPNSources[i] = VPNSource{ID: s.ID, URI: raw, PublicCatalogID: owner, Name: ownedprofile.RegionName(owner), Kind: VPNSourceDirect, Disabled: s.Disabled, ManagedIngress: s.ManagedIngress}
			return nil
		}
	}
	s := VPNSource{ID: nextVPNSourceID(p.VPNSources), URI: raw, PublicCatalogID: owner, Name: ownedprofile.RegionName(owner), Kind: VPNSourceDirect}
	if owner == ownedprofile.Boost && p.VPNSourceSelectionMode != "priority" {
		for i, old := range p.VPNSources {
			if old.PublicCatalogID == ownedprofile.Free {
				p.VPNSources = slices.Insert(p.VPNSources, i, s)
				return nil
			}
		}
	}
	p.VPNSources = append(p.VPNSources, s)
	return nil
}

// Old settings may put a regional or relay row ahead of its parent. Keep the
// first family's position and the authoritative parent ID used by vault restore.
func migrateRegionalWindowsSources(p *ProfileData) {
	parents := map[string]VPNSource{}
	legacy := false
	for _, s := range p.VPNSources {
		if ownedprofile.IsPrimary(s.PublicCatalogID) {
			parents[s.PublicCatalogID] = s
			if s.Name != ownedprofile.RegionName(s.PublicCatalogID) {
				legacy = true
			}
		}
		if isRegionalProvider(s.PublicCatalogID) || ownedprofile.IsReserve(s.PublicCatalogID) || s.PublicCatalogID == managedFreeVPNProviderID {
			legacy = true
		}
	}
	if !legacy {
		return
	}
	inserted := make(map[string]bool, len(parents))
	next := make([]VPNSource, 0, len(p.VPNSources))
	for _, s := range p.VPNSources {
		if isMainIngress(s.PublicCatalogID) || isExtraIngress(s.PublicCatalogID) {
			if _, ok := parents[windowsOwnedFamily(s.PublicCatalogID)]; ok {
				next = append(next, s)
			}
			continue
		}
		family := windowsOwnedFamily(s.PublicCatalogID)
		if family == "" {
			if s.PublicCatalogID != managedFreeVPNProviderID {
				next = append(next, s)
			}
			continue
		}
		if inserted[family] {
			continue
		}
		primary, ok := parents[family]
		if !ok {
			// Only the vault can restore the canonical key for an orphaned row.
			primary = VPNSource{ID: s.ID, Disabled: s.Disabled}
		}
		next = append(next, VPNSource{ID: primary.ID, PublicCatalogID: family, Name: ownedprofile.RegionName(family), URI: primary.URI, Kind: VPNSourceDirect, Disabled: primary.Disabled, ManagedIngress: primary.ManagedIngress})
		inserted[family] = true
	}
	p.VPNSources = next
	p.SingboxConfig, p.XrayConfig, p.XrayConfigReady = nil, nil, false
	p.SubscriptionURL = ""
}

// Each row owns its independently probed routes. A personal subscription keeps
// only its selected server, and a saved legacy relay never becomes a route.
func windowsSourceGroups(sources []VPNSource) [][]VPNSource {
	byOwner := make(map[string][]VPNSource, 2)
	for _, source := range sources {
		if isMainIngress(source.PublicCatalogID) || isExtraIngress(source.PublicCatalogID) {
			owner := windowsOwnedFamily(source.PublicCatalogID)
			byOwner[owner] = append(byOwner[owner], source)
		}
	}
	groups := make([][]VPNSource, 0, len(sources))
	for _, source := range sources {
		if !ownedprofile.IsPrimary(source.PublicCatalogID) && windowsOwnedFamily(source.PublicCatalogID) != "" {
			continue
		}
		groups = append(groups, append([]VPNSource{source}, byOwner[source.PublicCatalogID]...))
	}
	return groups
}

func windowsRuntimeSourceGroups(sources []VPNSource) [][]VPNSource {
	groups := windowsSourceGroups(sources)
	for i, group := range groups {
		owner := group[0]
		if owner.Disabled || ownedSourceExpired(owner) {
			groups[i] = nil
			continue
		}
		if ingress := ownedprofile.NormalizeIngress(owner.PublicCatalogID, owner.ManagedIngress); ingress != "" {
			groups[i] = slices.DeleteFunc(group, func(source VPNSource) bool { return windowsRouteIngress(source.PublicCatalogID) != ingress })
		}
	}
	return groups
}

func moveWindowsSource(profile *ProfileData, id string, index int) bool {
	groups := windowsSourceGroups(profile.VPNSources)
	from := slices.IndexFunc(groups, func(group []VPNSource) bool { return group[0].ID == id })
	if from < 0 || index < 0 || index >= len(groups) {
		return false
	}
	selected := groups[from]
	groups = slices.Delete(groups, from, from+1)
	groups = slices.Insert(groups, index, selected)
	// Retain orphaned metadata for vault restore.
	used := make(map[string]bool, len(profile.VPNSources))
	reordered := make([]VPNSource, 0, len(profile.VPNSources))
	for _, group := range groups {
		reordered = append(reordered, group...)
		for _, source := range group {
			used[source.ID] = true
		}
	}
	for _, source := range profile.VPNSources {
		if !used[source.ID] {
			reordered = append(reordered, source)
		}
	}
	profile.VPNSources, profile.VPNSourceSelectionMode = reordered, "priority"
	return true
}
