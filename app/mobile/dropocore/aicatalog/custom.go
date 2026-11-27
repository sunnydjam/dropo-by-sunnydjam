package aicatalog

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/idna"
	"golang.org/x/net/publicsuffix"
)

type CustomService struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Domains []string `json:"domains"`
}

// EditCustomService returns a new catalog. Each listed domain covers its
// subdomains as well. IPs, public suffixes and wildcards never become rules.
func EditCustomService(services []CustomService, id, name, input string, remove bool) ([]CustomService, error) {
	index := slices.IndexFunc(services, func(service CustomService) bool { return service.ID == id })
	if id != "" && index < 0 || remove && id == "" {
		return nil, errors.New("Сервис уже удалён или не найден")
	}
	next := slices.Clone(services)
	if remove {
		return slices.Delete(next, index, index+1), nil
	}
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > 64 || strings.ContainsFunc(name, unicode.IsControl) {
		return nil, errors.New("Введите название сервиса длиной до 64 символов")
	}
	if len(input) > 8192 {
		return nil, errors.New("Список доменов слишком длинный")
	}
	fields := strings.FieldsFunc(input, func(c rune) bool { return unicode.IsSpace(c) || c == ',' || c == ';' })
	if len(fields) == 0 || len(fields) > 24 {
		return nil, errors.New("Укажите от 1 до 24 доменов")
	}
	domains := make([]string, 0, len(fields))
	for _, field := range fields {
		domain, err := idna.Lookup.ToASCII(strings.ToLower(strings.TrimSuffix(field, ".")))
		_, ipErr := netip.ParseAddr(domain)
		_, suffixErr := publicsuffix.EffectiveTLDPlusOne(domain)
		if err != nil || ipErr == nil || suffixErr != nil || len(domain) > 253 || strings.ContainsAny(domain, "\x00/\\*:@?#_[]") {
			return nil, fmt.Errorf("Укажите домен без схемы, порта или маски: %s", field)
		}
		for _, service := range services {
			if service.ID != id && slices.Contains(service.Domains, domain) {
				return nil, fmt.Errorf("Домен уже добавлен в «%s»: %s", service.Name, domain)
			}
		}
		if !slices.Contains(domains, domain) {
			domains = append(domains, domain)
		}
	}
	if index < 0 {
		if len(services) >= 64 {
			return nil, errors.New("Можно добавить до 64 сервисов")
		}
		var key [12]byte
		if _, err := rand.Read(key[:]); err != nil {
			return nil, err
		}
		return append(next, CustomService{ID: hex.EncodeToString(key[:]), Name: name, Domains: domains}), nil
	}
	next[index] = CustomService{ID: id, Name: name, Domains: domains}
	return next, nil
}

func CustomDomains(services []CustomService) []string {
	var domains []string
	for _, service := range services {
		domains = append(domains, service.Domains...)
	}
	return domains
}
