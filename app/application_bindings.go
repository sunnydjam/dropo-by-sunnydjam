package main

import (
	"dropocore/aicatalog"
	"errors"
	"fmt"
	"maps"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
)

const personalAppVPN = "user-app-vpn"

type applicationBinding struct {
	Path    string `json:"path"`
	Service string `json:"service"`
}

func applicationPathPattern(path string) string {
	return "(?i)^" + regexp.QuoteMeta(path) + "$"
}

func catalogApplicationRules() []any {
	var names, domains, hosts []string
	for _, svc := range DefaultFreeAccessServices {
		if aicatalog.VPNOnly(svc.Tag) {
			continue
		}
		names = append(names, svc.ProcessNames...)
		if svc.Tag == "discord" {
			domains = append(domains, svc.DomainSuffixes...)
			hosts = append(hosts, svc.ExactHosts...)
		}
	}
	return []any{
		map[string]any{"process_name": uniqueStrings(names), "action": "route", "outbound": "proxy"},
		map[string]any{"domain_suffix": uniqueStrings(domains), "action": "route", "outbound": "proxy"},
		map[string]any{"domain": uniqueStrings(hosts), "action": "route", "outbound": "proxy"},
	}
}

func hasCatalogApplicationRules(route map[string]any) bool {
	rules, _ := route["rules"].([]any)
	for _, raw := range rules {
		r, _ := raw.(map[string]any)
		if r["outbound"] == "proxy" && r["network"] == nil && slices.Contains(interfaceStringSlice(r["process_name"]), "Discord.exe") {
			return true
		}
	}
	return false
}

// Upgrade cached catalog profiles locally. Reuse the existing protected DNS
// failover rules so their evaluate/respond tags and work-network priority survive.
func migrateCatalogApplications(config map[string]any) {
	route, _ := config["route"].(map[string]any)
	if route == nil || hasCatalogApplicationRules(route) {
		return
	}
	rules, _ := route["rules"].([]any)
	insert := slices.IndexFunc(rules, func(raw any) bool {
		r, _ := raw.(map[string]any)
		tags := interfaceStringSlice(r["rule_set"])
		return slices.Contains(tags, "refilter-domains") || slices.Contains(tags, "refilter-ips") || slices.Contains(interfaceStringSlice(r["domain_regex"]), blockedOnlyKnownDomainRegex)
	})
	if insert < 0 {
		insert = len(rules)
	}
	route["rules"] = slices.Insert(slices.Clone(rules), insert, catalogApplicationRules()...)
	discord, _ := findFreeAccessService("discord")
	dns, _ := config["dns"].(map[string]any)
	dnsRules, _ := dns["rules"].([]any)
	for _, raw := range dnsRules {
		r, _ := raw.(map[string]any)
		if names := interfaceStringSlice(r["domain_suffix"]); slices.Contains(names, "claude.ai") {
			r["domain_suffix"] = uniqueStrings(append(slices.Clone(names), discord.DomainSuffixes...))
		}
		if names := interfaceStringSlice(r["domain"]); slices.Contains(names, "chatgpt.com") {
			r["domain"] = uniqueStrings(append(slices.Clone(names), discord.ExactHosts...))
		}
	}
}

// Runtime overlay also covers persisted profiles created before executable bindings.
func applyApplicationBindings(config map[string]any, settings GlobalAppSettings) {
	route, _ := config["route"].(map[string]any)
	rules, _ := route["rules"].([]any)
	// Profiles keep local/work and runtime exceptions ahead of this consecutive
	// group. Find the group from catalog data, including older saved profiles.
	insert := slices.IndexFunc(rules, func(raw any) bool {
		r, _ := raw.(map[string]any)
		return isProtectedApplicationRule(r)
	})
	if insert < 0 {
		return
	}
	for insert < len(rules) {
		r, _ := rules[insert].(map[string]any)
		if !isProtectedApplicationRule(r) {
			break
		}
		insert++
	}
	var entries []any
	all := NormalizeRoutingMode(settings.RoutingMode) == RoutingModeAllTraffic
	outbounds, _ := config["outbounds"].([]any)
	hasVPN := outboundTagExists(outbounds, "auto-select")
	for _, binding := range settings.ApplicationBindings {
		if binding.Service != personalAppVPN {
			continue
		}
		rule := map[string]any{"process_path_regex": []string{applicationPathPattern(binding.Path)}, "action": "reject"}
		if protectedLinkUsesVPN(outbounds, "proxy", map[string]bool{}) {
			rule["action"], rule["outbound"] = "route", "proxy"
		}
		entries = append(entries, rule)
	}
	for _, svc := range DefaultFreeAccessServices {
		if aicatalog.VPNOnly(svc.Tag) {
			continue
		}
		target := "proxy"
		if !all {
			target = FreeAccessServiceRouteOutboundForSettings(svc, settings, hasVPN)
		}
		var matches []map[string]any
		if !all && len(svc.ProcessNames) > 0 {
			matches = append(matches, map[string]any{"process_name": svc.ProcessNames})
		}
		for _, binding := range settings.ApplicationBindings {
			if binding.Service == svc.Tag {
				matches = append(matches, map[string]any{"process_path_regex": []string{applicationPathPattern(binding.Path)}})
			}
		}
		for _, match := range matches {
			if !all && svc.Tag == "discord" {
				realtime := maps.Clone(match)
				realtime["action"], realtime["outbound"], realtime["network"] = "route", discordRealtimeGroupTag, "udp"
				entries = append(entries, realtime)
			}
			match["action"], match["outbound"] = "route", target
			entries = append(entries, match)
		}
	}
	route["rules"] = slices.Insert(slices.Clone(rules), insert, entries...)
}

func isProtectedApplicationRule(rule map[string]any) bool {
	for _, svc := range DefaultFreeAccessServices {
		if !aicatalog.VPNOnly(svc.Tag) {
			continue
		}
		for field, values := range map[string][]string{"domain": svc.ExactHosts, "domain_suffix": svc.DomainSuffixes, "process_name": svc.ProcessNames} {
			if len(values) > 0 && slices.Equal(interfaceStringSlice(rule[field]), values) {
				return true
			}
		}
	}
	return false
}

func isCustomBindingTarget(services []aicatalog.CustomService, tag string) bool {
	return slices.ContainsFunc(services, func(s aicatalog.CustomService) bool { return s.ID == tag })
}

func editApplicationBinding(settings GlobalAppSettings, oldPath, path, tag string) ([]applicationBinding, error) {
	next := slices.Clone(settings.ApplicationBindings)
	if oldPath != "" {
		i := slices.IndexFunc(next, func(b applicationBinding) bool { return strings.EqualFold(b.Path, oldPath) })
		if i < 0 {
			return nil, errors.New("Привязка уже изменена. Обновите список")
		}
		if path != "" && strings.EqualFold(next[i].Path, filepath.Clean(strings.Trim(strings.TrimSpace(path), "\""))) && next[i].Service == tag {
			return next, nil
		}
		next = slices.Delete(next, i, i+1)
		if path == "" {
			return next, nil
		}
	}
	path = filepath.Clean(strings.Trim(strings.TrimSpace(path), "\""))
	if len(path) > 32767 || !filepath.IsAbs(path) || len(filepath.VolumeName(path)) != 2 || strings.ContainsAny(path[2:], ":*?\"<>|\r\n") || !strings.EqualFold(filepath.Ext(path), ".exe") {
		return nil, errors.New("Укажите полный локальный путь к файлу .exe")
	}
	if _, ok := findFreeAccessService(tag); !ok && tag != personalAppVPN && !isCustomBindingTarget(settings.CustomVPNServices, tag) {
		return nil, errors.New("Неизвестный сервис")
	}
	name := filepath.Base(path)
	for _, svc := range DefaultFreeAccessServices {
		if slices.ContainsFunc(svc.ProcessNames, func(n string) bool { return strings.EqualFold(n, name) }) {
			return nil, fmt.Errorf("%s уже входит во встроенный каталог %s", name, svc.DisplayName)
		}
	}
	switch strings.ToLower(name) {
	case "sing-box.exe", "xray.exe", "dropo.exe", "dropo-core.exe", "dropo-ui.exe", "tg-ws-proxy.exe", "wireguard.exe", "wg.exe", "svchost.exe", "system.exe", "services.exe":
		return nil, errors.New("Системный или служебный процесс нельзя привязать к сервису")
	}
	if len(next) >= 128 {
		return nil, errors.New("Достигнут предел в 128 привязок")
	}
	if slices.ContainsFunc(next, func(b applicationBinding) bool { return strings.EqualFold(b.Path, path) }) {
		return nil, errors.New("Этот файл уже привязан")
	}
	return append(next, applicationBinding{Path: path, Service: tag}), nil
}

func (a *App) GetApplicationBindings() map[string]any {
	a.waitForInit()
	if a.storage == nil {
		return map[string]any{"success": false, "error": "Хранилище недоступно"}
	}
	settings := a.storage.GetAppSettings()
	services := map[string]string{personalAppVPN: "Через VPN"}
	for _, svc := range DefaultFreeAccessServices {
		services[svc.Tag] = svc.DisplayName
	}
	for _, svc := range settings.CustomVPNServices {
		services[svc.ID] = svc.Name
	}
	return map[string]any{"success": true, "bindings": settings.ApplicationBindings, "services": services}
}

func (a *App) SetApplicationBinding(oldPath, path, tag string) map[string]any {
	return a.editLocalRouting("Применяем настройки приложения", func(next *GlobalAppSettings) (bool, error) {
		bindings, err := editApplicationBinding(*next, oldPath, path, tag)
		changed := !slices.Equal(next.ApplicationBindings, bindings)
		next.ApplicationBindings = bindings
		return changed, err
	})
}

func (a *App) SetPersonalAddress(value string, remove bool) map[string]any {
	return a.editLocalRouting("Применяем настройки адреса", func(next *GlobalAppSettings) (bool, error) {
		entries, err := next.PersonalAddresses.Edit(value, remove)
		if err != nil {
			return false, err
		}
		next.PersonalAddresses = entries
		return true, nil
	})
}

func (a *App) editLocalRouting(reason string, edit func(*GlobalAppSettings) (bool, error)) map[string]any {
	a.waitForInit()
	a.settingsPolicyMu.Lock()
	defer a.settingsPolicyMu.Unlock()
	a.vpnLifecycleMu.Lock()
	defer a.vpnLifecycleMu.Unlock()
	fail := func(err error) map[string]any { return map[string]any{"success": false, "error": err.Error()} }
	if runtime.GOOS != "windows" || a.storage == nil || a.isShuttingDown() {
		return fail(errors.New("Хранилище недоступно"))
	}
	a.mu.Lock()
	running, starting := a.isRunning, a.isStarting
	a.mu.Unlock()
	if starting || a.vpnStopping.Load() || a.reconnecting.Load() {
		return fail(errors.New("Дождитесь завершения подключения"))
	}
	previous := a.storage.GetAppSettings()
	next := previous
	changed, err := edit(&next)
	if err != nil {
		return fail(err)
	}
	if !changed {
		return map[string]any{"success": true, "bindings": next.ApplicationBindings}
	}
	if running {
		generation := a.beginVPNTransactionalReconnect(reason)
		defer a.finishVPNTransactionalReconnect(generation)
		if r := a.stopVPNForReconnect(); !apiResultSucceeded(r) {
			return r
		}
	}
	save := func(s GlobalAppSettings) error {
		if err := writeCustomVPNRuleSet(customVPNRuleSetPath(a.storage.GetResourcesPath()), s.CustomVPNServices, s.ApplicationBindings...); err != nil {
			return err
		}
		return a.storage.UpdateAppSettings(s)
	}
	err = save(next)
	if err == nil && running {
		if r := a.startVPNForReconnect(); !apiResultSucceeded(r) && !apiResultCancelled(r) {
			err = errors.New(apiResultMessage(r))
		}
	}
	if err != nil {
		rollback := save(previous)
		recovery := a.recoverAfterServicePolicyRollback(running, rollback == nil)
		return fail(fmt.Errorf("%w%s", errors.Join(err, rollback), recovery))
	}
	return map[string]any{"success": true, "bindings": next.ApplicationBindings}
}
