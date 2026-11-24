package main

import (
	"fmt"
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
	vpnProxyAddress = strings.TrimSpace(vpnProxyAddress)
	zapretProxyAddress = strings.TrimSpace(zapretProxyAddress)
	vpnCount := len(plan.vpn.suffix) + len(plan.vpn.exact)
	zapretCount := len(plan.zapret.suffix) + len(plan.zapret.exact)
	if vpnCount > 0 && vpnProxyAddress == "" {
		return "", nil, fmt.Errorf("selective VPN proxy address is empty")
	}
	if zapretCount > 0 && zapretProxyAddress == "" {
		return "", nil, fmt.Errorf("selective Zapret proxy address is empty")
	}
	if vpnCount+zapretCount == 0 {
		return "", nil, nil
	}
	directConditions := append(pacExactConditions(plan.direct.exact), pacDomainConditions(orderedDomainSuffixes(plan.direct.suffix))...)
	var script strings.Builder
	script.WriteString("function FindProxyForURL(url, host) {\n" +
		"  host = host.toLowerCase();\n" +
		"  if (host.length > 0 && host.charAt(host.length - 1) === \".\") host = host.slice(0, -1);\n")
	if len(directConditions) > 0 {
		script.WriteString("  if (" + strings.Join(directConditions, " ||\n      ") + ") return \"DIRECT\";\n")
	}
	var all []string
	// Test exact names first, then the longest suffix. A shared, equally
	// specific entry has no unique terminal and safely stays direct.
	for _, exact := range []bool{true, false} {
		vpn, zapret := plan.vpn.suffix, plan.zapret.suffix
		if exact {
			vpn, zapret = plan.vpn.exact, plan.zapret.exact
		}
		names := append(orderedDomainSuffixes(vpn), orderedDomainSuffixes(zapret)...)
		sort.Strings(names)
		names = uniqueOrderedStrings(names)
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
			switch {
			case v && !z:
				result = strconv.Quote("PROXY " + vpnProxyAddress)
			case z && !v:
				result = "url.substring(0, 6).toLowerCase() === \"https:\" ? " + strconv.Quote("PROXY "+zapretProxyAddress) + " : \"DIRECT\""
			}
			script.WriteString("  if (" + condition + ") return " + result + ";\n")
		}
	}
	script.WriteString("  return \"DIRECT\";\n}\n")
	sort.Strings(all)
	return script.String(), uniqueOrderedStrings(all), nil
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
