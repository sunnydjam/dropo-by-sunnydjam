package dnspolicy

import (
	"bytes"
	"encoding/json"
	"maps"
	"slices"
	"strconv"
	"strings"
)

// JSON round trips turn integral ports into float64. Compare the wire shape,
// including every TLS and dial option, before reusing a managed transport.
func sameServer(a, b map[string]any) bool {
	left, err := json.Marshal(a)
	if err != nil {
		return false
	}
	right, err := json.Marshal(b)
	return err == nil && bytes.Equal(left, right)
}

func finlandDoH(tag string, throughVPN bool) map[string]any {
	server := Server(tag, throughVPN)
	server["server"] = FinlandIPv4
	server["tls"] = map[string]any{"enabled": true, "server_name": FinlandHostname}
	return server
}

// EnsurePreferredDialResolver handles explicit lookups which bypass DNS routing
// rules in sing-box. A duplicate or customized tag is left to its owner.
func EnsurePreferredDialResolver(dns map[string]any, tag string) string {
	if tag != "dns-direct" && tag != "dns-remote" {
		return tag
	}
	servers, _ := dns["servers"].([]any)
	var base, reserve map[string]any
	for _, raw := range servers {
		s, _ := raw.(map[string]any)
		switch s["tag"] {
		case tag:
			if base != nil {
				return tag
			}
			base = s
		case tag + "-fi":
			if reserve != nil {
				return tag
			}
			reserve = s
		}
	}
	viaVPN := base["detour"] == "proxy"
	if !sameServer(base, Server(tag, viaVPN)) {
		return tag
	}
	target := tag + "-fi"
	expected := finlandDoH(target, viaVPN)
	if reserve == nil {
		dns["servers"] = append(slices.Clip(servers), expected)
	} else if !sameServer(reserve, expected) {
		return tag
	}
	return target
}

// IsDropoDirectResolver recognizes only the stock direct resolver serialized
// by earlier releases. User and enterprise resolver definitions stay intact.
func IsDropoDirectResolver(server map[string]any) bool {
	if server["tag"] != "dns-direct" {
		return false
	}
	for _, viaVPN := range []bool{false, true} {
		expected := Server("dns-direct", viaVPN)
		if sameServer(server, expected) {
			return true
		}
		expected["server"] = legacyBootstrapIPv4
		if sameServer(server, expected) {
			return true
		}
	}
	return sameServer(server, map[string]any{"type": "udp", "tag": "dns-direct", "server": "77.88.8.8"})
}

// ConfigureRuntimeFailover expands only verified built-ins. sing-box 1.14's
// evaluate/respond rules bound each attempt and preserve the original detour.
// Explicit domain-resolver lookups keep their existing bootstrap transport.
func ConfigureRuntimeFailover(config map[string]interface{}) {
	servers, _ := config["servers"].([]interface{})
	rules, _ := config["rules"].([]interface{})
	final, _ := config["final"].(string)
	byTag := make(map[string]map[string]interface{}, len(servers))
	for _, raw := range servers {
		server, _ := raw.(map[string]interface{})
		tag, _ := server["tag"].(string)
		byTag[tag] = server
		if isManagedDoH(server, tag) && server["server"] == legacyBootstrapIPv4 {
			server["server"] = BootstrapIPv4
		}
	}
	for _, raw := range rules {
		rule, _ := raw.(map[string]interface{})
		tag, _ := rule["tag"].(string)
		if rule["action"] == "evaluate" && strings.HasPrefix(tag, "dropo-dns-") {
			return
		}
	}
	managed := make(map[string]bool, 2)
	for _, raw := range servers {
		server, _ := raw.(map[string]interface{})
		tag, _ := server["tag"].(string)
		if !isManagedDoH(server, tag) || server["server"] != BootstrapIPv4 {
			continue
		}
		reserves := []map[string]interface{}{
			finlandDoH(tag+"-fi", false),
			{"type": "tls", "tag": tag + "-lv", "server": LatviaIPv4, "server_port": 853, "tls": map[string]interface{}{"enabled": true, "server_name": LatviaHostname}},
		}
		clash := false
		for _, reserve := range reserves {
			if detour, ok := server["detour"]; ok {
				reserve["detour"] = detour
			}
			if existing := byTag[reserve["tag"].(string)]; existing != nil && !sameServer(existing, reserve) {
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
		for _, suffix := range []string{"-fi", ""} {
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

func isManagedDoH(server map[string]interface{}, tag string) bool {
	tls, _ := server["tls"].(map[string]interface{})
	return (tag == "dns-direct" || tag == "dns-remote") && server["type"] == "https" &&
		server["path"] == QueryPath && tls["enabled"] == true && tls["server_name"] == Hostname && tls["insecure"] != true
}
