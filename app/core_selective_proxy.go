package main

import (
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"

	traffic "dropo/trafficorchestrator"
)

type selectiveProxyRoutingLease interface {
	Update(traffic.TrafficPlan) error
	Restore() error
	PACURL() string
	DomainCount() int
}

func buildSelectiveProxyPAC(vpnProxyAddress, zapretProxyAddress string, plan selectiveDomainPlan) (string, []string, error) {
	return (*pacCatalogCache)(nil).build(vpnProxyAddress, zapretProxyAddress, plan)
}

type pacCatalogCache struct {
	domains []string
	encoded string
}

func (cache *pacCatalogCache) build(vpnProxyAddress, zapretProxyAddress string, plan selectiveDomainPlan) (string, []string, error) {
	vpnProxyAddress = strings.TrimSpace(vpnProxyAddress)
	zapretProxyAddress = strings.TrimSpace(zapretProxyAddress)
	vpnCount := len(plan.vpn.suffix) + len(plan.vpn.exact)
	zapretCount := len(plan.zapret.suffix) + len(plan.zapret.exact)
	if (vpnCount > 0 || len(plan.catalog) > 0 && plan.catalogRoute == traffic.ServiceRouteVPN) && vpnProxyAddress == "" {
		return "", nil, fmt.Errorf("selective VPN proxy address is empty")
	}
	unavailableCount := len(plan.unavailable.suffix) + len(plan.unavailable.exact)
	if (zapretCount+unavailableCount > 0 || len(plan.catalog) > 0 && plan.catalogRoute == traffic.ServiceRouteUnavailable) && zapretProxyAddress == "" {
		return "", nil, fmt.Errorf("selective Zapret proxy address is empty")
	}
	if vpnCount+zapretCount+unavailableCount+len(plan.catalog) == 0 {
		return "", nil, nil
	}
	directConditions := append(pacExactConditions(plan.direct.exact), pacDomainConditions(orderedDomainSuffixes(plan.direct.suffix))...)
	var script strings.Builder
	if len(plan.catalog) > 0 {
		if cache != nil && slices.Equal(cache.domains, plan.catalog) {
			script.WriteString(cache.encoded)
		} else {
			writePACCatalog(&script, plan.catalog)
			if cache != nil {
				cache.domains = slices.Clone(plan.catalog)
				cache.encoded = script.String()
			}
		}
	}
	script.WriteString("function FindProxyForURL(url, host) {\n" +
		"  host = host.toLowerCase();\n" +
		"  if (host.length > 0 && host.charAt(host.length - 1) === \".\") host = host.slice(0, -1);\n")
	writePolicy := func(domains selectiveDomains, decision string) {
		conditions := append(pacExactConditions(domains.exact), pacDomainConditions(orderedDomainSuffixes(domains.suffix))...)
		if len(conditions) > 0 {
			script.WriteString("  if (" + strings.Join(conditions, " ||\n      ") + ") return " + strconv.Quote(decision) + ";\n")
		}
	}
	writePolicy(plan.work, "DIRECT")
	writePolicy(plan.mandatoryDenied, "PROXY "+zapretProxyAddress)
	writePolicy(plan.mandatoryVPN, "PROXY "+vpnProxyAddress)
	if len(directConditions) > 0 {
		script.WriteString("  if (" + strings.Join(directConditions, " ||\n      ") + ") return \"DIRECT\";\n")
	}
	var all []string
	// Test exact names first, then the longest suffix. A shared, equally
	// specific entry has no unique terminal and safely stays direct.
	for _, exact := range []bool{true, false} {
		vpn, zapret, unavailable := plan.vpn.suffix, plan.zapret.suffix, plan.unavailable.suffix
		if exact {
			vpn, zapret, unavailable = plan.vpn.exact, plan.zapret.exact, plan.unavailable.exact
		}
		names := append(orderedDomainSuffixes(vpn), orderedDomainSuffixes(zapret)...)
		sort.Strings(names)
		names = uniqueOrderedStrings(append(names, orderedDomainSuffixes(unavailable)...))
		sort.SliceStable(names, func(i, j int) bool { return len(names[i]) > len(names[j]) })
		for _, name := range names {
			all = append(all, name)
			_, v := vpn[name]
			_, z := zapret[name]
			condition := "host === " + strconv.Quote(name)
			if !exact {
				condition = pacDomainConditions([]string{name})[0]
			}
			result := strconv.Quote("DIRECT")
			_, denied := unavailable[name]
			switch {
			case denied:
				// This listener rejects hosts outside its active Zapret route scope before dialing.
				result = strconv.Quote("PROXY " + zapretProxyAddress)
			case v && !z:
				result = strconv.Quote("PROXY " + vpnProxyAddress)
			case z && !v:
				result = "url.substring(0, 6).toLowerCase() === \"https:\" ? " + strconv.Quote("PROXY "+zapretProxyAddress) + " : \"DIRECT\""
			}
			script.WriteString("  if (" + condition + ") return " + result + ";\n")
		}
	}
	if len(plan.catalog) > 0 {
		proxy := vpnProxyAddress
		if plan.catalogRoute == traffic.ServiceRouteUnavailable {
			proxy = zapretProxyAddress
		}
		script.WriteString("  for (var n = host; n; ) { if (dropoCatalog['.' + n]) return " + strconv.Quote("PROXY "+proxy) + "; var dot = n.indexOf('.'); if (dot < 0) break; n = n.slice(dot+1); }\n")
		all = append(all, plan.catalog...)
	}
	script.WriteString("  return \"DIRECT\";\n}\n")
	sort.Strings(all)
	return script.String(), uniqueOrderedStrings(all), nil
}

// Front-code sorted, reversed ASCII hostnames to keep the shipped PAC below
// Chromium's PAC size limit. Decode once per script, then check label suffixes.
func writePACCatalog(script *strings.Builder, domains []string) {
	keys := make([]string, 0, len(domains))
	for _, domain := range domains {
		labels := strings.Split(domain, ".")
		slices.Reverse(labels)
		keys = append(keys, strings.Join(labels, "."))
	}
	sort.Strings(keys)
	var data strings.Builder
	prev := ""
	for i, key := range keys {
		if i > 0 {
			data.WriteByte('|')
		}
		prefix := 0
		for prefix < len(prev) && prefix < len(key) && prev[prefix] == key[prefix] {
			prefix++
		}
		data.WriteString(strconv.Itoa(prefix))
		data.WriteByte(':')
		data.WriteString(key[prefix:])
		prev = key
	}
	script.WriteString("var dropoCatalog = {}; (function(data) { var rows=data.split('|'), prev=''; for (var i=0; i<rows.length; i++) {var row=rows[i], p=row.indexOf(':'); prev=prev.slice(0,Number(row.slice(0,p)))+row.slice(p+1); dropoCatalog['.'+prev.split('.').reverse().join('.')]=true;} })(" + strconv.Quote(data.String()) + ");\n")
}

func uniqueOrderedStrings(values []string) []string {
	if len(values) < 2 {
		return values
	}
	result := values[:0]
	for _, value := range values {
		if len(result) == 0 || result[len(result)-1] != value {
			result = append(result, value)
		}
	}
	return result
}

func orderedDomainSuffixes(suffixes map[string]struct{}) []string {
	ordered := make([]string, 0, len(suffixes))
	for suffix := range suffixes {
		suffix = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(suffix)), ".")
		if suffix != "" {
			ordered = append(ordered, suffix)
		}
	}
	sort.Strings(ordered)
	return ordered
}

func pacDomainConditions(ordered []string) []string {
	conditions := make([]string, 0, len(ordered))
	for _, suffix := range ordered {
		quoted := strconv.Quote(suffix)
		conditions = append(conditions, "host === "+quoted+" || dnsDomainIs(host, \".\" + "+quoted+")")
	}
	return conditions
}

func pacExactConditions(hosts map[string]struct{}) []string {
	var conditions []string
	for _, host := range orderedDomainSuffixes(hosts) {
		conditions = append(conditions, "host === "+strconv.Quote(host))
	}
	return conditions
}
