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

func isRegionalProvider(id string) bool {
	return isLatviaProvider(id) || ownedprofile.IsFinlandReserveID(id)
}

func windowsOwnedFamily(id string) string {
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

// The stored key authorizes the tier. Only its scoped regional transport may dial.
func windowsRegionalURI(source VPNSource) (string, error) {
	routes := ownedprofile.DirectReserves(source.PublicCatalogID, source.URI, time.Now())
	if len(routes) != 1 {
		return "", fmt.Errorf("региональный вход Dropo недоступен")
	}
	return routes[0].URI, nil
}

func upsertWindowsOwnedSources(p *ProfileData, owner, raw string) error {
	if _, err := ownedprofile.Validate(owner, raw); err != nil || !ownedprofile.IsPrimary(owner) {
		return fmt.Errorf("Некорректный профиль Dropo")
	}
	for i, s := range p.VPNSources {
		if s.PublicCatalogID == owner {
			p.VPNSources[i] = VPNSource{ID: s.ID, URI: raw, PublicCatalogID: owner, Name: ownedprofile.RegionName(owner), Kind: VPNSourceDirect, Disabled: s.Disabled}
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
		next = append(next, VPNSource{ID: primary.ID, PublicCatalogID: family, Name: ownedprofile.RegionName(family), URI: primary.URI, Kind: VPNSourceDirect, Disabled: primary.Disabled})
		inserted[family] = true
	}
	p.VPNSources = next
	p.SingboxConfig, p.XrayConfig, p.XrayConfigReady = nil, nil, false
	p.SubscriptionURL = ""
}
