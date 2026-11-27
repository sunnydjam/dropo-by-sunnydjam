package blockedlist

import (
	"errors"
	"net/netip"
	"slices"
	"strings"

	"golang.org/x/net/idna"
	"golang.org/x/net/publicsuffix"
)

type Personal []string

func (entries Personal) Edit(input string, remove bool) (Personal, error) {
	value := strings.TrimSpace(input)
	if value == "" || len(value) > 1024 {
		return nil, errors.New("Введите домен, публичный IP или подсеть")
	}
	prefix, err := netip.ParsePrefix(value)
	if addr, e := netip.ParseAddr(value); e == nil {
		if addr.Zone() != "" {
			return nil, errors.New("Введите адрес без идентификатора интерфейса")
		}
		addr = addr.Unmap()
		prefix, err = addr.Prefix(addr.BitLen())
	}
	if err == nil {
		prefix = prefix.Masked()
		if !publicCatalogPrefix(prefix) || prefix.Addr().Is4In6() || prefix.Contains(netip.MustParseAddr("10.0.0.0")) || prefix.Contains(netip.MustParseAddr("172.16.0.0")) || prefix.Contains(netip.MustParseAddr("192.168.0.0")) {
			return nil, errors.New("Укажите публичный IP или подсеть вне локальной сети")
		}
		value = prefix.String()
	} else {
		domain, e := idna.Lookup.ToASCII(strings.TrimSuffix(strings.ToLower(value), "."))
		_, suffixErr := publicsuffix.EffectiveTLDPlusOne(domain)
		if e != nil || suffixErr != nil || !validCatalogDomain(domain) || strings.ContainsAny(domain, "_") || strings.Trim(domain, "0123456789.") == "" {
			return nil, errors.New("Укажите домен без схемы и порта, IP или подсеть")
		}
		value = domain
	}
	idx := slices.Index(entries, value)
	if remove {
		if idx < 0 {
			return nil, errors.New("Запись уже удалена")
		}
		return slices.Delete(slices.Clone(entries), idx, idx+1), nil
	}
	if idx >= 0 {
		return nil, errors.New("Запись уже есть в вашем списке")
	}
	if len(entries) >= 256 {
		return nil, errors.New("Можно добавить до 256 адресов")
	}
	return append(slices.Clone(entries), value), nil
}

func (entries Personal) Split() (domains, ips []string) {
	for _, entry := range entries {
		if strings.Contains(entry, "/") {
			ips = append(ips, entry)
		} else {
			domains = append(domains, entry)
		}
	}
	return
}

const PersonalIPTag = "dropo-user-ips"

// Extend the same rule-set matches as the bundled lists, including logical DNS
// rules. Their position relative to application, work and known-domain rules stays intact.
func (entries Personal) Apply(config map[string]any) {
	if len(entries) == 0 {
		return
	}
	route, _ := config["route"].(map[string]any)
	if route == nil {
		return
	}
	dns, _ := config["dns"].(map[string]any)
	domains, ips := entries.Split()
	sets, _ := route["rule_set"].([]any)
	for _, group := range []struct {
		ref, tag, field string
		values          []string
	}{
		{"refilter-domains", "dropo-user-domains", "domain_suffix", domains},
		{"refilter-ips", PersonalIPTag, "ip_cidr", ips},
	} {
		if len(group.values) == 0 {
			continue
		}
		sets = append(sets, map[string]any{"type": "inline", "tag": group.tag, "rules": []any{map[string]any{group.field: group.values}}})
		extendMatches(route, group.ref, group.tag)
		extendMatches(dns, group.ref, group.tag)
	}
	route["rule_set"] = sets
}

func extendMatches(section map[string]any, ref, tag string) {
	rules, _ := section["rules"].([]any)
	for _, raw := range rules {
		rule, _ := raw.(map[string]any)
		var names []string
		switch v := rule["rule_set"].(type) {
		case []string:
			names = slices.Clone(v)
		case []any:
			for _, n := range v {
				if s, ok := n.(string); ok {
					names = append(names, s)
				}
			}
		case string:
			names = []string{v}
		}
		if slices.Contains(names, ref) {
			rule["rule_set"] = append(names, tag)
		}
		extendMatches(rule, ref, tag)
	}
}
