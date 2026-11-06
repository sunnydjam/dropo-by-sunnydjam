package dropocore

import (
	"dropocore/ownedprofile"
	"sort"
	"time"
)

func ownedAndroidSourceExpired(s androidVPNSource) bool {
	return ownedprofile.Expired(s.PublicCatalogID, s.URI, time.Now())
}
func addOwnedAndroidSource(provider, raw string, consent bool) string {
	if !consent {
		return androidSourceError("Подтвердите индивидуальный профиль Dropo.")
	}
	if _, err := ownedprofile.Validate(provider, raw); err != nil {
		return androidSourceError("Некорректный профиль Dropo.")
	}
	nodes, err := parseAndroidSource(raw)
	if err != nil || len(nodes) != 1 {
		return androidSourceError("Профиль Dropo не поддерживается.")
	}
	mu.Lock()
	defer mu.Unlock()
	migrateAndroidSourcesLocked()
	index := -1
	for i, s := range current.VPNSources {
		if s.PublicCatalogID == provider {
			index = i
			if s.URI == raw {
				return encode(androidSourcesViewLocked())
			}
			break
		}
	}
	if androidSourcesBusyLocked() {
		return androidSourceError("Новый профиль готов. Отключите VPN для обновления источника.")
	}
	old := current
	old.VPNSources = append([]androidVPNSource(nil), current.VPNSources...)
	name := "Dropo Free"
	if provider == ownedprofile.Boost {
		name = "Dropo Boost"
	}
	s := androidVPNSource{ID: provider, PublicCatalogID: provider, Name: name, URI: raw, Nodes: nodes, UpdatedAt: currentTimeRFC3339()}
	if index >= 0 {
		s.ID = current.VPNSources[index].ID
		s.Disabled = current.VPNSources[index].Disabled
		current.VPNSources[index] = s
	} else {
		if len(current.VPNSources) >= maxAndroidVPNSources {
			return androidSourceError("Достигнут предел источников.")
		}
		current.VPNSources = append(current.VPNSources, s)
	}
	var positions []int
	var owned []androidVPNSource
	for i, s := range current.VPNSources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			positions = append(positions, i)
			owned = append(owned, s)
		}
	}
	sort.SliceStable(owned, func(i, j int) bool {
		return owned[i].PublicCatalogID == ownedprofile.Boost && owned[j].PublicCatalogID != ownedprofile.Boost
	})
	for i, p := range positions {
		current.VPNSources[p] = owned[i]
	}
	if len(positions) == len(current.VPNSources) {
		current.VPNSourceAutoSelect = false
	}
	syncAndroidSubscriptionLocked()
	clearCachedConfigLocked()
	current.sourcesRevision++
	if err = saveLocked(); err != nil {
		current = old
		return androidSourceError("Защищённый профиль не применён.")
	}
	return encode(androidSourcesViewLocked())
}
func stateWithoutOwnedSecrets(state coreState) coreState {
	sources := make([]androidVPNSource, 0, len(state.VPNSources))
	found := false
	for _, s := range state.VPNSources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			found = true
			s.URI = ""
			s.Nodes = nil
			s.PendingNodes = nil
			s.SelectedNodeID = ""
			s.LastRefreshError = "Защищённый профиль будет загружен из хранилища устройства."
		}
		sources = append(sources, s)
	}
	if found {
		state.VPNSources = sources
		state.Subscription = ""
		state.SubscriptionProxyCount = 0
		for _, s := range sources {
			if !s.Disabled {
				state.Subscription = s.URI
				state.SubscriptionProxyCount = len(s.Nodes)
				break
			}
		}
		state.CachedSingBoxConfig = ""
		state.CachedConfigSubscription = ""
		state.CachedConfigSignature = ""
		state.CachedConfigUpdatedAt = ""
		state.CachedProxyCount = 0
	}
	return state
}
