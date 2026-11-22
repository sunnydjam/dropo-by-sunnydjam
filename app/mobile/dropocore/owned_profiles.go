package dropocore

import (
	"dropocore/ownedprofile"
	"fmt"
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
	return applyOwnedAndroidSource(provider, raw, "", "", false)
}

func restoreOwnedAndroidSource(provider, raw, expectedSourceID, expectedNodeID string) string {
	return applyOwnedAndroidSource(provider, raw, expectedSourceID, expectedNodeID, true)
}

func applyOwnedAndroidSource(provider, raw, expectedSourceID, expectedNodeID string, restore bool) string {
	reserveID, reserve, err := ownedprofile.Pair(provider, raw)
	if err != nil {
		return androidSourceError("Некорректный профиль Dropo.")
	}
	mu.Lock()
	migrateAndroidSourcesLocked()
	if restore && (!ownedAndroidRestoreReferenceMatches(current.VPNSources, provider, expectedSourceID, expectedNodeID) || !ownedAndroidRestoreCredentialsMatch(current.VPNSources, provider, raw, reserveID, reserve)) {
		mu.Unlock()
		return androidSourceError("Профиль Dropo изменился. Повторите обновление источника.")
	}
	if ownedAndroidPairCurrent(current.VPNSources, provider, raw, reserveID, reserve) {
		result := encode(androidSourcesViewLocked())
		mu.Unlock()
		return result
	}
	if androidSourcesBusyLocked() {
		mu.Unlock()
		return androidSourceError("Новый профиль готов. Отключите VPN для обновления источника.")
	}
	revision := current.sourcesRevision
	mu.Unlock()
	nodes, err := parseAndroidSource(raw)
	if err != nil || len(nodes) != 1 {
		return androidSourceError("Профиль Dropo не поддерживается.")
	}
	reserveNodes, err := parseAndroidSource(reserve)
	if err != nil || len(reserveNodes) != 1 {
		return androidSourceError("Резервный профиль Dropo не поддерживается.")
	}
	mu.Lock()
	defer mu.Unlock()
	// A concurrent source removal or Stop invalidates an in-flight restore.
	if current.sourcesRevision != revision || androidSourcesBusyLocked() || (restore && (!ownedAndroidRestoreReferenceMatches(current.VPNSources, provider, expectedSourceID, expectedNodeID) || !ownedAndroidRestoreCredentialsMatch(current.VPNSources, provider, raw, reserveID, reserve))) {
		return androidSourceError("Состояние VPN изменилось. Повторите действие после отключения.")
	}
	old := current
	old.VPNSources = append([]androidVPNSource(nil), current.VPNSources...)
	sources, err := upsertOwnedAndroidPair(current.VPNSources, provider, raw, nodes, reserveID, reserve, reserveNodes)
	if err != nil {
		return androidSourceError(err.Error())
	}
	current.VPNSources = sources
	syncAndroidSubscriptionLocked()
	clearCachedConfigLocked()
	current.sourcesRevision++
	if err = saveLocked(); err != nil {
		current = old
		return androidSourceError("Защищённый профиль не применён.")
	}
	emitLocked("vpn-sources-changed", map[string]interface{}{})
	return encode(androidSourcesViewLocked())
}

// A parsed node ID omits expiry metadata; stale vault restores must not roll a
// live credential back even when its server/UUID fingerprint is unchanged.
func ownedAndroidRestoreCredentialsMatch(sources []androidVPNSource, primary, key, reserve, reserveKey string) bool {
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

func ownedAndroidRestoreReferenceMatches(sources []androidVPNSource, provider, expectedID, expectedNodeID string) bool {
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
		if selected := androidSelectedNode(source); selected >= 0 && selected < len(source.Nodes) {
			nodeID = androidNodeID(source.Nodes[selected])
		}
		if nodeID != expectedNodeID {
			return false
		}
		found++
	}
	return found == 1
}

func ownedAndroidPairCurrent(sources []androidVPNSource, primary, key, reserve, reserveKey string) bool {
	primaryFound, reserveFound := 0, 0
	for _, s := range sources {
		if s.PublicCatalogID == primary && s.URI == key && len(s.Nodes) == 1 {
			primaryFound++
		}
		if s.PublicCatalogID == reserve && s.URI == reserveKey && len(s.Nodes) == 1 {
			reserveFound++
		}
	}
	return primaryFound == 1 && reserveFound == 1
}

func upsertOwnedAndroidPair(previous []androidVPNSource, primary, key string, nodes []proxyConfig, reserve, reserveKey string, reserveNodes []proxyConfig) ([]androidVPNSource, error) {
	sources := append([]androidVPNSource(nil), previous...)
	missing := 2
	seen := map[string]bool{}
	for _, s := range sources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			if seen[s.PublicCatalogID] {
				return nil, fmt.Errorf("Дублирующийся профиль Dropo.")
			}
			seen[s.PublicCatalogID] = true
			if s.PublicCatalogID == primary || s.PublicCatalogID == reserve {
				missing--
			}
		}
	}
	logical := androidLogicalSourceCount(sources)
	if !seen[primary] {
		logical++
	}
	if logical > maxAndroidVPNSources || len(sources)+missing > maxAndroidSourceCandidates {
		return nil, fmt.Errorf("Достигнут предел источников. Для профиля Dropo нужны основное и резервное подключения.")
	}
	primaryIndex := -1
	for _, item := range []struct {
		id, uri string
		nodes   []proxyConfig
	}{{primary, key, nodes}, {reserve, reserveKey, reserveNodes}} {
		index := -1
		for i, s := range sources {
			if s.PublicCatalogID == item.id {
				index = i
				break
			}
		}
		var source androidVPNSource
		if index >= 0 && sources[index].URI == item.uri && len(sources[index].Nodes) == 1 {
			source = sources[index]
		} else {
			source = androidVPNSource{ID: item.id, PublicCatalogID: item.id, Name: ownedprofile.Name(item.id), URI: item.uri, Nodes: item.nodes, UpdatedAt: currentTimeRFC3339()}
			if index >= 0 {
				source.ManagedIngress = sources[index].ManagedIngress
				source.ID, source.Disabled, source.Name = sources[index].ID, sources[index].Disabled, sources[index].Name
			}
			if index < 0 {
				// Public catalog metadata cannot steal an existing personal ID.
				for n := 1; ; n++ {
					collision := false
					for _, s := range sources {
						if s.ID == source.ID {
							collision = true
							break
						}
					}
					if !collision {
						break
					}
					source.ID = fmt.Sprintf("%s-%d", item.id, n)
				}
			}
		}
		if index >= 0 {
			sources[index] = source
		} else if item.id == reserve {
			source.Disabled = sources[primaryIndex].Disabled
			index = primaryIndex + 1
			sources = append(sources, androidVPNSource{})
			copy(sources[index+1:], sources[index:])
			sources[index] = source
		} else {
			for _, sibling := range sources {
				if sibling.PublicCatalogID == reserve {
					source.Disabled = sibling.Disabled
					break
				}
			}
			index = len(sources)
			sources = append(sources, source)
		}
		if item.id == primary {
			primaryIndex = index
		}
	}
	var positions []int
	var owned []androidVPNSource
	for i, s := range sources {
		if ownedprofile.IsProvider(s.PublicCatalogID) {
			positions = append(positions, i)
			owned = append(owned, s)
		}
	}
	// Legacy migration inserts only the missing adjacent reserve. Existing
	// primary/product priorities may be an explicit user choice.
	if !seen[primary] && !seen[reserve] {
		sort.SliceStable(owned, func(i, j int) bool {
			return ownedprofile.Priority(owned[i].PublicCatalogID) < ownedprofile.Priority(owned[j].PublicCatalogID)
		})
		for i, p := range positions {
			sources[p] = owned[i]
		}
	}
	return sources, nil
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
