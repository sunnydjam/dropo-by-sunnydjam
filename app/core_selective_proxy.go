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

func buildSelectiveProxyPAC(vpnProxyAddress, zapretProxyAddress string, vpnSuffixes, zapretSuffixes, directSuffixes map[string]struct{}) (string, []string, error) {
	vpnProxyAddress = strings.TrimSpace(vpnProxyAddress)
	zapretProxyAddress = strings.TrimSpace(zapretProxyAddress)
	vpnOrdered := orderedDomainSuffixes(vpnSuffixes)
	zapretOrdered := orderedDomainSuffixes(zapretSuffixes)
	if len(vpnOrdered) > 0 && vpnProxyAddress == "" {
		return "", nil, fmt.Errorf("selective VPN proxy address is empty")
	}
	if len(zapretOrdered) > 0 && zapretProxyAddress == "" {
		return "", nil, fmt.Errorf("selective Zapret proxy address is empty")
	}
	if len(vpnOrdered)+len(zapretOrdered) == 0 {
		return "", nil, nil
	}
	vpnConditions := pacDomainConditions(vpnOrdered)
	zapretConditions := pacDomainConditions(zapretOrdered)
	directOrdered := orderedDomainSuffixes(directSuffixes)
	directConditions := pacDomainConditions(directOrdered)
	script := "function FindProxyForURL(url, host) {\n" +
		"  host = host.toLowerCase();\n" +
		"  if (host.length > 0 && host.charAt(host.length - 1) === \".\") host = host.slice(0, -1);\n"
	if len(directConditions) > 0 {
		script += "  if (" + strings.Join(directConditions, " ||\n      ") + ") return \"DIRECT\";\n"
	}
	if len(vpnConditions) > 0 {
		script += "  if (" + strings.Join(vpnConditions, " ||\n      ") + ") return \"PROXY " + vpnProxyAddress + "\";\n"
	}
	if len(zapretConditions) > 0 {
		// PAC sends only TLS CONNECT traffic to the scoped relay. Plain HTTP is
		// left direct instead of turning the relay into a general forward proxy.
		script += "  if (url.substring(0, 6).toLowerCase() === \"https:\" && (" + strings.Join(zapretConditions, " ||\n      ") + ")) return \"PROXY " + zapretProxyAddress + "\";\n"
	}
	script += "  return \"DIRECT\";\n" + "}\n"
	all := append(append([]string(nil), vpnOrdered...), zapretOrdered...)
	sort.Strings(all)
	return script, uniqueOrderedStrings(all), nil
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
