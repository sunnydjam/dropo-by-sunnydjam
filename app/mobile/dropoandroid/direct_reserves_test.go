//go:build with_quic && with_utls

package dropoandroid

import (
	core "dropocore"
	"dropocore/dnspolicy"
	"dropocore/ownedprofile"
	"encoding/json"
	"strings"
	"testing"
)

func TestPlayManagedDirectReservesPassPinnedEngineConfig(t *testing.T) {
	playPolicyFixture(t)
	storedCoreFixture(t)
	const fixture = "vless://11111111-2222-3333-4444-555555555555@193.233.88.97:443?type=xhttp&security=tls&sni=cdn.droponevedimka.ru&host=cdn.droponevedimka.ru&path=%2Fmanaged%2Fv1%2Ffree&encryption=none&dropo_expiry=0"
	args, _ := json.Marshal([]any{ownedprofile.Free, "Free", fixture, true})
	var enrollment struct{ Success bool }
	if json.Unmarshal([]byte(core.Call("AddManagedVPNSource", string(args))), &enrollment) != nil || !enrollment.Success {
		t.Fatal("cannot enroll the managed fixture")
	}
	paid := strings.NewReplacer("%2Ffree", "%2Fboost", "expiry=0", "expiry=4102444800").Replace(fixture)
	args, _ = json.Marshal([]any{ownedprofile.Boost, "Boost", paid, true})
	if json.Unmarshal([]byte(core.Call("AddManagedVPNSource", string(args))), &enrollment) != nil || !enrollment.Success {
		t.Fatal("Boost enrollment failed")
	}
	var runtime struct {
		Success    bool
		Config     string
		Candidates []struct{ ID string }
	}
	if json.Unmarshal([]byte(BuildSingBoxConfig()), &runtime) != nil || !runtime.Success || len(runtime.Candidates) != 6 {
		t.Fatal("expected six regional transports")
	}
	regional := map[string]string{ownedprofile.Free + "-lv-quic": ownedprofile.Free, ownedprofile.Boost + "-fi-tcp": ownedprofile.Boost}
	for i := 0; i < len(runtime.Candidates); i += 3 {
		tier, ok := regional[runtime.Candidates[i].ID]
		if !ok || runtime.Candidates[i+1].ID != tier+ownedprofile.MainSuffix || runtime.Candidates[i+2].ID != tier+ownedprofile.ExtraSuffix {
			t.Fatal("tier lost its regional or primary route")
		}
		delete(regional, runtime.Candidates[i].ID)
	}
	var graph struct{ Outbounds []map[string]any }
	if err := json.Unmarshal([]byte(runtime.Config), &graph); err != nil {
		t.Fatal(err)
	}
	var fi map[string]any
	for _, out := range graph.Outbounds {
		if out["tag"] == "vpn-"+ownedprofile.Boost+"-fi-tcp" && out["type"] == xhttpOutboundType {
			fi, _ = out["xray_outbound"].(map[string]any)
			if _, exists := out["finland_relay"]; exists {
				t.Fatal("legacy HTTPS relay is still in the managed config")
			}
		}
	}
	if fi == nil {
		t.Fatal("managed Finland source did not use embedded Xray")
	}
	servers := fi["settings"].(map[string]any)["vnext"].([]any)
	if servers[0].(map[string]any)["address"] != dnspolicy.FinlandIPv4 {
		t.Fatal("Finnish REALITY must connect directly")
	}
	normalized, _, err := normalizeXHTTPConfig(runtime.Config, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	var internal struct{ Outbounds []map[string]any }
	if json.Unmarshal([]byte(normalized), &internal) != nil {
		t.Fatal("invalid graph")
	}
	tag := "vpn-" + ownedprofile.Boost + "-fi-tcp"
	found := false
	for _, out := range internal.Outbounds {
		if out["tag"] == tag {
			found = out["type"] == "socks" && out["server"] == "127.0.0.1" && out["password"] != ""
		}
		if name, _ := out["tag"].(string); strings.HasPrefix(name, tag+"-via-") {
			t.Fatal("Finnish entrance unexpectedly uses a relay")
		}
	}
	if !found {
		t.Fatal("missing protected loopback bridge for direct Finnish REALITY")
	}
	stream, _ := fi["streamSettings"].(map[string]any)
	if !managedRegionalRealityStream(fi, stream) {
		t.Fatal("missing managed TCP/REALITY stream")
	}
	for _, mutate := range []func(map[string]any){
		func(o map[string]any) { o["streamSettings"].(map[string]any)["security"] = "none" },
		func(o map[string]any) { o["streamSettings"].(map[string]any)["sockopt"] = map[string]any{} },
		func(o map[string]any) {
			o["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "192.0.2.1"
		},
	} {
		var changed map[string]any
		raw, _ := json.Marshal(fi)
		if err := json.Unmarshal(raw, &changed); err != nil {
			t.Fatal(err)
		}
		mutate(changed)
		raw, _ = json.Marshal(changed)
		if _, err := buildXHTTPConfig(raw, nil); err == nil {
			t.Fatal("accepted modified managed TCP transport")
		}
		if managedRegionalRealityStream(changed, changed["streamSettings"].(map[string]any)) {
			t.Fatal("Play accepted modified managed TCP transport")
		}
	}
	if err := CheckConfig(runtime.Config); err != nil {
		t.Fatal("pinned Play runtime rejected a direct reserve", err)
	}
}
