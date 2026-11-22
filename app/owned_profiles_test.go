package main

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"strings"
	"testing"
)

func TestManagedKeysAndGeneratedConfigsNeverPersistInSettings(t *testing.T) {
	raw := "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"
	settings := &SettingsFile{Profiles: []ProfileData{{ID: 1, SubscriptionURL: raw, VPNSources: []VPNSource{{ID: "one", PublicCatalogID: ownedprofile.Free, Name: "Dropo Free", URI: raw, Disabled: true, CachedNodes: []string{raw}}}, SingboxConfig: map[string]interface{}{"password": "11111111-2222-3333-4444-555555555555"}}}}
	safe := settingsWithoutOwnedSecrets(settings)
	body, err := json.Marshal(safe)
	if err != nil || strings.Contains(string(body), "11111111-2222-3333-4444-555555555555") || strings.Contains(string(body), "vless://") {
		t.Fatal("managed secret leaked to ordinary settings")
	}
	if safe.Profiles[0].VPNSources[0].PublicCatalogID != ownedprofile.Free || !safe.Profiles[0].VPNSources[0].Disabled {
		t.Fatal("protected reference/manual choice lost")
	}
	if settings.Profiles[0].VPNSources[0].URI != raw {
		t.Fatal("persistent redaction mutated live credentials")
	}
	if hasConfiguredVPNSource(&safe.Profiles[0]) {
		t.Fatal("empty protected reference became usable/direct fallback")
	}
}
