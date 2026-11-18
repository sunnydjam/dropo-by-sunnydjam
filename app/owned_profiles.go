package main

import (
	"dropocore/ownedprofile"
	"fmt"
	"sort"
	"time"
)

func (a *App) addOwnedVPNSource(provider, raw string, consent bool) map[string]interface{} {
	if !consent {
		return map[string]interface{}{"success": false, "error": "Подтвердите использование индивидуального профиля Dropo."}
	}
	return a.applyOwnedVPNSource(provider, raw, "", "", false)
}

// Restore only an existing vault reference. Enrollment uses AddManagedVPNSource;
// a stale UI snapshot must never recreate a family that the user removed.
func (a *App) RestoreManagedVPNSource(provider, raw, expectedSourceID, expectedNodeID string) map[string]interface{} {
	return a.applyOwnedVPNSource(provider, raw, expectedSourceID, expectedNodeID, true)
}

func (a *App) applyOwnedVPNSource(provider, raw, expectedSourceID, expectedNodeID string, restore bool) map[string]interface{} {
	reserveID, reserve, err := ownedprofile.Pair(provider, raw)
	if err != nil {
		return map[string]interface{}{"success": false, "error": "Получен некорректный профиль Dropo."}
	}
	var observed []VPNSource
	if a.storage != nil {
		if profile, err := a.storage.GetActiveProfile(); err == nil {
			observed = append([]VPNSource(nil), profile.VPNSources...)
			if restore && (!ownedVPNRestoreReferenceMatches(observed, provider, expectedSourceID, expectedNodeID) || !ownedVPNRestoreCredentialsMatch(observed, provider, raw, reserveID, reserve)) {
				return map[string]interface{}{"success": false, "error": "Профиль Dropo изменился. Повторите обновление источника."}
			}
			if ownedVPNPairCurrent(profile.VPNSources, provider, raw, reserveID, reserve) {
				return map[string]interface{}{"success": true}
			}
		}
	}
	return a.changeVPNSources(func(profile *ProfileData) error {
		if (restore && (!ownedVPNRestoreReferenceMatches(profile.VPNSources, provider, expectedSourceID, expectedNodeID) || !ownedVPNRestoreCredentialsMatch(profile.VPNSources, provider, raw, reserveID, reserve))) || !ownedVPNFamilyUnchanged(observed, profile.VPNSources, provider) {
			return fmt.Errorf("Профиль Dropo изменился. Повторите обновление источника.")
		}
		return upsertOwnedVPNPair(profile, provider, raw)
	})
}

// Node fingerprints omit entitlement expiry. A cached restore may populate an
// empty disk reference, but only explicit enrollment may rotate a live key.
func ownedVPNRestoreCredentialsMatch(sources []VPNSource, primary, key, reserve, reserveKey string) bool {
	for _, source := range sources {
		if source.URI == "" {
			continue
		}
		if source.PublicCatalogID == primary && source.URI != key || source.PublicCatalogID == reserve && source.URI != reserveKey {
			return false
		}
	}
	return true
}

func ownedVPNRestoreReferenceMatches(sources []VPNSource, provider, expectedID, expectedNodeID string) bool {
	if expectedID == "" || !ownedprofile.IsPrimary(provider) {
		return false
	}
	found := 0
	for _, source := range sources {
		if source.ID != expectedID {
			continue
		}
		if !ownedprofile.SameFamily(provider, source.PublicCatalogID) {
			return false
		}
		nodeID := ""
		if source.SelectedNode >= 0 && source.SelectedNode < len(source.NodeIDs) {
			nodeID = source.NodeIDs[source.SelectedNode]
		}
		if nodeID != expectedNodeID {
			return false
		}
		found++
	}
	return found == 1
}

// Check the credential/reference snapshot inside the lifecycle transaction.
// A restore that raced deletion or a newer credential update must not recreate
// that family. Renames, ordering and disable preferences are merged separately.
func ownedVPNFamilyUnchanged(before, after []VPNSource, provider string) bool {
	type reference struct{ id, provider, uri string }
	refs := func(sources []VPNSource) map[reference]int {
		result := map[reference]int{}
		for _, s := range sources {
			if ownedprofile.SameFamily(provider, s.PublicCatalogID) {
				result[reference{s.ID, s.PublicCatalogID, s.URI}]++
			}
		}
		return result
	}
	a, b := refs(before), refs(after)
	if len(a) != len(b) {
		return false
	}
	for ref, count := range a {
		if b[ref] != count {
			return false
		}
	}
	return true
}

func ownedVPNPairCurrent(sources []VPNSource, primary, key, reserve, reserveKey string) bool {
	primaryFound, reserveFound := 0, 0
	for _, s := range sources {
		if s.PublicCatalogID == primary && s.URI == key {
			primaryFound++
		}
		if s.PublicCatalogID == reserve && s.URI == reserveKey {
			reserveFound++
		}
	}
	return primaryFound == 1 && reserveFound == 1
}

// The caller owns the source transaction. Prepare both entries before replacing
// the list so a malformed member cannot leave a half-updated managed family.
func upsertOwnedVPNPair(profile *ProfileData, provider, raw string) error {
	reserveID, reserve, err := ownedprofile.Pair(provider, raw)
	if err != nil {
		return fmt.Errorf("Некорректный профиль Dropo")
	}
	sources := append([]VPNSource(nil), profile.VPNSources...)
	wasEmpty := len(sources) == 0
	seen := map[string]bool{}
	for _, s := range sources {
		if s.PublicCatalogID == provider || s.PublicCatalogID == reserveID {
			if seen[s.PublicCatalogID] {
				return fmt.Errorf("Дублирующийся профиль Dropo")
			}
			seen[s.PublicCatalogID] = true
		}
	}
	primaryIndex := -1
	for _, item := range []struct{ id, uri string }{{provider, raw}, {reserveID, reserve}} {
		index := -1
		for i, s := range sources {
			if s.PublicCatalogID == item.id {
				index = i
				break
			}
		}
		var source VPNSource
		if index >= 0 && sources[index].URI == item.uri {
			source = sources[index]
		} else {
			source, err = newVPNSource(nextVPNSourceID(sources), ownedprofile.Name(item.id), item.uri)
			if err != nil {
				return fmt.Errorf("Некорректный профиль Dropo")
			}
			source.PublicCatalogID = item.id
			if index >= 0 {
				source.ID, source.Disabled, source.Name = sources[index].ID, sources[index].Disabled, sources[index].Name
			}
		}
		if index >= 0 {
			sources[index] = source
		} else if item.id == reserveID {
			source.Disabled = sources[primaryIndex].Disabled
			index = primaryIndex + 1
			sources = append(sources, VPNSource{})
			copy(sources[index+1:], sources[index:])
			sources[index] = source
		} else {
			// An orphan reserve still represents the user's product preference.
			for _, sibling := range sources {
				if sibling.PublicCatalogID == reserveID {
					source.Disabled = sibling.Disabled
					break
				}
			}
			index = len(sources)
			sources = append(sources, source)
		}
		if item.id == provider {
			primaryIndex = index
		}
	}
	var positions []int
	var managed []VPNSource
	for i, s := range sources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			positions = append(positions, i)
			managed = append(managed, s)
		}
	}
	// Only a newly enrolled product gets the default product priority. Adding
	// a missing reserve to an existing primary must preserve its saved order.
	if !seen[provider] && !seen[reserveID] {
		sort.SliceStable(managed, func(i, j int) bool {
			return ownedprofile.Priority(managed[i].PublicCatalogID) < ownedprofile.Priority(managed[j].PublicCatalogID)
		})
		for i, p := range positions {
			sources[p] = managed[i]
		}
	}
	profile.VPNSources = sources
	if wasEmpty {
		profile.VPNSourceSelectionMode = "priority"
	}
	return nil
}

func removeOwnedVPNFamily(sources []VPNSource, provider string) []VPNSource {
	remaining := make([]VPNSource, 0, len(sources))
	for _, s := range sources {
		if !ownedprofile.SameFamily(s.PublicCatalogID, provider) {
			remaining = append(remaining, s)
		}
	}
	return remaining
}

// Managed credentials live in the native Keystore/DPAPI vault. JSON settings
// retain ordinary user sources; Flutter restores managed sources from that
// vault locally before a connection, including while the account API is down.
func settingsWithoutOwnedSecrets(settings *SettingsFile) *SettingsFile {
	if settings == nil {
		return nil
	}
	copySettings := *settings
	copySettings.Profiles = append([]ProfileData(nil), settings.Profiles...)
	for i := range copySettings.Profiles {
		p := &copySettings.Profiles[i]
		sources := make([]VPNSource, 0, len(p.VPNSources))
		found := false
		for _, s := range p.VPNSources {
			if ownedprofile.IsProvider(s.PublicCatalogID) {
				found = true
				s.URI = ""
				s.CachedNodes = nil
				s.NodeNames = nil
				s.NodeIDs = nil
				s.NodeCount = 0
				s.SelectedNodeID = ""
				s.LastError = "Защищённый профиль будет загружен из хранилища устройства."
				s.UsingCache = false
			}
			sources = append(sources, s)
		}
		if found {
			p.VPNSources = sources
			p.SubscriptionURL = ""
			p.ProxyCount = 0
			p.LastUpdated = ""
			p.SingboxConfig = nil
			p.XrayConfig = nil
			p.XrayConfigReady = false
			normalizeProfileVPNSources(p)
		}
	}
	return &copySettings
}
func ownedSourceExpired(s VPNSource) bool {
	return ownedprofile.Expired(s.PublicCatalogID, s.URI, time.Now())
}
