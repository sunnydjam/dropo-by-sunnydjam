package main

import (
	"dropocore/ownedprofile"
	"fmt"
	"slices"
	"time"
)

func (a *App) GetVPNSources() map[string]interface{} {
	a.waitForInit()
	if a.storage == nil {
		return map[string]interface{}{"success": false, "error": "storage is not initialized"}
	}
	profile, err := a.storage.GetActiveProfile()
	if err != nil {
		return map[string]interface{}{"success": false, "error": err.Error()}
	}
	active := a.activeVPNSource()
	running, now := a.isVPNRunning() && !a.vpnStopping.Load(), time.Now()
	views := publicVPNSources(profile.VPNSources)
	confirmedActive := ""
	for i, group := range windowsSourceGroups(profile.VPNSources) {
		view := views[i]
		owner := group[0]
		ownerTag := "vpn-source-" + owner.ID
		response := a.vpnSourceResponseSnapshot(ownerTag, running, now)
		confirmed := false
		ingresses := make(map[string]vpnResponse, len(group))
		for _, source := range group {
			tag := "vpn-source-" + source.ID
			sample := a.vpnSourceResponseSnapshot(tag, running, now)
			ingress := windowsRouteIngress(source.PublicCatalogID)
			if ownedprofile.IsResidential(source.PublicCatalogID) {
				ingress = "residential-xhttp"
			}
			if ownedprofile.IsMoscowCandidate(source.PublicCatalogID) {
				ingress = "moscow-" + ingress
			}
			if ingress != "" {
				ingresses[ingress] = sample
			}
			if response.State != "ok" && sample.State == "ok" {
				response = sample
			}
			if running && active == tag && sample.State == "ok" {
				confirmed, confirmedActive, response = true, ownerTag, sample
				view["active_ingress"] = ingress
			}
		}
		if len(ingresses) > 0 {
			view["ingress_responses"] = ingresses
		}
		view["active"], view["response"] = confirmed, response
	}
	return map[string]interface{}{"success": true, "sources": views, "activeSource": confirmedActive, "running": running, "autoSelect": profile.VPNSourceSelectionMode != "priority"}
}

func (a *App) AddVPNSource(name, uri string) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		source, err := newVPNSource(nextVPNSourceID(profile.VPNSources), name, uri)
		if err != nil {
			return err
		}
		profile.VPNSources = append(profile.VPNSources, source)
		return nil
	})
}

func (a *App) RemoveVPNSource(id string) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		id = normalizeVPNSourceID(id)
		for index, source := range profile.VPNSources {
			if source.ID == id {
				if windowsOwnedFamily(source.PublicCatalogID) != "" {
					profile.VPNSources = removeOwnedVPNFamily(profile.VPNSources, source.PublicCatalogID)
				} else {
					profile.VPNSources = append(profile.VPNSources[:index], profile.VPNSources[index+1:]...)
				}
				return nil
			}
		}
		return fmt.Errorf("VPN source %q not found", id)
	})
}

func (a *App) SetVPNSourceNode(id string, nodeIndex int) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		id = normalizeVPNSourceID(id)
		for index := range profile.VPNSources {
			source := &profile.VPNSources[index]
			if source.ID != id {
				continue
			}
			if nodeIndex < 0 || nodeIndex >= source.NodeCount {
				return fmt.Errorf("node index %d is outside source range", nodeIndex)
			}
			source.SelectedNode = nodeIndex
			source.SelectedNodeID = ""
			if nodeIndex < len(source.NodeIDs) {
				source.SelectedNodeID = source.NodeIDs[nodeIndex]
			}
			return nil
		}
		return fmt.Errorf("VPN source %q not found", id)
	})
}

// SetVPNSourceNodeByID resolves the user's selection inside the lifecycle
// transaction, so a stale UI index cannot select a different server.
func (a *App) SetVPNSourceNodeByID(id, nodeID string) map[string]interface{} {
	return a.setVPNSourceNodeByID(id, nodeID, vpnSourceReconnectOps{
		stop: a.stopVPNForReconnect, start: a.startVPNForReconnect, restore: a.restoreVPNSourceProfile,
	})
}

func (a *App) setVPNSourceNodeByID(id, nodeID string, ops vpnSourceReconnectOps) map[string]interface{} {
	if id == "" || len(id) > 128 || id != normalizeVPNSourceID(id) || !validVPNFavoriteNodeID(nodeID) {
		return map[string]interface{}{"success": false, "error": "Неверный идентификатор сервера. Обновите список."}
	}
	missing := func() error {
		return fmt.Errorf("Выбранный сервер больше недоступен. Обновите список и выберите сервер снова.")
	}
	return a.changeVPNSourcesTransactionValidated(func(profile *ProfileData) error {
		for i := range profile.VPNSources {
			source := &profile.VPNSources[i]
			if source.ID != id {
				continue
			}
			for index, candidateID := range source.NodeIDs {
				if candidateID == nodeID && index < source.NodeCount {
					source.SelectedNode, source.SelectedNodeID = index, nodeID
					return nil
				}
			}
		}
		return missing()
	}, func(sources []VPNSource) error {
		for _, source := range sources {
			if source.ID == id && source.SelectedNodeID == nodeID && source.SelectedNode >= 0 && source.SelectedNode < len(source.NodeIDs) && source.NodeIDs[source.SelectedNode] == nodeID {
				return nil
			}
		}
		return missing()
	}, ops)
}

func (a *App) SetVPNSourceEnabled(id string, enabled bool) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		id = normalizeVPNSourceID(id)
		for index := range profile.VPNSources {
			if profile.VPNSources[index].ID == id {
				profile.VPNSources[index].Disabled = !enabled
				if provider := profile.VPNSources[index].PublicCatalogID; ownedprofile.IsPrimary(provider) {
					for i := range profile.VPNSources {
						if sameWindowsOwnedFamily(provider, profile.VPNSources[i].PublicCatalogID) {
							profile.VPNSources[i].Disabled = !enabled
						}
					}
				}
				return nil
			}
		}
		return fmt.Errorf("VPN source %q not found", id)
	})
}

func (a *App) MoveVPNSource(id string, newIndex int) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		if !moveWindowsSource(profile, normalizeVPNSourceID(id), newIndex) {
			return fmt.Errorf("VPN source or position is unavailable")
		}
		return nil
	})
}

func (a *App) SetManagedIngress(id, ingress string) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		index := slices.IndexFunc(profile.VPNSources, func(source VPNSource) bool { return source.ID == id })
		if index >= 0 {
			source := &profile.VPNSources[index]
			if ownedprofile.ValidIngress(source.PublicCatalogID, ingress) && !source.Disabled && !ownedSourceExpired(*source) {
				if ingress != "" && !slices.ContainsFunc(profile.VPNSources, func(route VPNSource) bool {
					return sameWindowsOwnedFamily(route.PublicCatalogID, source.PublicCatalogID) && windowsRouteIngress(route.PublicCatalogID) == ingress && !route.Disabled && !ownedSourceExpired(route)
				}) {
					return fmt.Errorf("Этот вход сейчас недоступен.")
				}
				source.ManagedIngress = ingress
				if ingress == "" || moveWindowsSource(profile, id, 0) {
					return nil
				}
			}
		}
		return fmt.Errorf("Этот вход сейчас недоступен.")
	})
}

func (a *App) RefreshVPNSources() map[string]interface{} {
	return a.changeVPNSources(func(_ *ProfileData) error { return nil })
}

// Reordering is an explicit user preference. This action restores automatic
// latency selection without discarding the list's tie-break/fallback order.
func (a *App) EnableVPNSourceAutoSelect() map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		profile.VPNSourceSelectionMode = "latency"
		return nil
	})
}

func (a *App) changeVPNSources(change func(*ProfileData) error) map[string]interface{} {
	return a.changeVPNSourcesTransaction(change, vpnSourceReconnectOps{
		stop:    a.stopVPNForReconnect,
		start:   a.startVPNForReconnect,
		restore: a.restoreVPNSourceProfile,
	})
}

// publicVPNSources deliberately excludes subscription URIs and cached node
// keys. The trusted local UI only needs display metadata and never receives
// reusable credentials through the JSON bridge.
func publicVPNSources(sources []VPNSource) []map[string]interface{} {
	result := make([]map[string]interface{}, 0, len(sources))
	for _, group := range windowsSourceGroups(sources) {
		source := group[0]
		referenceOnly := ownedprofile.IsPrimary(source.PublicCatalogID) && ownedSourceExpired(source)
		name := source.Name
		ingress := ""
		if ownedprofile.IsPrimary(source.PublicCatalogID) {
			name = ownedprofile.DisplayName(source.PublicCatalogID, ownedprofile.Name(source.PublicCatalogID))
			ingress = ownedprofile.NormalizeIngress(source.PublicCatalogID, source.ManagedIngress)
		}
		problem := source.LastError
		if source.PublicCatalogID == managedFreeVPNProviderID && problem != "" {
			problem = "Не удалось обновить Dropo Free. Используются сохранённые серверы, если они доступны."
		}
		result = append(result, map[string]interface{}{
			"id": source.ID, "name": name, "kind": source.Kind, "reference_only": referenceOnly,
			"managed_ingress":   ingress,
			"public_catalog_id": source.PublicCatalogID, "using_cache": source.UsingCache,
			"disabled": source.Disabled, "selected_node": source.SelectedNode,
			"selected_node_id": source.SelectedNodeID, "node_count": source.NodeCount,
			"node_names":        append([]string(nil), source.NodeNames...),
			"node_ids":          append([]string{}, source.NodeIDs...),
			"favorite_node_ids": append([]string{}, source.FavoriteNodeIDs...),
			"last_updated":      source.LastUpdated, "last_error": problem,
		})
	}
	return result
}
