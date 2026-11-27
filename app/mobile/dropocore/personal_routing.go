package dropocore

import (
	"dropocore/blockedlist"
	"errors"
	"regexp"
	"slices"
	"strings"
)

type androidPersonalRouting struct {
	Addresses blockedlist.Personal `json:"addresses,omitempty"`
	Packages  []string             `json:"packages,omitempty"`
}

func (p androidPersonalRouting) signature() string {
	if len(p.Addresses) == 0 && len(p.Packages) == 0 {
		return ""
	}
	return "|addresses=" + strings.Join(p.Addresses, ",") + "|packages=" + strings.Join(p.Packages, ",")
}
func (p androidPersonalRouting) bindings() map[string]any {
	rows := make([]map[string]string, 0, len(p.Packages))
	for _, pkg := range p.Packages {
		rows = append(rows, map[string]string{"path": pkg, "service": "user-app-vpn"})
	}
	return map[string]any{"success": true, "bindings": rows, "services": map[string]string{"user-app-vpn": "Через VPN"}}
}

var personalPackage = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$`)

func (p *androidPersonalRouting) editPackage(old, value, service string) error {
	packages := slices.Clone(p.Packages)
	if old != "" {
		i := slices.Index(packages, old)
		if i < 0 {
			return errors.New("Приложение уже удалено")
		}
		packages = slices.Delete(packages, i, i+1)
	}
	value = strings.TrimSpace(value)
	if value == "" && old == "" {
		return errors.New("Введите имя пакета Android")
	}
	if value != "" {
		if service != "user-app-vpn" || len(value) > 255 || !personalPackage.MatchString(value) {
			return errors.New("Укажите имя пакета Android, например com.example.app")
		}
		for _, svc := range androidServiceCatalog() {
			if slices.Contains(svc.PackageNames, value) {
				return errors.New("Приложение уже есть во встроенном каталоге")
			}
		}
		if slices.Contains(packages, value) {
			return errors.New("Приложение уже добавлено")
		}
		if len(packages) >= 128 {
			return errors.New("Можно добавить до 128 приложений")
		}
		packages = append(packages, value)
	}
	p.Packages = packages
	return nil
}
func (p androidPersonalRouting) apply(config map[string]any) {
	p.Addresses.Apply(config)
	if len(p.Packages) == 0 {
		return
	}
	route := config["route"].(map[string]any)
	rules := route["rules"].([]any)
	// The built-in protected package rule already follows local/work exclusions.
	for _, raw := range rules {
		rule, _ := raw.(map[string]any)
		names, ok := rule["package_name"].([]string)
		if ok && rule["outbound"] == "proxy" {
			rule["package_name"] = append(slices.Clone(names), p.Packages...)
			return
		}
	}
}
