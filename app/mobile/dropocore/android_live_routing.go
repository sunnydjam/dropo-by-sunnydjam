package dropocore

import (
	"dropocore/aicatalog"
	"encoding/json"
	"errors"
	"slices"
	"strings"
)

type androidRoutingChange struct {
	mode, tag, method string
	policies          map[string]string
	customServices    []aicatalog.CustomService
	personal          androidPersonalRouting
	unchanged         bool
}

func prepareAndroidRoutingChangeLocked(method string, args []interface{}) (androidRoutingChange, error) {
	change := androidRoutingChange{mode: current.Config.RoutingMode, policies: androidRoutePoliciesLocked(), customServices: current.CustomVPNServices, personal: current.Personal}
	if method == "SetPersonalAddress" {
		entries, err := change.personal.Addresses.Edit(stringArg(args, 0, ""), boolArg(args, 1, false))
		change.personal.Addresses = entries
		return change, err
	}
	if method == "SetApplicationBinding" {
		err := change.personal.editPackage(stringArg(args, 0, ""), stringArg(args, 1, ""), stringArg(args, 2, ""))
		return change, err
	}
	if method == "SetCustomVPNService" {
		var err error
		change.customServices, err = aicatalog.EditCustomService(current.CustomVPNServices,
			stringArg(args, 0, ""), stringArg(args, 1, ""), stringArg(args, 2, ""), boolArg(args, 3, false))
		change.unchanged = slices.EqualFunc(change.customServices, current.CustomVPNServices, func(a, b aicatalog.CustomService) bool {
			return a.ID == b.ID && a.Name == b.Name && slices.Equal(a.Domains, b.Domains)
		})
		return change, err
	}
	if method == "SetRoutingMode" {
		mode := normalizeAndroidRoutingMode(stringArg(args, 0, change.mode))
		if mode == "" {
			return change, errors.New("Unknown routing mode")
		}
		change.unchanged, change.mode = mode == change.mode, mode
		return change, nil
	}
	change.tag = stringArg(args, 0, "")
	change.method = normalizeAndroidRoutePolicy(stringArg(args, 1, ""))
	service, ok := androidServiceByTag(change.tag)
	if !ok {
		return change, errors.New("Unknown Android route service: " + change.tag)
	}
	if aicatalog.VPNOnly(change.tag) && change.method != androidRoutePolicyVPN {
		return change, errors.New("Для сервиса обязателен VPN")
	}
	if change.method == "" {
		return change, errors.New("Unknown Android route policy")
	}
	change.unchanged = androidServicePolicy(service, change.policies) == change.method
	if change.method == androidServicePolicy(service, nil) {
		delete(change.policies, change.tag)
	} else {
		if change.policies == nil {
			change.policies = make(map[string]string)
		}
		change.policies[change.tag] = change.method
	}
	return change, nil
}

func (change androidRoutingChange) saveLocked() error {
	if change.unchanged {
		return nil
	}
	previousMode, previousPolicies := current.Config.RoutingMode, current.RoutePolicies
	previousPersonal := current.Personal
	previousServices := current.CustomVPNServices
	previousCache, prepared := captureAndroidSubscriptionStateLocked(), current.preparedSources
	current.Config.RoutingMode, current.RoutePolicies = change.mode, change.policies
	current.Personal = change.personal
	current.CustomVPNServices = change.customServices
	clearCachedConfigLocked()
	if current.Connected {
		current.preparedSources = prepared
	}
	if err := saveLocked(); err != nil {
		current.Config.RoutingMode, current.RoutePolicies = previousMode, previousPolicies
		current.Personal = previousPersonal
		current.CustomVPNServices = previousServices
		restoreAndroidSubscriptionStateLocked(previousCache)
		current.preparedSources = prepared
		return err
	}
	current.sourcesRevision++
	appendLogLocked("android routing policy changed")
	return nil
}

func (change androidRoutingChange) resultLocked(applied bool) string {
	result := map[string]interface{}{"success": true, "mode": change.mode, "applied": applied, "unchanged": change.unchanged,
		"customVPNServices": change.customServices}
	if change.tag != "" {
		effective := androidEffectiveRoutePoliciesForMode(change.policies, current.Subscription != "", change.mode)[change.tag]
		if aicatalog.VPNOnly(change.tag) {
			effective = androidRoutePolicyVPN
		}
		result["tag"], result["method"] = change.tag, change.method
		result["methodLabel"], result["effectiveMethodLabel"] = androidRoutePolicyLabel(change.method), androidRoutePolicyLabel(effective)
		if effective == "" {
			result["effectiveMethodLabel"] = "По каталогу блокировок"
		}
		result["requiresVpn"] = effective == androidRoutePolicyVPN
	}
	return encode(result)
}

func setAndroidRoutingLocked(method string, args []interface{}) string {
	if androidSourcesBusyLocked() {
		return androidSourceError("Для активного VPN используйте обновление маршрутов VpnService.")
	}
	change, err := prepareAndroidRoutingChangeLocked(method, args)
	if err != nil {
		return androidSourceError(err.Error())
	}
	if err := change.saveLocked(); err != nil {
		return androidSourceError("Не удалось сохранить режим подключения. Попробуйте ещё раз.")
	}
	return change.resultLocked(false)
}

// ApplyAndroidRoutingChange replaces the route/DNS policy of the running
// session using its existing transports. The engine worker serializes this
// operation with other reloads. Cancellation wins over both commit and rollback.
func ApplyAndroidRoutingChange(method, args, activeConfig string, reload func(string) error) (string, error) {
	mu.Lock()
	if !current.Connected || current.sourceWorkCancelled {
		mu.Unlock()
		return androidSourceError("Подключение VPN уже завершено."), nil
	}
	change, err := prepareAndroidRoutingChangeLocked(method, decodeArgs(args))
	if err != nil || change.unchanged {
		defer mu.Unlock()
		if err != nil {
			return androidSourceError(err.Error()), nil
		}
		return change.resultLocked(change.tag == "" || change.mode != "all_traffic"), nil
	}
	if change.tag != "" && change.mode == "all_traffic" {
		defer mu.Unlock()
		if err := change.saveLocked(); err != nil {
			return androidSourceError("Не удалось сохранить маршруты Android VPN."), nil
		}
		return change.resultLocked(false), nil
	}
	revision, hideRU := current.sourcesRevision, current.Config.HideRuTraffic
	mu.Unlock()

	next, err := replaceAndroidRoutingPolicy(activeConfig, change, hideRU)
	if err != nil {
		return androidSourceError("Не удалось подготовить маршруты Android VPN."), nil
	}
	reloadErr := reload(next)
	mu.Lock()
	if !current.Connected || current.sourceWorkCancelled {
		mu.Unlock()
		return androidSourceError("Подключение VPN уже завершено."), nil
	}
	message := "Не удалось применить маршруты Android VPN."
	if reloadErr == nil && current.sourcesRevision == revision {
		if err := change.saveLocked(); err == nil {
			defer mu.Unlock()
			return change.resultLocked(true), nil
		}
		message = "Не удалось сохранить маршруты Android VPN."
	}
	mu.Unlock()
	return androidSourceError(message), reload(activeConfig)
}

func replaceAndroidRoutingPolicy(activeConfig string, change androidRoutingChange, hideRU bool) (string, error) {
	var config map[string]interface{}
	if err := json.Unmarshal([]byte(activeConfig), &config); err != nil {
		return "", err
	}
	outbounds, hasOutbounds := config["outbounds"].([]interface{})
	_, hasDNS := config["dns"].(map[string]interface{})
	route, hasRoute := config["route"].(map[string]interface{})
	if !hasOutbounds || !hasDNS || !hasRoute {
		return "", errors.New("incomplete active Android VPN configuration")
	}
	var hasProxy bool
	ruOutbound := "proxy"
	kept := outbounds[:0]
	for _, outbound := range outbounds {
		entry, _ := outbound.(map[string]interface{})
		tag, _ := entry["tag"].(string)
		if strings.HasPrefix(tag, AndroidAdaptiveSelectorPrefix) {
			continue
		}
		if tag == "proxy" {
			hasProxy = true
		}
		if tag == "ru-proxy" {
			ruOutbound = tag
		}
		kept = append(kept, outbound)
	}
	if !hasProxy {
		return "", errors.New("active Android VPN selector is missing")
	}
	policies := androidEffectiveRoutePoliciesForMode(change.policies, hasProxy, change.mode)
	config["outbounds"] = kept
	customDomains := aicatalog.CustomDomains(change.customServices)
	config["dns"] = buildAndroidDNSPolicy(hasProxy, change.mode, hideRU, policies, customDomains...)
	route["rules"], route["final"] = buildAndroidRouteRules(change.mode, hideRU, ruOutbound, policies, customDomains...), "direct"
	configureAndroidCatalog(route, change.mode)
	change.personal.apply(config)
	if change.mode == "blocked_only" {
		addAndroidAdaptiveGraph(config, change.policies)
	}
	data, err := json.Marshal(config)
	return string(data), err
}
