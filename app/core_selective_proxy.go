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

func buildSelectiveProxyPAC(proxyAddress string, suffixes, directSuffixes map[string]struct{}) (string, []string, error) {
	proxyAddress = strings.TrimSpace(proxyAddress)
	if proxyAddress == "" {
		return "", nil, fmt.Errorf("selective proxy address is empty")
	}
	ordered := make([]string, 0, len(suffixes))
	for suffix := range suffixes {
		suffix = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(suffix)), ".")
		if suffix != "" {
			ordered = append(ordered, suffix)
		}
	}
	sort.Strings(ordered)
	if len(ordered) == 0 {
		return "", nil, nil
	}
	conditions := pacDomainConditions(ordered)
	directOrdered := orderedDomainSuffixes(directSuffixes)
	directConditions := pacDomainConditions(directOrdered)
	script := "function FindProxyForURL(url, host) {\n" +
		"  host = host.toLowerCase();\n" +
		"  if (host.length > 0 && host.charAt(host.length - 1) === \".\") host = host.slice(0, -1);\n"
	if len(directConditions) > 0 {
		script += "  if (" + strings.Join(directConditions, " ||\n      ") + ") return \"DIRECT\";\n"
	}
	script += "  if (" + strings.Join(conditions, " ||\n      ") + ") return \"PROXY " + proxyAddress + "\";\n" +
		"  return \"DIRECT\";\n" +
		"}\n"
	return script, ordered, nil
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
