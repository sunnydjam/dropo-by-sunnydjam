package main

import (
	"dropocore/aicatalog"
	"dropocore/dnspolicy"
	"errors"
	"maps"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	traffic "dropo/trafficorchestrator"
)

const customVPNRuleSet = "dropo-custom-vpn-domains"

func (a *App) SetCustomVPNService(id, name, domains string, remove bool) map[string]any {
	a.waitForInit()
	a.settingsPolicyMu.Lock()
	defer a.settingsPolicyMu.Unlock()
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	failure := func(err error) map[string]any {
		return map[string]any{"success": false, "error": err.Error()}
	}
	if runtime.GOOS != "windows" || a.storage == nil || a.isShuttingDown() {
		return failure(errors.New("Настройки маршрутов недоступны"))
	}
	a.mu.Lock()
	starting := a.isStarting
	a.mu.Unlock()
	if starting || a.vpnStopping.Load() || a.reconnecting.Load() {
		return failure(errors.New("Дождитесь завершения подключения или отключения VPN"))
	}
	previous := a.storage.GetAppSettings()
	next, err := aicatalog.EditCustomService(previous.CustomVPNServices, id, name, domains, remove)
	if err != nil {
		return failure(err)
	}
	settings := previous
	settings.CustomVPNServices = next
	if err := a.storage.UpdateAppSettings(settings); err != nil {
		return failure(err)
	}
	path := customVPNRuleSetPath(a.storage.GetResourcesPath())
	err = writeCustomVPNRuleSet(path, next)
	if err == nil && shouldUseSelectiveWindowsSession(settings) && a.trafficEngine != nil && a.trafficEngine.ActiveTag() != "" {
		a.serviceEngineComposeMu.Lock()
		plan := a.trafficEngine.CurrentPlan()
		plan.Services = slices.DeleteFunc(plan.Services, func(rule traffic.ServiceRule) bool { return rule.ID == customVPNRuleSet })
		plan.Routes = slices.DeleteFunc(plan.Routes, func(route traffic.ServiceRoute) bool { return route.ServiceID == customVPNRuleSet })
		appendCustomVPNPlanRule(&plan, next)
		err = a.trafficEngine.StartPlan(plan)
		a.serviceEngineComposeMu.Unlock()
	}
	if err != nil {
		return failure(errors.Join(err, writeCustomVPNRuleSet(path, previous.CustomVPNServices), a.storage.UpdateAppSettings(previous)))
	}
	return map[string]any{"success": true, "customVPNServices": next}
}

func customVPNRuleSetPath(resources string) string {
	return filepath.Join(resources, customVPNRuleSet+".json")
}

func writeCustomVPNRuleSet(path string, services []aicatalog.CustomService) error {
	rules := []any{}
	if domains := aicatalog.CustomDomains(services); len(domains) != 0 {
		rules = append(rules, map[string]any{"domain_suffix": domains})
	}
	return writeJSONConfig(path, map[string]any{"version": 4, "rules": rules})
}

// The bundled sing-box runtime watches local rule-set files. The guard and
// the connected TUN share the file, so changing the catalog keeps both alive.
func customVPNRuleSetConfig(path string) map[string]any {
	return map[string]any{"type": "local", "format": "source", "tag": customVPNRuleSet, "path": path}
}

func withCustomVPNRules(config map[string]any, path string) map[string]any {
	result := maps.Clone(config)
	route, _ := config["route"].(map[string]any)
	dns, _ := config["dns"].(map[string]any)
	if route == nil || dns == nil {
		return result
	}
	route, dns = maps.Clone(route), maps.Clone(dns)
	result["route"], result["dns"] = route, dns
	sets, _ := route["rule_set"].([]any)
	route["rule_set"] = append(slices.Clone(sets), customVPNRuleSetConfig(path))

	rules, _ := route["rules"].([]any)
	insert := 0
	for i, raw := range rules {
		rule, _ := raw.(map[string]any)
		if rule["action"] == "hijack-dns" || rule["ip_is_private"] == true || slices.Equal(interfaceStringSlice(rule["domain_suffix"]), LocalDomainSuffixes) {
			insert = i + 1
		}
	}
	outbounds, _ := config["outbounds"].([]any)
	match := []string{customVPNRuleSet}
	protected := map[string]any{"rule_set": match, "action": "reject"}
	vpnAvailable := protectedLinkUsesVPN(outbounds, "proxy", map[string]bool{})
	if vpnAvailable {
		protected["action"], protected["outbound"] = "route", "proxy"
	}
	route["rules"] = slices.Insert(slices.Clone(rules), insert, any(protected))
	servers, _ := dns["servers"].([]any)
	dnsRule := map[string]any{"rule_set": match, "action": "reject"}
	protectedDNSTags := make(map[string]bool)
	for _, raw := range servers {
		server, _ := raw.(map[string]any)
		if tag, ok := server["tag"].(string); ok && server["detour"] == "proxy" {
			protectedDNSTags[tag] = true
		}
	}
	if vpnAvailable && protectedDNSTags["dns-remote"] {
		dnsRule["action"], dnsRule["server"] = "route", "dns-remote"
	}
	protectedDNS := []any{dnsRule}
	if dnsRule["action"] == "route" && protectedDNSTags["dns-remote-fi"] && protectedDNSTags["dns-remote-lv"] {
		protectedDNS = dnspolicy.AppendRuntimeFailoverRules(nil, dnsRule, "dns-remote", customVPNRuleSet+"-dns-")
	}
	dnsRules, _ := dns["rules"].([]any)
	insert = 0
	for i, raw := range dnsRules {
		entry, _ := raw.(map[string]any)
		if entry["server"] == "dns-local" {
			insert = i + 1
		}
	}
	dns["rules"] = slices.Insert(slices.Clone(dnsRules), insert, protectedDNS...)
	return result
}

func appendCustomVPNPlanRule(plan *traffic.TrafficPlan, services []aicatalog.CustomService) {
	if domains := aicatalog.CustomDomains(services); len(domains) != 0 {
		plan.Services = append(plan.Services, traffic.ServiceRule{
			ID: customVPNRuleSet, DisplayName: "Custom VPN services", VPNOnly: true, DomainSuffixes: domains,
		})
		plan.Routes = append(plan.Routes, traffic.ServiceRoute{ServiceID: customVPNRuleSet, Kind: traffic.ServiceRouteVPN})
	}
}

func hostInCustomVPNList(host string, services []aicatalog.CustomService) bool {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	return slices.ContainsFunc(aicatalog.CustomDomains(services), func(domain string) bool {
		return host == domain || strings.HasSuffix(host, "."+domain)
	})
}
