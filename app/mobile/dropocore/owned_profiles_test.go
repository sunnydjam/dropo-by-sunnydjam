package dropocore

import (
	"dropocore/ownedprofile"
	"encoding/json"
	"strings"
	"testing"
)

func TestAndroidManagedSecretsExcludedButReferenceSurvives(t *testing.T) {
	raw := "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"
	state := coreState{Subscription: raw, VPNSources: []androidVPNSource{{ID: "one", PublicCatalogID: ownedprofile.Free, URI: raw, Disabled: true, Nodes: []proxyConfig{{UUID: "11111111-2222-3333-4444-555555555555"}}}}, CachedSingBoxConfig: raw, CachedConfigSubscription: raw}
	safe := stateWithoutOwnedSecrets(state)
	body, err := json.Marshal(safe)
	if err != nil || strings.Contains(string(body), "11111111-2222-3333-4444-555555555555") || strings.Contains(string(body), "vless://") {
		t.Fatal("managed credential persisted in ordinary state")
	}
	if safe.VPNSources[0].PublicCatalogID != ownedprofile.Free || !safe.VPNSources[0].Disabled || state.VPNSources[0].URI != raw {
		t.Fatal("reference/choice or live state changed")
	}
}
