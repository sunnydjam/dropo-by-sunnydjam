package main

import (
	"dropocore/ownedprofile"
	"fmt"
	"strings"
	"time"
)

const latviaSuffix = "-lv-quic"

func isLatviaProvider(id string) bool {
	return id == ownedprofile.Free+latviaSuffix || id == ownedprofile.Boost+latviaSuffix
}
func windowsOwnedFamily(id string) string {
	if isLatviaProvider(id) {
		return strings.TrimSuffix(id, latviaSuffix)
	}
	return ownedprofile.Family(id)
}
func sameWindowsOwnedFamily(a, b string) bool {
	family := windowsOwnedFamily(a)
	return family != "" && family == windowsOwnedFamily(b)
}

// The vault owns the primary identity and expiry. Derive the scoped transport
// credential only when building the native outbound; never send its parent UUID.
func windowsLatviaURI(source VPNSource) (string, error) {
	owner := windowsOwnedFamily(source.PublicCatalogID)
	if !isLatviaProvider(source.PublicCatalogID) || ownedprofile.Expired(owner, source.URI, time.Now()) {
		return "", fmt.Errorf("срок действия входа Dropo истёк или ключ недоступен")
	}
	for _, route := range ownedprofile.DirectReserves(owner, source.URI, time.Now()) {
		if route.ID == source.PublicCatalogID {
			return route.URI, nil
		}
	}
	return "", fmt.Errorf("не найден латвийский вход Dropo")
}

func latviaSourceCurrent(sources []VPNSource, owner, raw string) bool {
	eligible := !ownedprofile.Expired(owner, raw, time.Now())
	for _, s := range sources {
		if s.PublicCatalogID == owner+latviaSuffix {
			return eligible && s.URI == raw
		}
	}
	return !eligible
}
func upsertWindowsOwnedSources(p *ProfileData, owner, raw string) error {
	if err := upsertOwnedVPNPair(p, owner, raw); err != nil {
		return err
	}
	id := owner + latviaSuffix
	// Expired entitlements must not advertise a selectable fast ingress.
	if ownedprofile.Expired(owner, raw, time.Now()) {
		kept := p.VPNSources[:0]
		for _, s := range p.VPNSources {
			if s.PublicCatalogID != id {
				kept = append(kept, s)
			}
		}
		p.VPNSources = kept
		return nil
	}
	for i := range p.VPNSources {
		s := &p.VPNSources[i]
		if s.PublicCatalogID != id {
			continue
		}
		if s.URI != raw {
			*s = VPNSource{ID: s.ID, Name: s.Name, Kind: VPNSourceDirect, PublicCatalogID: id, Disabled: s.Disabled, URI: raw}
		}
		return nil
	}
	for _, primary := range p.VPNSources {
		if primary.PublicCatalogID == owner {
			p.VPNSources = append(p.VPNSources, VPNSource{ID: nextVPNSourceID(p.VPNSources), Name: ownedprofile.Name(owner) + " · Латвия", Kind: VPNSourceDirect, PublicCatalogID: id, Disabled: primary.Disabled, URI: raw})
			return nil
		}
	}
	return fmt.Errorf("не найден основной профиль Dropo")
}
