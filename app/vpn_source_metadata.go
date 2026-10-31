package main

import (
	"encoding/hex"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxVPNSourceFavorites = 64

func validVPNSourceDisplayName(name string) bool {
	if name == "" || !utf8.ValidString(name) || utf8.RuneCountInString(name) > 80 || strings.Contains(name, "://") {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) || unicode.Is(unicode.Zl, r) || unicode.Is(unicode.Zp, r) {
			return false
		}
	}
	return true
}

func validVPNFavoriteNodeID(id string) bool {
	if len(id) != 24 || id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func normalizeVPNFavoriteNodeIDs(ids []string) []string {
	result := make([]string, 0, min(len(ids), maxVPNSourceFavorites))
	seen := make(map[string]bool, len(result))
	for _, id := range ids {
		if validVPNFavoriteNodeID(id) && !seen[id] {
			result = append(result, id)
			seen[id] = true
			if len(result) == maxVPNSourceFavorites {
				break
			}
		}
	}
	return result
}

func preserveVPNSourceMetadata(next, live []VPNSource) {
	for i := range next {
		for _, previous := range live {
			if next[i].ID == previous.ID && next[i].URI == previous.URI {
				next[i].Name = previous.Name
				next[i].FavoriteNodeIDs = migrateVPNFavoriteNodeIDs(previous)
				break
			}
		}
	}
}

func migrateVPNFavoriteNodeIDs(source VPNSource) []string {
	ids := normalizeVPNFavoriteNodeIDs(source.FavoriteNodeIDs)
	for n, favorite := range ids {
		for index, oldID := range source.NodeIDs {
			if favorite == oldID && index < len(source.CachedNodes) {
				if node, err := (&SubscriptionFetcher{}).ParseSingleLink(source.CachedNodes[index]); err == nil {
					ids[n] = vpnNodeFingerprint(node)
				}
				break
			}
		}
	}
	return normalizeVPNFavoriteNodeIDs(ids)
}

func (a *App) RenameVPNSource(id, name string) map[string]interface{} {
	name = strings.TrimSpace(name)
	if !validVPNSourceDisplayName(name) {
		return map[string]interface{}{"success": false, "error": "Используйте название до 80 символов без ссылок и переносов строк."}
	}
	return a.changeVPNSourceMetadata(id, func(source *VPNSource) error {
		source.Name = name
		return nil
	})
}

func (a *App) SetVPNSourceNodeFavorite(id, nodeID string, favorite bool) map[string]interface{} {
	if !validVPNFavoriteNodeID(nodeID) {
		return map[string]interface{}{"success": false, "error": "Сервер не найден. Обновите список."}
	}
	return a.changeVPNSourceMetadata(id, func(source *VPNSource) error {
		ids := normalizeVPNFavoriteNodeIDs(source.FavoriteNodeIDs)
		found, exists := false, false
		for _, candidate := range source.NodeIDs {
			found = found || candidate == nodeID
		}
		for _, candidate := range ids {
			exists = exists || candidate == nodeID
		}
		if favorite && !found {
			return fmt.Errorf("сервер не найден в этом источнике; обновите список")
		}
		if favorite && !exists {
			if len(ids) >= maxVPNSourceFavorites {
				return fmt.Errorf("в одном источнике можно сохранить до 64 избранных серверов")
			}
			ids = append(ids, nodeID)
		}
		if !favorite {
			filtered := make([]string, 0, len(ids))
			for _, candidate := range ids {
				if candidate != nodeID {
					filtered = append(filtered, candidate)
				}
			}
			ids = filtered
		}
		source.FavoriteNodeIDs = ids
		return nil
	})
}

// Metadata edits never build, download, restart or invalidate a traffic plan.
// Serialize with profile/reconnect transactions so their rollback cannot undo
// a concurrent successful edit; update only the current source under storage.mu.
func (a *App) changeVPNSourceMetadata(id string, change func(*VPNSource) error) map[string]interface{} {
	a.waitForInit()
	if id == "" || len(id) > 128 || normalizeVPNSourceID(id) != id {
		return map[string]interface{}{"success": false, "error": "Источник не найден. Обновите список."}
	}
	a.settingsPolicyMu.Lock()
	defer a.settingsPolicyMu.Unlock()
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	if a.storage == nil {
		return map[string]interface{}{"success": false, "error": "Хранилище источников ещё не готово."}
	}
	if err := a.storage.changeActiveVPNSourceMetadata(id, change); err != nil {
		return map[string]interface{}{"success": false, "error": err.Error()}
	}
	a.emitEvent("vpn-sources-changed", map[string]interface{}{})
	return map[string]interface{}{"success": true, "metadataOnly": true, "restarted": false}
}

func (s *Storage) changeActiveVPNSourceMetadata(id string, change func(*VPNSource) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for p := range s.data.Profiles {
		profile := &s.data.Profiles[p]
		if profile.ID != s.data.App.ActiveProfileID {
			continue
		}
		for n, source := range profile.VPNSources {
			if source.ID != id {
				continue
			}
			source.FavoriteNodeIDs = append([]string(nil), source.FavoriteNodeIDs...)
			if err := change(&source); err != nil {
				return err
			}
			previous := profile.VPNSources
			profile.VPNSources = append([]VPNSource(nil), previous...)
			profile.VPNSources[n] = source
			if err := s.saveInternal(); err != nil {
				profile.VPNSources = previous
				return fmt.Errorf("не удалось сохранить изменение источника; повторите попытку")
			}
			return nil
		}
	}
	return fmt.Errorf("источник не найден; обновите список")
}
