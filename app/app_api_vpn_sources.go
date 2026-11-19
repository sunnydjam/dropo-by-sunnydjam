package main

import (
	"dropocore/ownedprofile"
	"fmt"
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
	owners := ownedVPNSourceTags(profile.VPNSources, now)
	visibleActive := active
	if owner := owners[active]; owner != "" {
		visibleActive = owner
	}
	views := publicVPNSources(profile.VPNSources)
	for _, view := range views {
		tag := "vpn-source-" + view["id"].(string)
		isActive := running && visibleActive == tag
		probeTag := tag
		if isActive {
			probeTag = active
		}
		response := a.vpnSourceResponseSnapshot(probeTag, running, now)
		if probeTag != tag {
			response.SourceID, response.NodeID = view["id"].(string), ""
		}
		view["active"], view["response"] = isActive, response
	}
	return map[string]interface{}{"success": true, "sources": views, "activeSource": visibleActive, "running": running, "autoSelect": profile.VPNSourceSelectionMode != "priority"}
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
				if ownedprofile.IsProvider(source.PublicCatalogID) {
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
				if provider := profile.VPNSources[index].PublicCatalogID; ownedprofile.IsProvider(provider) {
					for i := range profile.VPNSources {
						if ownedprofile.SameFamily(provider, profile.VPNSources[i].PublicCatalogID) {
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
		id = normalizeVPNSourceID(id)
		order, ok := ownedprofile.Move(ownedSourceInputs(profile.VPNSources), id, newIndex)
		if !ok {
			return fmt.Errorf("VPN source %q not found", id)
		}
		reordered := make([]VPNSource, len(order))
		for i, index := range order {
			reordered[i] = profile.VPNSources[index]
		}
		profile.VPNSources = reordered
		profile.VPNSourceSelectionMode = "priority"
		return nil
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
	for _, source := range sources {
		if ownedprofile.IsReserve(source.PublicCatalogID) {
			continue
		}
		problem := source.LastError
		if source.PublicCatalogID == managedFreeVPNProviderID && problem != "" {
			problem = "Не удалось обновить Dropo Free. Используются сохранённые серверы, если они доступны."
		}
		result = append(result, map[string]interface{}{
			"id": source.ID, "name": ownedprofile.DisplayName(source.PublicCatalogID, source.Name), "kind": source.Kind,
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
