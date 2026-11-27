// Package blockedlist reads the bundled, normalized catalogs on Windows and Android.
package blockedlist

import (
	"bufio"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
)

const (
	maxBlockedCatalogItems = 250_000
	// Broad provider/CDN ranges are weak evidence that every address inside the
	// range is blocked. Route at most 16-address prefixes automatically; named
	// services keep their separately reviewed CIDRs.
	maxBlockedCatalogHostBits = 4
)

type Catalog struct {
	Domains []string
	IPCIDRs []string
}

// Index caches catalog data for one immutable runtime directory.
type Index struct {
	mu   sync.Mutex
	dir  string
	data Catalog
}

func (idx *Index) Search(dir, query string, personal Personal) map[string]any {
	query = strings.ToLower(strings.TrimSpace(query))
	if len(query) > 253 {
		return map[string]any{"success": false, "error": "Запрос слишком длинный"}
	}
	if dir == "" {
		return map[string]any{"success": false, "error": "Каталог ещё не готов"}
	}
	idx.mu.Lock()
	defer idx.mu.Unlock()
	if idx.dir != dir {
		domains, err := ReadLines(filepath.Join(dir, "domains_all.lst"), true)
		if err != nil {
			return map[string]any{"success": false, "error": err.Error()}
		}
		ips, err := ReadLines(filepath.Join(dir, "ipsum.lst"), false)
		if err != nil {
			return map[string]any{"success": false, "error": err.Error()}
		}
		idx.dir, idx.data = dir, Catalog{Domains: domains, IPCIDRs: ips}
	}
	page := idx.data.Page(query)
	if len(personal) == 0 {
		return page
	}
	userItems := []string{}
	extra := 0
	addr, _ := netip.ParseAddr(query)
	for i := len(personal) - 1; i >= 0; i-- {
		entry := personal[i]
		group := idx.data.Domains
		prefix, e := netip.ParsePrefix(entry)
		if e == nil {
			group = idx.data.IPCIDRs
		}
		if _, found := slices.BinarySearch(group, entry); !found {
			extra++
		}
		match := strings.Contains(entry, query)
		if addr.IsValid() && e == nil {
			match = prefix.Contains(addr)
		}
		if match && len(userItems) < 10 {
			userItems = append(userItems, entry)
		}
	}
	items := slices.Clone(userItems)
	for _, entry := range page["items"].([]string) {
		if len(items) >= 10 {
			break
		}
		if !slices.Contains(items, entry) {
			items = append(items, entry)
		}
	}
	// Keep an exact result visible even if ten user entries match its substring.
	if len(query) > 0 {
		_, domain := slices.BinarySearch(idx.data.Domains, query)
		_, ip := slices.BinarySearch(idx.data.IPCIDRs, query)
		if domain || ip || slices.Contains(personal, query) {
			items = append([]string{query}, slices.DeleteFunc(items, func(v string) bool { return v == query })...)
			if len(items) > 10 {
				items = items[:10]
			}
			if slices.Contains(personal, query) && !slices.Contains(userItems, query) {
				userItems = append(userItems, query)
			}
		}
	}
	page["total"] = page["total"].(int) + extra
	page["items"], page["personal"] = items, userItems
	return page
}

func (catalog Catalog) Page(query string) map[string]any {
	total := len(catalog.Domains) + len(catalog.IPCIDRs)
	items := make([]string, 0, 10)
	if query != "" {
		for _, group := range [][]string{catalog.Domains, catalog.IPCIDRs} {
			if _, exact := slices.BinarySearch(group, query); exact {
				items = append(items, query)
				break
			}
		}
	}
	queryIP, _ := netip.ParseAddr(query)
	for groupIndex, group := range [][]string{catalog.IPCIDRs, catalog.Domains} {
		for i := len(group) - 1; i >= 0 && len(items) < 10; i-- {
			value := group[i]
			if value == query {
				continue
			}
			match := strings.Contains(value, query)
			if groupIndex == 0 && queryIP.IsValid() {
				prefix, err := netip.ParsePrefix(value)
				match = err == nil && prefix.Contains(queryIP)
			}
			if match {
				items = append(items, value)
			}
		}
	}
	return map[string]any{"success": true, "total": total, "items": items}
}

func ReadLines(path string, domains bool) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open bundled blocked catalog %s: %w", filepath.Base(path), err)
	}
	defer file.Close()

	seen := make(map[string]struct{})
	items := make([]string, 0, 32_768)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 64*1024)
	for scanner.Scan() {
		value := strings.ToLower(strings.TrimSpace(scanner.Text()))
		if value == "" || strings.HasPrefix(value, "#") {
			continue
		}
		if domains {
			if !validCatalogDomain(value) {
				return nil, fmt.Errorf("invalid domain %q in %s", value, filepath.Base(path))
			}
		} else {
			prefix, parseErr := netip.ParsePrefix(value)
			if parseErr != nil {
				return nil, fmt.Errorf("invalid CIDR %q in %s: %w", value, filepath.Base(path), parseErr)
			}
			prefix = prefix.Masked()
			if !publicCatalogPrefix(prefix) || !specificBlockedCatalogPrefix(prefix) {
				continue
			}
			value = prefix.String()
		}
		if _, duplicate := seen[value]; duplicate {
			continue
		}
		if len(items) >= maxBlockedCatalogItems {
			return nil, fmt.Errorf("%s exceeds the %d-entry safety limit", filepath.Base(path), maxBlockedCatalogItems)
		}
		seen[value] = struct{}{}
		items = append(items, value)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read bundled blocked catalog %s: %w", filepath.Base(path), err)
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("bundled blocked catalog %s is empty", filepath.Base(path))
	}
	sort.Strings(items)
	return items, nil
}

func specificBlockedCatalogPrefix(prefix netip.Prefix) bool {
	if !prefix.IsValid() {
		return false
	}
	return prefix.Addr().BitLen()-prefix.Bits() <= maxBlockedCatalogHostBits
}

func validCatalogDomain(value string) bool {
	if len(value) > 253 || strings.HasPrefix(value, ".") || strings.HasSuffix(value, ".") || !strings.Contains(value, ".") {
		return false
	}
	for _, label := range strings.Split(value, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' || character == '_' {
				continue
			}
			return false
		}
	}
	return true
}

func publicCatalogPrefix(prefix netip.Prefix) bool {
	address := prefix.Addr()
	if !address.IsValid() || address.IsUnspecified() || address.IsLoopback() || address.IsMulticast() || address.IsPrivate() || address.IsLinkLocalUnicast() {
		return false
	}
	reserved := []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("169.254.0.0/16"),
		netip.MustParsePrefix("224.0.0.0/4"), netip.MustParsePrefix("240.0.0.0/4"),
		netip.MustParsePrefix("::/128"), netip.MustParsePrefix("::1/128"),
		netip.MustParsePrefix("fc00::/7"), netip.MustParsePrefix("fe80::/10"),
		netip.MustParsePrefix("ff00::/8"),
	}
	for _, blocked := range reserved {
		if blocked.Contains(address) || prefix.Contains(blocked.Addr()) {
			return false
		}
	}
	return true
}
