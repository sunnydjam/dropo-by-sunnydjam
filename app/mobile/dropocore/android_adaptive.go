package dropocore

import (
	"strings"
	"time"
)

const AndroidAdaptiveSelectorPrefix = "adaptive-tls-"

type androidAdaptiveRecord struct {
	Method    string `json:"method"`
	CheckedAt string `json:"checkedAt"`
	Successes int    `json:"successes"`
	Fallback  bool   `json:"fallback"`
}
type androidAdaptiveService struct {
	Tag     string   `json:"tag"`
	Targets []string `json:"targets"`
}

// This candidate covers HTTPS/TCP only. QUIC, calls, unknown protocols and
// ports keep the VPN route. There is no Android WinDivert/zapret executable.
func androidAdaptiveServices(policies map[string]string) []androidAdaptiveService {
	allowed := map[string]bool{"youtube": true, "meta": true, "facebook": true, "twitter": true, "linkedin": true, "twitch": true, "spotify": true, "canva": true, "notion": true, "openai": true}
	out := []androidAdaptiveService{}
	for _, service := range androidServiceCatalog() {
		if !allowed[service.Tag] || androidServicePolicy(service, policies) != androidRoutePolicyAuto {
			continue
		}
		targets := uniqueNonEmptyStrings(append([]string{service.HealthURL}, service.ProbeURLs...))
		if len(targets) == 0 || len(targets) > 6 {
			continue
		}
		valid := true
		for _, target := range targets {
			if !strings.HasPrefix(target, "https://") {
				valid = false
			}
		}
		if valid {
			out = append(out, androidAdaptiveService{service.Tag, targets})
		}
	}
	return out
}

func addAndroidAdaptiveGraph(config map[string]interface{}, policies map[string]string) {
	outbounds := config["outbounds"].([]interface{})
	route := config["route"].(map[string]interface{})
	rules := route["rules"].([]interface{})
	adaptive := []interface{}{}
	for _, candidate := range androidAdaptiveServices(policies) {
		service, _ := androidServiceByTag(candidate.Tag)
		tag := AndroidAdaptiveSelectorPrefix + candidate.Tag
		outbounds = append(outbounds, map[string]interface{}{"type": "selector", "tag": tag, "outbounds": []string{"proxy", "direct"}, "default": "proxy", "interrupt_exist_connections": true})
		adaptive = append(adaptive, map[string]interface{}{"network": "tcp", "protocol": "tls", "port": 443, "domain_suffix": append([]string(nil), service.DomainSuffixes...), "action": "route", "outbound": tag, "tls_record_fragment": true})
	}
	// The first four rules preserve sniff/DNS and private/work boundaries.
	if len(rules) >= 4 {
		next := append([]interface{}{}, rules[:4]...)
		next = append(next, adaptive...)
		rules = append(next, rules[4:]...)
	}
	config["outbounds"], route["rules"] = outbounds, rules
}

func AndroidAdaptivePlan() string {
	mu.Lock()
	defer mu.Unlock()
	services := []androidAdaptiveService{}
	if current.Connected && normalizeAndroidRoutingMode(current.Config.RoutingMode) == "all_traffic" {
		services = androidAdaptiveServices(androidRoutePoliciesLocked())
	}
	return encode(map[string]interface{}{"generation": current.sourceSession, "services": services, "method": "tls_record_fragment", "attempts": 3, "udp": "vpn"})
}

// The immutable graph permits only a narrow HTTPS service selector. Apply and
// persistence are fenced by the same lock used by disconnect. Cache is a local
// observation, never authorization to bypass fresh 3/3 checks on a new network.
func CommitAndroidAdaptive(generation int64, tag string, successes int, selector AndroidSourceSelector) bool {
	mu.Lock()
	defer mu.Unlock()
	if generation <= 0 || current.sourceSession != generation || !current.Connected || current.Config.RoutingMode != "all_traffic" || selector == nil {
		return false
	}
	eligible := false
	for _, s := range androidAdaptiveServices(androidRoutePoliciesLocked()) {
		if s.Tag == tag {
			eligible = true
			break
		}
	}
	if !eligible || successes != 0 && successes != 3 {
		return false
	}
	selected := "proxy"
	if successes == 3 {
		selected = "direct"
	}
	if !selector.SelectSourceTag(selected) {
		return false
	}
	if current.AdaptiveCache == nil {
		current.AdaptiveCache = map[string]androidAdaptiveRecord{}
	}
	if current.adaptiveActive == nil {
		current.adaptiveActive = map[string]bool{}
	}
	current.adaptiveActive[tag] = successes == 3
	current.AdaptiveCache[tag] = androidAdaptiveRecord{"tls_record_fragment", time.Now().UTC().Format(time.RFC3339), successes, successes != 3}
	if err := saveLocked(); err != nil {
		selector.SelectSourceTag("proxy")
		current.adaptiveActive[tag] = false
		return false
	}
	emitLocked("service-strategy-changed", map[string]interface{}{"tag": tag, "method": selected, "tlsOnly": true, "udp": "vpn"})
	return true
}

func ResetAndroidAdaptive(generation int64) {
	mu.Lock()
	defer mu.Unlock()
	if current.sourceSession == generation {
		current.adaptiveActive = nil
	}
}

func sanitizeAndroidAdaptiveCacheLocked() {
	if len(current.AdaptiveCache) > 16 {
		current.AdaptiveCache = nil
		return
	}
	for tag, record := range current.AdaptiveCache {
		_, ok := androidServiceByTag(tag)
		at, err := time.Parse(time.RFC3339, record.CheckedAt)
		if !ok || err != nil || record.Method != "tls_record_fragment" || record.Successes != 0 && record.Successes != 3 || time.Since(at) > 24*time.Hour || at.After(time.Now().Add(time.Minute)) {
			delete(current.AdaptiveCache, tag)
		}
	}
}

func AndroidAdaptiveServiceDomains(tag string) string {
	for _, s := range androidAdaptiveServices(nil) {
		if s.Tag == tag {
			service, _ := androidServiceByTag(tag)
			return encode(service.DomainSuffixes)
		}
	}
	return "[]"
}
