package main

import (
	"dropocore/ownedprofile"
	"fmt"
	"slices"
	"time"
)

// ApplyManagedVPNEntitlement updates the two managed families in a single
// prepared Windows transaction. Empty keys remove the Turbo family.
func (a *App) ApplyManagedVPNEntitlement(free, turbo string, preferTurbo bool) map[string]interface{} {
	ops := vpnSourceReconnectOps{
		stop: a.stopVPNForReconnect, start: a.startVPNForReconnect, restore: a.restoreVPNSourceProfile,
	}
	return a.applyManagedVPNEntitlement(free, turbo, preferTurbo, ops)
}

func (a *App) applyManagedVPNEntitlement(free, turbo string, preferTurbo bool, ops vpnSourceReconnectOps) map[string]interface{} {
	revoked := turbo == "" && free == ""
	if revoked {
		// Recover via a regenerated Free chain if the prepared restart fails.
		// Reapplying the old config would put the revoked credentials back.
		restore := ops.restore
		ops.restore = func(profile ProfileData) error {
			dropRevokedTurbo(&profile)
			return a.restoreVPNSourceProfileWith(profile, restore)
		}
		ops.enforceRevocation = true
	}
	alreadyRemoved := false
	result := a.changeVPNSourcesTransaction(func(profile *ProfileData) error {
		if revoked {
			alreadyRemoved = !slices.ContainsFunc(profile.VPNSources, func(source VPNSource) bool {
				return windowsOwnedFamily(source.PublicCatalogID) == ownedprofile.Boost
			})
			if alreadyRemoved {
				return fmt.Errorf("Dropo Turbo уже удалён")
			}
			dropRevokedTurbo(profile)
			return nil
		}
		if _, err := ownedprofile.Validate(ownedprofile.Boost, turbo); err != nil ||
			ownedprofile.Expired(ownedprofile.Boost, turbo, time.Now()) {
			return fmt.Errorf("Получен недействительный профиль Dropo Turbo")
		}
		if err := upsertWindowsOwnedSources(profile, ownedprofile.Free, free); err != nil {
			return err
		}
		if err := upsertWindowsOwnedSources(profile, ownedprofile.Boost, turbo); err != nil {
			return err
		}
		if !preferTurbo {
			return nil
		}
		for _, source := range profile.VPNSources {
			if source.PublicCatalogID == ownedprofile.Boost && !source.Disabled {
				moveWindowsSource(profile, source.ID, 0)
				break
			}
		}
		return nil
	}, ops)
	if alreadyRemoved {
		return map[string]interface{}{"success": true, "unchanged": true}
	}
	return result
}

func dropRevokedTurbo(profile *ProfileData) {
	profile.VPNSources = removeOwnedVPNFamily(profile.VPNSources, ownedprofile.Boost)
	for _, source := range profile.VPNSources {
		if source.PublicCatalogID == ownedprofile.Free && !source.Disabled {
			moveWindowsSource(profile, source.ID, 0)
			break
		}
	}
	profile.SubscriptionURL = ""
	profile.SingboxConfig, profile.XrayConfig, profile.XrayConfigReady = nil, nil, false
	normalizeProfileVPNSources(profile)
}

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
			matched := 0
			for _, source := range profile.VPNSources {
				if windowsOwnedFamily(source.PublicCatalogID) == provider && windowsRouteIngress(source.PublicCatalogID) != "" && source.URI == raw {
					matched++
				}
			}
			if matched == 7 {
				return map[string]interface{}{"success": true}
			}
		}
	}
	return a.changeVPNSources(func(profile *ProfileData) error {
		if (restore && (!ownedVPNRestoreReferenceMatches(profile.VPNSources, provider, expectedSourceID, expectedNodeID) || !ownedVPNRestoreCredentialsMatch(profile.VPNSources, provider, raw, reserveID, reserve))) || !ownedVPNFamilyUnchanged(observed, profile.VPNSources, provider) {
			return fmt.Errorf("Профиль Dropo изменился. Повторите обновление источника.")
		}
		return upsertWindowsOwnedSources(profile, provider, raw)
	})
}

// Node fingerprints omit entitlement expiry. A cached restore may populate an
// empty disk reference, but only explicit enrollment may rotate a live key.
func ownedVPNRestoreCredentialsMatch(sources []VPNSource, primary, key, reserve, reserveKey string) bool {
	for _, source := range sources {
		if source.URI == "" {
			continue
		}
		if (windowsOwnedFamily(source.PublicCatalogID) == primary && !ownedprofile.IsReserve(source.PublicCatalogID)) && source.URI != key || source.PublicCatalogID == reserve && source.URI != reserveKey {
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
		if !sameWindowsOwnedFamily(provider, source.PublicCatalogID) {
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
			if sameWindowsOwnedFamily(provider, s.PublicCatalogID) {
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

func removeOwnedVPNFamily(sources []VPNSource, provider string) []VPNSource {
	remaining := make([]VPNSource, 0, len(sources))
	for _, s := range sources {
		if !sameWindowsOwnedFamily(s.PublicCatalogID, provider) {
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
			if windowsOwnedFamily(s.PublicCatalogID) != "" {
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
	if isRegionalProvider(s.PublicCatalogID) || isMainIngress(s.PublicCatalogID) || isExtraIngress(s.PublicCatalogID) || ownedprofile.IsMoscowCandidate(s.PublicCatalogID) || ownedprofile.IsResidential(s.PublicCatalogID) {
		return ownedprofile.Expired(windowsOwnedFamily(s.PublicCatalogID), s.URI, time.Now())
	}
	return ownedprofile.Expired(s.PublicCatalogID, s.URI, time.Now())
}
