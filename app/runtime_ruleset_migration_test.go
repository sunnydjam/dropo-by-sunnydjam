package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMigrateRuntimeRuleSetPaths(t *testing.T) {
	currentRuntime := t.TempDir()
	previousRuntime := t.TempDir()
	currentFilters := filepath.Join(currentRuntime, "bin", FiltersFolder)

	config := map[string]interface{}{
		"route": map[string]interface{}{
			"rule_set": []interface{}{
				map[string]interface{}{
					"type":   "local",
					"tag":    "refilter-domains",
					"format": "binary",
					"path":   filepath.Join(previousRuntime, "bin", FiltersFolder, "refilter_domains.srs"),
				},
				map[string]interface{}{
					"type": "local",
					"tag":  "user-owned-rule-set",
					"path": filepath.Join(previousRuntime, "custom.srs"),
				},
			},
		},
	}

	if !migrateRuntimeRuleSetPaths(config, currentFilters) {
		t.Fatal("previous runtime path was not migrated")
	}
	ruleSets := config["route"].(map[string]interface{})["rule_set"].([]interface{})
	want := filepath.Join(currentFilters, "refilter_domains.srs")
	if got := ruleSets[0].(map[string]interface{})["path"]; !sameRuntimeRuleSetPath(got.(string), want) {
		t.Fatalf("migrated path = %q, want %q", got, want)
	}
	if migrateRuntimeRuleSetPaths(config, currentFilters) {
		t.Fatal("current runtime path was migrated again")
	}

	// Unknown local rule sets are outside this migration's ownership boundary.
	config["route"].(map[string]interface{})["rule_set"] = ruleSets[1:]
	originalUnmanagedPath := ruleSets[1].(map[string]interface{})["path"]
	if migrateRuntimeRuleSetPaths(config, currentFilters) {
		t.Fatal("unmanaged local rule-set was migrated")
	}
	if got := ruleSets[1].(map[string]interface{})["path"]; got != originalUnmanagedPath {
		t.Fatalf("unmanaged local rule-set path changed from %q to %q", originalUnmanagedPath, got)
	}
}

func TestEnsureActiveConfigMigratesPreviousRuntimeRuleSetPathsOffline(t *testing.T) {
	app := newInitializedSettingsScenarioApp(t)
	currentFilters := app.configBuilder.filterManager.GetFiltersPath()
	if err := os.MkdirAll(currentFilters, 0755); err != nil {
		t.Fatalf("create current filters directory: %v", err)
	}
	for _, filter := range FilterFiles {
		if err := os.WriteFile(filepath.Join(currentFilters, filter.Name), []byte("test"), 0644); err != nil {
			t.Fatalf("create current filter %s: %v", filter.Name, err)
		}
	}
	if err := app.configBuilder.BuildConfig(""); err != nil {
		t.Fatalf("build current config: %v", err)
	}

	profile, err := app.storage.GetActiveProfile()
	if err != nil {
		t.Fatalf("get active profile: %v", err)
	}
	config, err := app.storage.GetProfileConfig(profile.ID)
	if err != nil {
		t.Fatalf("get current profile config: %v", err)
	}
	route := config["route"].(map[string]interface{})
	ruleSets := route["rule_set"].([]interface{})
	if len(ruleSets) == 0 {
		t.Fatal("generated config has no bundled local rule sets")
	}
	previousRuntime := t.TempDir()
	stalePath := filepath.Join(previousRuntime, "bin", FiltersFolder, "refilter_domains.srs")
	staleInjected := false
	for _, raw := range ruleSets {
		ruleSet, _ := raw.(map[string]interface{})
		if ruleSet["tag"] == "refilter-domains" {
			ruleSet["path"] = stalePath
			staleInjected = true
			break
		}
	}
	if !staleInjected {
		t.Fatal("generated config has no refilter-domains rule set")
	}
	// A full rebuild would discard this unknown field. Keeping it proves the
	// repair is an offline, path-only migration of the cached profile.
	config["runtime_migration_marker"] = "preserved"
	if err := app.storage.UpdateProfileConfig(profile.ID, config); err != nil {
		t.Fatalf("store stale profile config: %v", err)
	}
	if err := app.ensureActiveConfigForStart(); err != nil {
		t.Fatalf("migrate stale runtime config: %v", err)
	}

	migrated, err := app.storage.GetProfileConfig(profile.ID)
	if err != nil {
		t.Fatalf("get migrated profile config: %v", err)
	}
	if got := migrated["runtime_migration_marker"]; got != "preserved" {
		t.Fatalf("cached config was rebuilt instead of migrated in place: marker = %v", got)
	}
	if migrateRuntimeRuleSetPaths(migrated, currentFilters) {
		t.Fatal("stored config still references a previous runtime")
	}
	migratedRoute := migrated["route"].(map[string]interface{})
	foundMigratedRuleSet := false
	for _, raw := range migratedRoute["rule_set"].([]interface{}) {
		ruleSet, _ := raw.(map[string]interface{})
		if ruleSet["tag"] != "refilter-domains" {
			continue
		}
		want := filepath.Join(currentFilters, "refilter_domains.srs")
		if got, _ := ruleSet["path"].(string); !sameRuntimeRuleSetPath(got, want) {
			t.Fatalf("migrated refilter path = %q, want %q", got, want)
		}
		foundMigratedRuleSet = true
		break
	}
	if !foundMigratedRuleSet {
		t.Fatal("migrated config lost the refilter-domains rule set")
	}

	activeConfigPath, err := app.storage.WriteActiveConfigToFile()
	if err != nil {
		t.Fatalf("write active config: %v", err)
	}
	proxyConfigPath, err := app.writeDeepWindowsProxyFallbackConfig(activeConfigPath)
	if err != nil {
		t.Fatalf("write selective proxy config: %v", err)
	}
	for _, path := range []string{activeConfigPath, proxyConfigPath} {
		written, err := readJSONConfig(path)
		if err != nil {
			t.Fatalf("read generated config %s: %v", filepath.Base(path), err)
		}
		if migrateRuntimeRuleSetPaths(written, currentFilters) {
			t.Fatalf("generated config %s still referenced the previous runtime", filepath.Base(path))
		}
	}
}
