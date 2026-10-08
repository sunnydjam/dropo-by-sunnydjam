package dropocore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
)

// Android stores independent subscriptions, not a flattened list of servers.
// Credentials and parsed nodes stay in app-private storage, never in source views.
type androidVPNSource struct {
	ID               string        `json:"id"`
	Name             string        `json:"name"`
	URI              string        `json:"uri"`
	Disabled         bool          `json:"disabled"`
	SelectedNodeID   string        `json:"selected_node_id,omitempty"`
	Nodes            []proxyConfig `json:"nodes,omitempty"`
	UpdatedAt        string        `json:"updated_at,omitempty"`
	LastRefreshError string        `json:"last_refresh_error,omitempty"`
	PendingNodes     []proxyConfig `json:"pending_nodes,omitempty"`
	PendingUpdatedAt string        `json:"pending_updated_at,omitempty"`
}

const maxAndroidVPNSources = 16

// Tests may inject a parser. Production uses the context-aware built-in parser.
var androidSourceParser func(string) ([]proxyConfig, error)

func androidNodeID(node proxyConfig) string {
	node.Tag, node.Name, node.Raw = "", "", ""
	data, _ := json.Marshal(node)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

func androidSelectedNode(source androidVPNSource) int {
	if source.SelectedNodeID == "" {
		return 0
	}
	for i, node := range source.Nodes {
		if androidNodeID(node) == source.SelectedNodeID {
			return i
		}
	}
	return -1
}

func migrateAndroidSourcesLocked() {
	if current.VPNSources != nil {
		return
	}
	current.VPNSources = []androidVPNSource{}
	if strings.TrimSpace(current.Subscription) != "" {
		current.VPNSources = append(current.VPNSources, androidVPNSource{
			ID: "source-1", Name: "Моя подписка", URI: current.Subscription,
		})
	}
}

func primaryAndroidSourceLocked() *androidVPNSource {
	for i := range current.VPNSources {
		if !current.VPNSources[i].Disabled {
			return &current.VPNSources[i]
		}
	}
	return nil
}

func syncAndroidSubscriptionLocked() {
	current.Subscription, current.SubscriptionProxyCount = "", 0
	if source := primaryAndroidSourceLocked(); source != nil {
		current.Subscription = source.URI
		current.SubscriptionProxyCount = len(source.Nodes)
	}
}

func androidSourcesBusyLocked() bool {
	return current.Connected || current.ServiceState == "starting" || current.ServiceState == "disconnecting"
}

func androidSourcesViewLocked() map[string]interface{} {
	migrateAndroidSourcesLocked()
	views := make([]map[string]interface{}, 0, len(current.VPNSources))
	for _, source := range current.VPNSources {
		names := make([]string, 0, len(source.Nodes))
		for i, node := range source.Nodes {
			name := strings.TrimSpace(node.Name)
			// Never display a raw key as a server label.
			if name == "" || strings.Contains(name, "://") {
				name = fmt.Sprintf("Сервер %d", i+1)
			}
			names = append(names, name)
		}
		kind := "subscription"
		if isDirectProxyLink(source.URI) {
			kind = "key"
		}
		problem := source.LastRefreshError
		publicID := ""
		if isAndroidPublicSource(source.URI) {
			publicID = androidPublicSourceID
		}
		if androidSelectedNode(source) < 0 {
			problem = "Выбранный сервер исчез из подписки. Выберите другой сервер."
		}
		views = append(views, map[string]interface{}{
			"public_catalog_id": publicID,
			"id":                source.ID, "name": source.Name, "kind": kind, "disabled": source.Disabled,
			"selected_node": androidSelectedNode(source), "node_count": len(source.Nodes),
			"node_names": names, "last_updated": source.UpdatedAt, "last_error": problem,
			"active":   current.Connected && current.activeSourceID == source.ID,
			"response": androidSourceResponseLocked(source.ID),
		})
	}
	return map[string]interface{}{"success": true, "sources": views, "running": current.Connected,
		"autoSelect": current.VPNSourceAutoSelect, "autoSelectSupported": true, "fallbackSupported": true}
}

// Mutations are transactional and allowed only while stopped. Network parsing
// is deliberately outside mu so a slow provider cannot block status or Stop.
func changeAndroidSources(method string, args []interface{}) string {
	mu.Lock()
	migrateAndroidSourcesLocked()
	if androidSourcesBusyLocked() {
		mu.Unlock()
		return androidSourceError("Отключите VPN перед изменением источников.")
	}
	revision := current.sourcesRevision
	autoSelect := current.VPNSourceAutoSelect
	sources := append([]androidVPNSource(nil), current.VPNSources...)
	mu.Unlock()

	find := func(id string) int {
		for i := range sources {
			if sources[i].ID == id {
				return i
			}
		}
		return -1
	}
	id := stringArg(args, 0, "")
	index := find(id)
	switch method {
	case "EnableVPNSourceAutoSelect":
		autoSelect = true
		if len(args) > 0 {
			value, ok := args[0].(bool)
			if !ok {
				return androidSourceError("Неверное состояние автовыбора.")
			}
			autoSelect = value
		}
	case "AddVPNSource":
		if len(sources) >= maxAndroidVPNSources {
			return androidSourceError("Можно сохранить не более 16 источников.")
		}
		uri := strings.TrimSpace(stringArg(args, 1, ""))
		if err := validateAndroidSubscriptionLocally(uri); err != nil {
			return androidSourceError(err.Error())
		}
		if isAndroidPublicSource(uri) {
			uri = androidPublicSourceURL
		}
		for _, source := range sources {
			if source.URI == uri || (isAndroidPublicSource(source.URI) && uri == androidPublicSourceURL) {
				return androidSourceError("Этот источник уже добавлен.")
			}
		}
		name := strings.TrimSpace(id)
		if name == "" {
			name = "Мой VPN"
		}
		if len([]rune(name)) > 80 || strings.ContainsAny(name, "\r\n") || strings.Contains(name, "://") {
			return androidSourceError("Используйте короткое название без ссылок и переносов строк.")
		}
		nodes, err := parseAndroidSource(uri)
		if err != nil || len(nodes) == 0 {
			return androidSourceError(androidSubscriptionTestError)
		}
		for n := 1; ; n++ {
			id = fmt.Sprintf("source-%d", n)
			if find(id) < 0 {
				break
			}
		}
		sources = append(sources, androidVPNSource{ID: id, Name: name, URI: uri, Nodes: nodes, UpdatedAt: currentTimeRFC3339()})
	case "RefreshVPNSources":
		// A failed refresh leaves the complete old pool and chosen nodes intact.
		var workers sync.WaitGroup
		limit := make(chan struct{}, 4)
		failures := make(chan bool, len(sources))
		for i := range sources {
			if sources[i].Disabled {
				continue
			}
			limit <- struct{}{}
			workers.Add(1)
			go func(i int) {
				defer workers.Done()
				defer func() { <-limit }()
				mu.Lock()
				stale := current.sourcesRevision != revision || androidSourcesBusyLocked()
				mu.Unlock()
				if stale {
					failures <- true
					return
				}
				nodes, err := parseAndroidSource(sources[i].URI)
				if err != nil || len(nodes) == 0 {
					failures <- true
					return
				}
				sources[i].Nodes, sources[i].UpdatedAt = nodes, currentTimeRFC3339()
				sources[i].PendingNodes, sources[i].PendingUpdatedAt, sources[i].LastRefreshError = nil, "", ""
			}(i)
		}
		workers.Wait()
		if len(failures) > 0 {
			return androidSourceError("Не удалось обновить список серверов. Сохранённые источники не изменены.")
		}
	case "RemoveVPNSource", "SetVPNSourceEnabled", "SetVPNSourceNode", "MoveVPNSource":
		if index < 0 {
			return androidSourceError("Источник не найден. Обновите список.")
		}
		switch method {
		case "RemoveVPNSource":
			sources = append(sources[:index], sources[index+1:]...)
		case "SetVPNSourceEnabled":
			if len(args) < 2 {
				return androidSourceError("Не указано состояние источника.")
			}
			enabled, ok := args[1].(bool)
			if !ok {
				return androidSourceError("Неверное состояние источника.")
			}
			sources[index].Disabled = !enabled
		case "SetVPNSourceNode", "MoveVPNSource":
			if len(args) < 2 {
				return androidSourceError("Не указан номер элемента.")
			}
			raw, ok := args[1].(float64)
			n := int(raw)
			limit := len(sources)
			if method == "SetVPNSourceNode" {
				limit = len(sources[index].Nodes)
			}
			if !ok || raw != float64(n) || n < 0 || n >= limit {
				return androidSourceError("Элемент списка не найден.")
			}
			if method == "SetVPNSourceNode" {
				sources[index].SelectedNodeID = androidNodeID(sources[index].Nodes[n])
			} else {
				autoSelect = false
				source := sources[index]
				sources = append(sources[:index], sources[index+1:]...)
				sources = append(sources, androidVPNSource{})
				copy(sources[n+1:], sources[n:])
				sources[n] = source
			}
		}
	default:
		return androidSourceError("Неизвестная операция с источниками.")
	}

	mu.Lock()
	defer mu.Unlock()
	if revision != current.sourcesRevision || androidSourcesBusyLocked() {
		return androidSourceError("Состояние VPN изменилось. Повторите действие после отключения.")
	}
	previous := captureAndroidSubscriptionStateLocked()
	previousAutoSelect := current.VPNSourceAutoSelect
	oldSources := current.VPNSources
	current.VPNSources = sources
	current.VPNSourceAutoSelect = autoSelect
	syncAndroidSubscriptionLocked()
	clearCachedConfigLocked()
	if err := saveLocked(); err != nil {
		current.VPNSources = oldSources
		current.VPNSourceAutoSelect = previousAutoSelect
		restoreAndroidSubscriptionStateLocked(previous)
		return androidSourceError(androidSubscriptionSaveError)
	}
	current.sourcesRevision++
	emitLocked("vpn-sources-changed", map[string]interface{}{})
	return encode(map[string]interface{}{"success": true})
}

func androidSourceError(message string) string {
	return encode(map[string]interface{}{"success": false, "error": message})
}
