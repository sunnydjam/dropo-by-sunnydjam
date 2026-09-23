package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

type VPNSourceKind string

const (
	VPNSourceSubscription VPNSourceKind = "subscription"
	VPNSourceDirect       VPNSourceKind = "direct"
)

// VPNSource is one fallback unit. A subscription may contain many nodes, but
// only SelectedNode participates in routing. Failover advances to the next
// enabled VPNSource, never silently to another node of this source.
type VPNSource struct {
	ID              string        `json:"id"`
	Name            string        `json:"name"`
	Kind            VPNSourceKind `json:"kind"`
	PublicCatalogID string        `json:"public_catalog_id,omitempty"`
	URI             string        `json:"uri"`
	Disabled        bool          `json:"disabled,omitempty"`
	SelectedNode    int           `json:"selected_node"`
	SelectedNodeID  string        `json:"selected_node_id,omitempty"`
	NodeCount       int           `json:"node_count,omitempty"`
	NodeNames       []string      `json:"node_names,omitempty"`
	NodeIDs         []string      `json:"node_ids,omitempty"`
	CachedNodes     []string      `json:"cached_nodes,omitempty"`
	LastUpdated     string        `json:"last_updated,omitempty"`
	LastError       string        `json:"last_error,omitempty"`
	UsingCache      bool          `json:"using_cache,omitempty"`
}

func newVPNSource(id, name, uri string) (VPNSource, error) {
	uri = strings.TrimSpace(uri)
	if uri == "" {
		return VPNSource{}, fmt.Errorf("VPN source URI is empty")
	}
	kind := VPNSourceSubscription
	if isDirectProxyLink(uri) {
		kind = VPNSourceDirect
		proxy, err := (&SubscriptionFetcher{}).ParseSingleLink(uri)
		if err != nil || proxy.Server == "" || proxy.ServerPort < 1 || proxy.ServerPort > 65535 {
			return VPNSource{}, fmt.Errorf("VPN key must contain a valid server address and port")
		}
	} else if err := validateSubscriptionURL(uri); err != nil {
		return VPNSource{}, err
	}
	id = normalizeVPNSourceID(id)
	if id == "" {
		return VPNSource{}, fmt.Errorf("VPN source id is invalid")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		if kind == VPNSourceDirect {
			name = "VPN key"
		} else {
			name = "VPN subscription"
		}
	}
	return VPNSource{ID: id, Name: name, Kind: kind, URI: uri}, nil
}

// hasConfiguredVPNSource checks whether the active profile can produce a VPN
// outbound without making a network request. A subscription's actual nodes are
// still validated by the config builder; this guard prevents full-tunnel mode
// from silently using its direct-only fallback when no source is configured.
func hasConfiguredVPNSource(profile *ProfileData) bool {
	if profile == nil {
		return false
	}
	sources := profile.VPNSources
	if len(sources) == 0 && strings.TrimSpace(profile.SubscriptionURL) != "" {
		sources = []VPNSource{{ID: "legacy", URI: profile.SubscriptionURL}}
	}
	for _, source := range sources {
		if source.Disabled {
			continue
		}
		uri := strings.TrimSpace(source.URI)
		if uri == "" {
			continue
		}
		if isDirectProxyLink(uri) {
			proxy, err := (&SubscriptionFetcher{}).ParseSingleLink(uri)
			if err == nil && proxy.Server != "" && proxy.ServerPort > 0 && proxy.ServerPort <= 65535 {
				split := SplitProxyConfigs([]ProxyConfig{proxy})
				if len(split.SingBox)+len(split.XrayBridge) > 0 {
					return true
				}
			}
			continue
		}
		if validateSubscriptionURL(uri) == nil {
			return true
		}
	}
	return false
}

func normalizeVPNSourceID(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var builder strings.Builder
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' {
			builder.WriteRune(character)
		}
	}
	return strings.Trim(builder.String(), "-")
}

func normalizeProfileVPNSources(profile *ProfileData) {
	if profile == nil {
		return
	}
	if len(profile.VPNSources) == 0 && strings.TrimSpace(profile.SubscriptionURL) != "" {
		if source, err := newVPNSource("source-1", "Primary", profile.SubscriptionURL); err == nil {
			source.NodeCount = profile.ProxyCount
			source.LastUpdated = profile.LastUpdated
			profile.VPNSources = []VPNSource{source}
		}
	}
	seen := map[string]struct{}{}
	for index := range profile.VPNSources {
		source := &profile.VPNSources[index]
		baseID := normalizeVPNSourceID(source.ID)
		if baseID == "" {
			baseID = fmt.Sprintf("source-%d", index+1)
		}
		id := baseID
		for suffix := 2; ; suffix++ {
			if _, duplicate := seen[id]; !duplicate {
				break
			}
			id = fmt.Sprintf("%s-%d", baseID, suffix)
		}
		seen[id] = struct{}{}
		source.ID = id
		if source.Kind == "" {
			if isDirectProxyLink(source.URI) {
				source.Kind = VPNSourceDirect
			} else {
				source.Kind = VPNSourceSubscription
			}
		}
		if source.Name == "" {
			source.Name = fmt.Sprintf("VPN source %d", index+1)
		}
		if source.SelectedNode < 0 || (source.NodeCount > 0 && source.SelectedNode >= source.NodeCount) {
			source.SelectedNode = 0
		}
	}
	normalizePublicVPNSourceMetadata(profile.VPNSources)
	profile.SubscriptionURL = ""
	profile.ProxyCount = 0
	profile.LastUpdated = ""
	for _, source := range profile.VPNSources {
		if source.Disabled {
			continue
		}
		if profile.SubscriptionURL == "" {
			profile.SubscriptionURL = source.URI
			profile.LastUpdated = source.LastUpdated
		}
		profile.ProxyCount += source.NodeCount
	}
}

func nextVPNSourceID(sources []VPNSource) string {
	used := map[string]struct{}{}
	for _, source := range sources {
		used[source.ID] = struct{}{}
	}
	for index := 1; ; index++ {
		candidate := fmt.Sprintf("source-%d", index)
		if _, exists := used[candidate]; !exists {
			return candidate
		}
	}
}

func markVPNSourceUpdated(source *VPNSource, nodes []ProxyConfig, err error) {
	if source == nil {
		return
	}
	if err != nil {
		source.LastError = err.Error()
		return
	}
	// Migrate old fingerprints (which included display labels) using the saved
	// key before replacing the cache. Manual selection must survive refreshed
	// country/latency labels and provider reordering.
	if source.SelectedNodeID != "" {
		for index, id := range source.NodeIDs {
			if id == source.SelectedNodeID && index < len(source.CachedNodes) {
				if node, parseErr := (&SubscriptionFetcher{}).ParseSingleLink(source.CachedNodes[index]); parseErr == nil {
					source.SelectedNodeID = vpnNodeFingerprint(node)
				}
				break
			}
		}
	}
	source.NodeCount = len(nodes)
	source.NodeNames = make([]string, 0, len(nodes))
	source.NodeIDs = make([]string, 0, len(nodes))
	source.CachedNodes = make([]string, 0, len(nodes))
	for index, node := range nodes {
		name := strings.TrimSpace(node.Name)
		if name == "" {
			name = fmt.Sprintf("Node %d", index+1)
		}
		source.NodeNames = append(source.NodeNames, name)
		source.NodeIDs = append(source.NodeIDs, vpnNodeFingerprint(node))
		if strings.TrimSpace(node.Raw) != "" {
			source.CachedNodes = append(source.CachedNodes, node.Raw)
		}
	}
	selectedIDMatched := source.SelectedNodeID == ""
	if source.SelectedNodeID != "" {
		for index, nodeID := range source.NodeIDs {
			if nodeID == source.SelectedNodeID {
				source.SelectedNode = index
				selectedIDMatched = true
				break
			}
		}
	}
	if !selectedIDMatched || source.SelectedNode < 0 || source.SelectedNode >= len(nodes) {
		source.SelectedNode = 0
	}
	if len(source.NodeIDs) > 0 {
		source.SelectedNodeID = source.NodeIDs[source.SelectedNode]
	}
	source.LastUpdated = time.Now().Format("2006-01-02 15:04:05")
	source.LastError = ""
	source.UsingCache = false
}

// Xray-backed nodes are constructed separately from native sing-box nodes.
// Restore the user's source order afterwards so bootstrap and the background
// health monitor agree even when native and XHTTP sources are interleaved.
func orderVPNSourceProxies(proxies []ProxyConfig, sources []VPNSource) {
	positions := make(map[string]int, len(sources))
	for index, source := range sources {
		positions["vpn-source-"+source.ID] = index
	}
	position := func(tag string) int {
		if index, ok := positions[tag]; ok {
			return index
		}
		return len(sources)
	}
	sort.SliceStable(proxies, func(i, j int) bool {
		return position(proxies[i].Tag) < position(proxies[j].Tag)
	})
}

func vpnNodeFingerprint(node ProxyConfig) string {
	if node.Raw != "" {
		if parsed, err := (&SubscriptionFetcher{}).ParseSingleLink(node.Raw); err == nil {
			node = parsed
		}
	}
	node.Raw, node.Name, node.Tag = "", "", ""
	node.Server = strings.ToLower(strings.TrimSpace(node.Server))
	node.Network = NormalizeTransport(node.Network)
	identity, _ := json.Marshal(node)
	digest := sha256.Sum256(identity)
	return fmt.Sprintf("%x", digest[:12])
}
