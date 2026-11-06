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
	if _, err := ownedprofile.Validate(provider, raw); err != nil {
		return map[string]interface{}{"success": false, "error": "Получен некорректный профиль Dropo."}
	}
	if a.storage != nil {
		if profile, err := a.storage.GetActiveProfile(); err == nil {
			for _, s := range profile.VPNSources {
				if s.PublicCatalogID == provider && s.URI == raw {
					return map[string]interface{}{"success": true}
				}
			}
		}
	}
	return a.changeVPNSources(func(profile *ProfileData) error {
		name := "Dropo Free"
		if provider == ownedprofile.Boost {
			name = "Dropo Boost"
		}
		index := -1
		for i, s := range profile.VPNSources {
			if s.PublicCatalogID == provider {
				index = i
				break
			}
		}
		source, err := newVPNSource(nextVPNSourceID(profile.VPNSources), name, raw)
		if err != nil {
			return fmt.Errorf("Некорректный профиль Dropo")
		}
		source.PublicCatalogID = provider
		if index >= 0 {
			source.ID = profile.VPNSources[index].ID
			source.Disabled = profile.VPNSources[index].Disabled
			profile.VPNSources[index] = source
		} else {
			profile.VPNSources = append(profile.VPNSources, source)
		}
		// Preserve positions/policies of manually supplied independent providers.
		var positions []int
		var managed []VPNSource
		for i, s := range profile.VPNSources {
			if ownedprofile.IsProvider(s.PublicCatalogID) {
				positions = append(positions, i)
				managed = append(managed, s)
			}
		}
		sort.SliceStable(managed, func(i, j int) bool {
			return managed[i].PublicCatalogID == ownedprofile.Boost && managed[j].PublicCatalogID != ownedprofile.Boost
		})
		for i, p := range positions {
			profile.VPNSources[p] = managed[i]
		}
		if len(positions) == len(profile.VPNSources) {
			profile.VPNSourceSelectionMode = "priority"
		}
		return nil
	})
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
