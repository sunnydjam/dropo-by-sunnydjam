package main

import (
	"encoding/base64"
	"fmt"
	"net"
	"sort"
	"strings"

	traffic "dropo/trafficorchestrator"
)

const selectiveHostsDisabledMarker = "# dropo-selective-vpn-disabled:"
const selectiveHostsFakeMarker = "# dropo-selective-vpn-fake"

type selectiveFakeHostMapping struct {
	Address string
	Host    string
}

type selectiveNameResolutionLease interface {
	Update(selectiveNameResolutionPlan) error
	Restore() error
	DisabledMappings() int
	PrimedMappings() int
}

type selectiveNameResolutionPlan struct {
	Plan      traffic.TrafficPlan
	Directory *traffic.FakeIPDirectory
}

func selectedFakeHostMappings(plan traffic.TrafficPlan, directory *traffic.FakeIPDirectory) []selectiveFakeHostMapping {
	if directory == nil {
		return nil
	}
	selected := make(map[string]bool, len(plan.Routes))
	for _, route := range plan.Routes {
		selected[route.ServiceID] = route.Kind == traffic.ServiceRouteVPN || route.Kind == traffic.ServiceRouteZapret || route.Kind == traffic.ServiceRouteUnavailable
	}
	hosts := make([]string, 0)
	for _, service := range plan.Services {
		if selected[service.ID] {
			hosts = append(hosts, service.ExactHosts...)
		}
	}
	sort.Strings(hosts)
	result := make([]selectiveFakeHostMapping, 0, len(hosts))
	for _, host := range hosts {
		if target, ok := directory.ResolveHost(host); ok {
			result = append(result, selectiveFakeHostMapping{Address: target.Address.String(), Host: target.Host})
		}
	}
	return result
}

type selectiveDomains struct {
	exact  map[string]struct{}
	suffix map[string]struct{}
}

func newSelectiveDomains() selectiveDomains {
	return selectiveDomains{exact: make(map[string]struct{}), suffix: make(map[string]struct{})}
}

func (d selectiveDomains) matches(host string) bool {
	host = normalizeProxyHost(host)
	if _, ok := d.exact[host]; ok {
		return true
	}
	return hostMatchesSelectedSuffix(host, d.suffix)
}

type selectiveDomainPlan struct {
	owners                              map[string]traffic.ServiceRouteKind
	catalog                             []string
	catalogRoute                        traffic.ServiceRouteKind
	direct, vpn, zapret, unavailable    selectiveDomains
	work, mandatoryVPN, mandatoryDenied selectiveDomains
}

func selectiveDomainsForPlan(plan traffic.TrafficPlan) selectiveDomainPlan {
	result := selectiveDomainPlan{direct: newSelectiveDomains(), vpn: newSelectiveDomains(), zapret: newSelectiveDomains(), unavailable: newSelectiveDomains(), work: newSelectiveDomains(), mandatoryVPN: newSelectiveDomains(), mandatoryDenied: newSelectiveDomains()}
	add := func(set map[string]struct{}, hosts []string) {
		for _, h := range hosts {
			if host := normalizeProxyHost(h); host != "" {
				set[host] = struct{}{}
			}
		}
	}
	for _, work := range plan.WorkNetworks {
		add(result.work.suffix, work.DomainSuffixes)
		add(result.direct.suffix, work.DomainSuffixes)
	}
	for _, rule := range plan.DirectRules {
		add(result.direct.suffix, rule.DomainSuffixes)
	}
	routes := make(map[string]traffic.ServiceRouteKind, len(plan.Routes))
	for _, route := range plan.Routes {
		routes[route.ServiceID] = route.Kind
	}
	result.owners = selectiveProcessRoutes(plan, routes)
	for _, svc := range plan.Services {
		kind := routes[svc.ID]
		if svc.ID == commonBlockedServiceTag && (kind == traffic.ServiceRouteVPN || kind == traffic.ServiceRouteUnavailable) {
			result.catalog = svc.DomainSuffixes
			result.catalogRoute = kind
			continue
		}
		if svc.VPNOnly {
			scope := result.mandatoryVPN
			if kind != traffic.ServiceRouteVPN {
				scope = result.mandatoryDenied
				kind = traffic.ServiceRouteUnavailable
			}
			add(scope.exact, svc.ExactHosts)
			add(scope.suffix, svc.DomainSuffixes)
		}
		var d selectiveDomains
		switch kind {
		case traffic.ServiceRouteVPN:
			d = result.vpn
		case traffic.ServiceRouteZapret:
			d = result.zapret
		case traffic.ServiceRouteUnavailable:
			d = result.unavailable
		case traffic.ServiceRouteDirect:
			d = result.direct
		default:
			continue
		}
		add(d.exact, svc.ExactHosts)
		add(d.suffix, svc.DomainSuffixes)
	}
	return result
}

func (p selectiveDomainPlan) needsFake(host string) bool {
	if p.work.matches(host) {
		return false
	}
	if p.mandatoryVPN.matches(host) || p.mandatoryDenied.matches(host) {
		return true
	}
	if p.direct.matches(host) {
		return false
	}
	_, exactZapret := p.zapret.exact[normalizeProxyHost(host)]
	return p.vpn.matches(host) || p.unavailable.matches(host) || exactZapret
}

// installSelectiveFakeHosts appends only exact, positively classified service
// hosts. It never expands domain suffixes into shared-provider addresses. Each
// line is tagged so a normal Stop and a later crash-recovery Start can remove
// the overlay without changing unrelated user records.
func installSelectiveFakeHosts(input []byte, mappings []selectiveFakeHostMapping) ([]byte, int) {
	cleaned, _ := removeSelectiveFakeHosts(input)
	unique := make(map[string]selectiveFakeHostMapping, len(mappings))
	for _, mapping := range mappings {
		host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(mapping.Host)), ".")
		address := strings.TrimSpace(mapping.Address)
		if host == "" || net.ParseIP(address) == nil {
			continue
		}
		unique[host] = selectiveFakeHostMapping{Address: address, Host: host}
	}
	hosts := make([]string, 0, len(unique))
	for host := range unique {
		hosts = append(hosts, host)
	}
	sort.Strings(hosts)
	if len(hosts) == 0 {
		return cleaned, 0
	}
	ending := "\r\n"
	if len(cleaned) > 0 && !strings.Contains(string(cleaned), "\r\n") {
		ending = "\n"
	}
	var builder strings.Builder
	builder.Write(cleaned)
	if len(cleaned) > 0 && !strings.HasSuffix(string(cleaned), "\n") {
		builder.WriteString(ending)
	}
	for _, host := range hosts {
		mapping := unique[host]
		builder.WriteString(fmt.Sprintf("%s %s %s%s", mapping.Address, mapping.Host, selectiveHostsFakeMarker, ending))
	}
	return []byte(builder.String()), len(hosts)
}

func removeSelectiveFakeHosts(input []byte) ([]byte, int) {
	lines := splitLinesPreservingEndings(string(input))
	kept := lines[:0]
	removed := 0
	for _, line := range lines {
		body, _ := splitLineEnding(line)
		fields := strings.Fields(strings.TrimSpace(body))
		if len(fields) == 4 && fields[2] == "#" && fields[3] == "dropo-selective-vpn-fake" && net.ParseIP(fields[0]) != nil {
			removed++
			continue
		}
		kept = append(kept, line)
	}
	return []byte(strings.Join(kept, "")), removed
}

func restoreSelectiveHostsContent(input []byte) ([]byte, int) {
	output, removed := removeSelectiveFakeHosts(input)
	output, restored := restoreSelectedVPNHostsMappings(output)
	return output, removed + restored
}

// disableSelectedVPNHostsMappings comments only complete hosts-file records
// whose hostnames all belong to services currently routed through the
// selective VPN. Mixed records are left byte-for-byte unchanged and reported
// as conflicts, because disabling an unrelated name would violate the direct
// routing contract.
func disableSelectedVPNHostsMappings(input []byte, matches func(string) bool) ([]byte, int, int) {
	restored, _ := restoreSelectedVPNHostsMappings(input)
	lines := splitLinesPreservingEndings(string(restored))
	disabled := 0
	conflicts := 0
	for index, line := range lines {
		body, ending := splitLineEnding(line)
		trimmed := strings.TrimSpace(body)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) < 2 || net.ParseIP(fields[0]) == nil {
			continue
		}
		matched := 0
		hosts := 0
		for _, field := range fields[1:] {
			if strings.HasPrefix(field, "#") {
				break
			}
			hosts++
			if matches(field) {
				matched++
			}
		}
		if matched == 0 {
			continue
		}
		if matched != hosts {
			conflicts++
			continue
		}
		encoded := base64.StdEncoding.EncodeToString([]byte(body))
		lines[index] = selectiveHostsDisabledMarker + encoded + ending
		disabled += matched
	}
	return []byte(strings.Join(lines, "")), disabled, conflicts
}

func restoreSelectedVPNHostsMappings(input []byte) ([]byte, int) {
	lines := splitLinesPreservingEndings(string(input))
	restored := 0
	for index, line := range lines {
		body, ending := splitLineEnding(line)
		trimmed := strings.TrimSpace(body)
		if !strings.HasPrefix(trimmed, selectiveHostsDisabledMarker) {
			continue
		}
		encoded := strings.TrimSpace(strings.TrimPrefix(trimmed, selectiveHostsDisabledMarker))
		original, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			continue
		}
		lines[index] = string(original) + ending
		restored++
	}
	return []byte(strings.Join(lines, "")), restored
}

func hostMatchesSelectedSuffix(host string, suffixes map[string]struct{}) bool {
	host = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	if host == "" {
		return false
	}
	for suffix := range suffixes {
		if host == suffix || strings.HasSuffix(host, "."+suffix) {
			return true
		}
	}
	return false
}

func splitLinesPreservingEndings(value string) []string {
	if value == "" {
		return nil
	}
	lines := make([]string, 0, strings.Count(value, "\n")+1)
	for len(value) > 0 {
		index := strings.IndexByte(value, '\n')
		if index < 0 {
			lines = append(lines, value)
			break
		}
		lines = append(lines, value[:index+1])
		value = value[index+1:]
	}
	return lines
}

func splitLineEnding(line string) (string, string) {
	if strings.HasSuffix(line, "\r\n") {
		return strings.TrimSuffix(line, "\r\n"), "\r\n"
	}
	if strings.HasSuffix(line, "\n") {
		return strings.TrimSuffix(line, "\n"), "\n"
	}
	return line, ""
}
