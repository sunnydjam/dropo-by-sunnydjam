package main

import (
	"fmt"
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
	views := publicVPNSources(profile.VPNSources)
	for _, view := range views {
		view["active"] = a.isVPNRunning() && active == "vpn-source-"+view["id"].(string)
	}
	return map[string]interface{}{"success": true, "sources": views, "activeSource": active}
}

func (a *App) AddVPNSource(name, uri string) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		source, err := newVPNSource(nextVPNSourceID(profile.VPNSources), name, uri)
		if err != nil {
			return err
		}
		if provider, public := publicVPNProviderForURI(uri); public {
			for _, existing := range profile.VPNSources {
				if known, ok := publicVPNProviderForURI(existing.URI); ok && known.ID == provider.ID {
					return fmt.Errorf("бесплатный источник уже добавлен")
				}
			}
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
				profile.VPNSources = append(profile.VPNSources[:index], profile.VPNSources[index+1:]...)
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

func (a *App) SetVPNSourceEnabled(id string, enabled bool) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		id = normalizeVPNSourceID(id)
		for index := range profile.VPNSources {
			if profile.VPNSources[index].ID == id {
				profile.VPNSources[index].Disabled = !enabled
				return nil
			}
		}
		return fmt.Errorf("VPN source %q not found", id)
	})
}

func (a *App) MoveVPNSource(id string, newIndex int) map[string]interface{} {
	return a.changeVPNSources(func(profile *ProfileData) error {
		if newIndex < 0 || newIndex >= len(profile.VPNSources) {
			return fmt.Errorf("source index %d is outside range", newIndex)
		}
		id = normalizeVPNSourceID(id)
		oldIndex := -1
		for index, source := range profile.VPNSources {
			if source.ID == id {
				oldIndex = index
				break
			}
		}
		if oldIndex < 0 {
			return fmt.Errorf("VPN source %q not found", id)
		}
		_, movingPublic := publicVPNProviderForURI(profile.VPNSources[oldIndex].URI)
		_, targetPublic := publicVPNProviderForURI(profile.VPNSources[newIndex].URI)
		if movingPublic != targetPublic {
			return fmt.Errorf("бесплатный источник используется только после ваших подписок")
		}
		source := profile.VPNSources[oldIndex]
		profile.VPNSources = append(profile.VPNSources[:oldIndex], profile.VPNSources[oldIndex+1:]...)
		profile.VPNSources = append(profile.VPNSources, VPNSource{})
		copy(profile.VPNSources[newIndex+1:], profile.VPNSources[newIndex:])
		profile.VPNSources[newIndex] = source
		return nil
	})
}

func (a *App) RefreshVPNSources() map[string]interface{} {
	return a.changeVPNSources(func(_ *ProfileData) error { return nil })
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
		result = append(result, map[string]interface{}{
			"id": source.ID, "name": source.Name, "kind": source.Kind,
			"public_catalog_id": source.PublicCatalogID, "using_cache": source.UsingCache,
			"disabled": source.Disabled, "selected_node": source.SelectedNode,
			"selected_node_id": source.SelectedNodeID, "node_count": source.NodeCount,
			"node_names":   append([]string(nil), source.NodeNames...),
			"last_updated": source.LastUpdated, "last_error": source.LastError,
		})
	}
	return result
}
