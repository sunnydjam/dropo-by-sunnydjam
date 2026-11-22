package dropocore

import (
	"encoding/hex"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxAndroidSourceFavorites = 64

func validAndroidSourceDisplayName(name string) bool {
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

func validAndroidFavoriteNodeID(id string) bool {
	if len(id) != 64 || id != strings.ToLower(id) {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func normalizeAndroidFavoriteNodeIDs(ids []string) []string {
	result := make([]string, 0, min(len(ids), maxAndroidSourceFavorites))
	seen := make(map[string]bool, len(result))
	for _, id := range ids {
		if validAndroidFavoriteNodeID(id) && !seen[id] {
			result = append(result, id)
			seen[id] = true
			if len(result) == maxAndroidSourceFavorites {
				break
			}
		}
	}
	return result
}

func preserveAndroidSourceMetadata(next, live []androidVPNSource) {
	for i := range next {
		for _, previous := range live {
			if next[i].ID == previous.ID && next[i].URI == previous.URI {
				next[i].Name = previous.Name
				next[i].FavoriteNodeIDs = normalizeAndroidFavoriteNodeIDs(previous.FavoriteNodeIDs)
				break
			}
		}
	}
}

// Called under mu, also while connected. This only replaces presentation
// metadata and saves it atomically. Do not invalidate cached configs, traffic
// revision, session generation, probes or the immutable active source plan.
func changeAndroidSourceMetadataLocked(method string, args []interface{}) string {
	if len(args) < 2 {
		return androidSourceError("Не указаны параметры источника.")
	}
	id, valid := args[0].(string)
	if !valid || id == "" || len(id) > 128 {
		return androidSourceError("Источник не найден. Обновите список.")
	}
	index := -1
	for i, source := range current.VPNSources {
		if source.ID == id {
			index = i
			break
		}
	}
	if index < 0 {
		return androidSourceError("Источник не найден. Обновите список.")
	}
	source := current.VPNSources[index]
	source.FavoriteNodeIDs = normalizeAndroidFavoriteNodeIDs(source.FavoriteNodeIDs)
	switch method {
	case "RenameVPNSource":
		if len(args) != 2 {
			return androidSourceError("Неверные параметры названия источника.")
		}
		name, ok := args[1].(string)
		name = strings.TrimSpace(name)
		if !ok || !validAndroidSourceDisplayName(name) {
			return androidSourceError("Используйте название до 80 символов без ссылок и переносов строк.")
		}
		source.Name = name
	case "SetVPNSourceNodeFavorite":
		if len(args) != 3 {
			return androidSourceError("Не указано состояние избранного.")
		}
		nodeID, nodeOK := args[1].(string)
		favorite, valueOK := args[2].(bool)
		if !nodeOK || !valueOK || !validAndroidFavoriteNodeID(nodeID) {
			return androidSourceError("Неверные параметры избранного сервера.")
		}
		found, exists := false, false
		for _, node := range source.Nodes {
			found = found || androidNodeID(node) == nodeID
		}
		for _, candidate := range source.FavoriteNodeIDs {
			exists = exists || candidate == nodeID
		}
		if favorite && !found {
			return androidSourceError("Сервер не найден в этом источнике. Обновите список.")
		}
		if favorite && !exists {
			if len(source.FavoriteNodeIDs) >= maxAndroidSourceFavorites {
				return androidSourceError("В одном источнике можно сохранить до 64 избранных серверов.")
			}
			source.FavoriteNodeIDs = append(source.FavoriteNodeIDs, nodeID)
		}
		if !favorite {
			filtered := make([]string, 0, len(source.FavoriteNodeIDs))
			for _, candidate := range source.FavoriteNodeIDs {
				if candidate != nodeID {
					filtered = append(filtered, candidate)
				}
			}
			source.FavoriteNodeIDs = filtered
		}
	default:
		return androidSourceError("Неизвестная операция с источником.")
	}
	previous := current.VPNSources
	previousError := current.LastError
	current.VPNSources = append([]androidVPNSource(nil), previous...)
	current.VPNSources[index] = source
	if err := saveLocked(); err != nil {
		current.VPNSources = previous
		// The operation reports its persistence error to the UI. A failed star
		// or rename must not replace the live VPN's health/error indication.
		current.LastError = previousError
		return androidSourceError(androidSubscriptionSaveError)
	}
	emitLocked("vpn-sources-changed", map[string]interface{}{})
	return encode(map[string]interface{}{"success": true, "metadataOnly": true, "restarted": false})
}
