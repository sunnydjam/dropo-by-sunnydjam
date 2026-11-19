package dnspolicy

import (
	"maps"
	"reflect"
	"strconv"
	"strings"
)

// ConfigureRuntimeFailover expands only verified built-ins. sing-box 1.14's
// evaluate/respond rules bound each attempt and preserve the original detour.
// Explicit domain-resolver lookups keep their existing bootstrap transport.
func ConfigureRuntimeFailover(config map[string]interface{}) {
	servers, _ := config["servers"].([]interface{})
	rules, _ := config["rules"].([]interface{})
	final, _ := config["final"].(string)
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		tag, _ := rule["tag"].(string)
		if rule["action"] == "evaluate" && strings.HasPrefix(tag, "dropo-dns-") {
			return
		}
	}
	byTag := make(map[string]map[string]interface{}, len(servers))
	for _, raw := range servers {
		server, _ := raw.(map[string]interface{})
		tag, _ := server["tag"].(string)
		byTag[tag] = server
	}
	managed := make(map[string]bool, 2)
	for _, raw := range servers {
		server, _ := raw.(map[string]interface{})
		tag, _ := server["tag"].(string)
		tls, _ := server["tls"].(map[string]interface{})
		if tag != "dns-direct" && tag != "dns-remote" || server["type"] != "https" || server["server"] != BootstrapIPv4 || server["path"] != QueryPath || tls["enabled"] != true || tls["server_name"] != Hostname || tls["insecure"] == true {
			continue
		}
		reserves := []map[string]interface{}{
			{"type": "https", "tag": tag + "-fi", "server": FinlandIPv4, "server_port": 443, "path": QueryPath, "tls": map[string]interface{}{"enabled": true, "server_name": FinlandHostname}},
			{"type": "tls", "tag": tag + "-lv", "server": LatviaIPv4, "server_port": 853, "tls": map[string]interface{}{"enabled": true, "server_name": LatviaHostname}},
		}
		clash := false
		for _, reserve := range reserves {
			if detour, ok := server["detour"]; ok {
				reserve["detour"] = detour
			}
			if existing := byTag[reserve["tag"].(string)]; existing != nil && !reflect.DeepEqual(existing, reserve) {
				clash = true
			}
		}
		if clash {
			continue
		}
		managed[tag] = true
		for _, reserve := range reserves {
			reserveTag := reserve["tag"].(string)
			if byTag[reserveTag] == nil {
				servers = append(servers, reserve)
				byTag[reserveTag] = reserve
			}
		}
	}
	if len(managed) == 0 {
		return
	}
	var expanded []interface{}
	appendChain := func(rule map[string]interface{}, tag string) {
		for _, suffix := range []string{"", "-fi"} {
			evaluation := maps.Clone(rule)
			resultTag := "dropo-dns-" + strconv.Itoa(len(expanded))
			evaluation["action"], evaluation["server"], evaluation["tag"], evaluation["timeout"] = "evaluate", tag+suffix, resultTag, "2s"
			expanded = append(expanded, evaluation)
			for _, response := range []string{"NOERROR", "NXDOMAIN"} {
				expanded = append(expanded, map[string]interface{}{"action": "respond", "match_response": resultTag, "response_rcode": response})
			}
		}
		last := maps.Clone(rule)
		last["server"], last["timeout"] = tag+"-lv", "2s"
		expanded = append(expanded, last)
	}
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		tag, _ := rule["server"].(string)
		if managed[tag] && rule["action"] == "route" {
			appendChain(rule, tag)
		} else {
			expanded = append(expanded, raw)
		}
	}
	if managed[final] {
		appendChain(map[string]interface{}{"action": "route", "domain_regex": []string{"^.+$"}}, final)
	}
	config["servers"], config["rules"] = servers, expanded
}
